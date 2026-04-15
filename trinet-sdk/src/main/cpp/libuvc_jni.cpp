// JNI bridge: bind an Android-supplied USB file descriptor to libusb via
// libusb_wrap_sys_device, open it with libuvc, and stream H.264 frames back
// to Kotlin as ByteArrays.
//
// Threading: libuvc spins up its own libusb event thread and invokes our
// stream callback off the main thread. We attach to the JVM, copy the frame
// payload into a Java byte[], invoke NativeBridge.onFrameNative(...), and
// return immediately. The Java side decides what to do with the buffer.

#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <time.h>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "libusb.h"
#include "libuvc/libuvc.h"

#define LOG_TAG "trinet.jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM* g_jvm = nullptr;
jclass  g_bridge_class = nullptr;
jmethodID g_on_frame = nullptr;
jmethodID g_on_error = nullptr;

struct Session {
    uvc_context_t*         uvc_ctx = nullptr;
    uvc_device_handle_t*   uvc_dev = nullptr;
    uvc_stream_ctrl_t      stream_ctrl{};
    std::atomic<bool>      streaming{false};
    // First-frame CLOCK_MONOTONIC timestamp in µs. Each stream start resets it
    // so PTS restarts at 0 per session.
    std::atomic<int64_t>   pts_epoch_us{0};
};

JNIEnv* attach_env(bool* attached) {
    JNIEnv* env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
        *attached = false;
        return env;
    }
    if (g_jvm->AttachCurrentThread(&env, nullptr) == JNI_OK) {
        *attached = true;
        return env;
    }
    return nullptr;
}

void detach_env(bool attached) {
    if (attached) g_jvm->DetachCurrentThread();
}

void on_frame_callback(uvc_frame_t* frame, void* user_ptr) {
    auto* sess = static_cast<Session*>(user_ptr);
    if (!sess->streaming.load(std::memory_order_relaxed)) return;
    if (!frame || !frame->data || frame->data_bytes == 0) return;

    // Log the first few frames so Kotlin-side misconfiguration is visible:
    // size + first bytes let us tell H.264 Annex B (00 00 00 01 ...) from MJPEG (FF D8).
    static std::atomic<int> frame_seq{0};
    int seq = frame_seq.fetch_add(1, std::memory_order_relaxed);
    if (seq < 5) {
        const uint8_t* d = static_cast<const uint8_t*>(frame->data);
        size_t n = frame->data_bytes < 16 ? frame->data_bytes : 16;
        char hex[64] = {0};
        int pos = 0;
        for (size_t i = 0; i < n && pos < (int)sizeof(hex) - 3; ++i)
            pos += snprintf(hex + pos, sizeof(hex) - pos, "%02x ", d[i]);
        LOGI("native frame #%d: bytes=%zu fmt=%d head=%s",
             seq, frame->data_bytes, (int)frame->frame_format, hex);
    } else if (seq == 30 || seq % 150 == 0) {
        LOGI("native frame #%d: bytes=%zu", seq, frame->data_bytes);
    }

    bool attached = false;
    JNIEnv* env = attach_env(&attached);
    if (!env) return;

    jbyteArray arr = env->NewByteArray(static_cast<jsize>(frame->data_bytes));
    if (!arr) {
        env->ExceptionClear();
        detach_env(attached);
        return;
    }
    env->SetByteArrayRegion(arr, 0, static_cast<jsize>(frame->data_bytes),
                            reinterpret_cast<const jbyte*>(frame->data));
    // libuvc on Android does not populate frame->capture_time (observed:
    // tv_sec=tv_usec=0 for every frame). That caused MediaMuxer to see PTS=0
    // for every sample and emit an MP4 with a bogus ~10000 fps header. We
    // stamp each frame ourselves with CLOCK_MONOTONIC µs, normalised against
    // the first frame of *this session* so PTS restarts at 0 per recording.
    struct timespec tsn{};
    clock_gettime(CLOCK_MONOTONIC, &tsn);
    int64_t now_us = static_cast<int64_t>(tsn.tv_sec) * 1000000LL
                   + static_cast<int64_t>(tsn.tv_nsec) / 1000LL;
    int64_t epoch = sess->pts_epoch_us.load(std::memory_order_relaxed);
    if (epoch == 0) {
        sess->pts_epoch_us.compare_exchange_strong(epoch, now_us);
        epoch = sess->pts_epoch_us.load(std::memory_order_relaxed);
    }
    jlong pts_us = static_cast<jlong>(now_us - epoch);
    env->CallStaticVoidMethod(g_bridge_class, g_on_frame, arr, pts_us);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(arr);
    detach_env(attached);
}

void report_error(const char* msg) {
    bool attached = false;
    JNIEnv* env = attach_env(&attached);
    if (!env) return;
    jstring s = env->NewStringUTF(msg);
    env->CallStaticVoidMethod(g_bridge_class, g_on_error, s);
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->DeleteLocalRef(s);
    detach_env(attached);
}

} // anonymous namespace

extern "C" jint JNI_OnLoad(JavaVM* vm, void*) {
    g_jvm = vm;
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return -1;

    jclass cls = env->FindClass("com/panoculon/trinet/sdk/transport/NativeBridge");
    if (!cls) return -1;
    g_bridge_class = reinterpret_cast<jclass>(env->NewGlobalRef(cls));
    g_on_frame = env->GetStaticMethodID(g_bridge_class, "onFrameNative", "([BJ)V");
    g_on_error = env->GetStaticMethodID(g_bridge_class, "onErrorNative", "(Ljava/lang/String;)V");
    if (!g_on_frame || !g_on_error) return -1;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_panoculon_trinet_sdk_transport_NativeBridge_nativeVersion(JNIEnv* env, jclass) {
    return env->NewStringUTF(TRINET_NATIVE_VERSION);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_panoculon_trinet_sdk_transport_NativeBridge_nativeOpen(
    JNIEnv* /*env*/, jclass, jint usb_fd) {
    auto* sess = new Session();

    // libusb on Android: skip device enumeration. Setting this on the NULL
    // (global) context applies to any libusb_init called after — including
    // the one libuvc performs internally inside uvc_init.
    if (libusb_set_option(nullptr, LIBUSB_OPTION_NO_DEVICE_DISCOVERY, nullptr) != LIBUSB_SUCCESS) {
        LOGW("libusb NO_DEVICE_DISCOVERY rejected (continuing)");
    }

    // IMPORTANT: pass NULL so libuvc creates and OWNS its libusb context.
    // If we pass our own, libuvc's `own_usb_ctx` flag stays 0 and the event
    // handler thread is NEVER spawned — which means isochronous transfers are
    // submitted but their completion callbacks never fire, so no frames ever
    // reach the caller. See libuvc init.c:159 (uvc_start_handler_thread guard).
    uvc_error_t urc = uvc_init(&sess->uvc_ctx, nullptr);
    if (urc != UVC_SUCCESS) {
        LOGE("uvc_init failed: %d", urc);
        delete sess;
        return 0;
    }
    urc = uvc_wrap(usb_fd, sess->uvc_ctx, &sess->uvc_dev);
    if (urc != UVC_SUCCESS) {
        LOGE("uvc_wrap failed: %d (%s)", urc, uvc_strerror(urc));
        uvc_exit(sess->uvc_ctx);
        delete sess;
        return 0;
    }
    LOGI("native open ok: fd=%d session=%p", usb_fd, sess);
    return reinterpret_cast<jlong>(sess);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_panoculon_trinet_sdk_transport_NativeBridge_nativeStartStream(
    JNIEnv*, jclass, jlong handle, jint width, jint height, jint fps) {
    auto* sess = reinterpret_cast<Session*>(handle);
    if (!sess || !sess->uvc_dev) return JNI_FALSE;

    // Try H.264 first (uvc_get_stream_ctrl_format_size handles framebased).
    // DO NOT fall back to MJPEG — our pipeline assumes H.264 Annex B, and a silent
    // MJPEG fallback would produce JPEGs that our NAL parser would mis-decode into
    // garbage, producing a black preview with no obvious error.
    uvc_error_t rc = uvc_get_stream_ctrl_format_size(
        sess->uvc_dev, &sess->stream_ctrl, UVC_FRAME_FORMAT_H264, width, height, fps);
    if (rc != UVC_SUCCESS) {
        LOGE("uvc H264 %dx%d@%d negotiation failed: %d (%s). "
             "This build does not fall back to MJPEG — the device must advertise H.264.",
             width, height, fps, rc, uvc_strerror(rc));
        char msg[128];
        snprintf(msg, sizeof(msg), "H264 %dx%d@%d negotiation failed: %s",
                 width, height, fps, uvc_strerror(rc));
        report_error(msg);
        return JNI_FALSE;
    }
    LOGI("stream_ctrl: dwMaxPayloadTransferSize=%u dwMaxVideoFrameSize=%u",
         sess->stream_ctrl.dwMaxPayloadTransferSize,
         sess->stream_ctrl.dwMaxVideoFrameSize);

    sess->streaming.store(true, std::memory_order_relaxed);
    sess->pts_epoch_us.store(0, std::memory_order_relaxed);  // restart PTS at 0
    rc = uvc_start_streaming(sess->uvc_dev, &sess->stream_ctrl, on_frame_callback, sess, 0);
    if (rc != UVC_SUCCESS) {
        sess->streaming.store(false);
        LOGE("uvc_start_streaming failed: %d (%s)", rc, uvc_strerror(rc));
        report_error(uvc_strerror(rc));
        return JNI_FALSE;
    }
    LOGI("streaming started: %dx%d @ %d fps", width, height, fps);
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_panoculon_trinet_sdk_transport_NativeBridge_nativeStopStream(
    JNIEnv*, jclass, jlong handle) {
    auto* sess = reinterpret_cast<Session*>(handle);
    if (!sess) return;
    sess->streaming.store(false, std::memory_order_relaxed);
    if (sess->uvc_dev) uvc_stop_streaming(sess->uvc_dev);
}

extern "C" JNIEXPORT void JNICALL
Java_com_panoculon_trinet_sdk_transport_NativeBridge_nativeClose(
    JNIEnv*, jclass, jlong handle) {
    auto* sess = reinterpret_cast<Session*>(handle);
    if (!sess) return;
    sess->streaming.store(false);
    if (sess->uvc_dev) uvc_close(sess->uvc_dev);
    // uvc_exit tears down libuvc's internal libusb context too (because we
    // passed NULL to uvc_init, so own_usb_ctx==1).
    if (sess->uvc_ctx) uvc_exit(sess->uvc_ctx);
    delete sess;
}
