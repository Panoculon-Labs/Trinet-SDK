# Trinet laptop tools

Python utilities for poking at a Trinet camera from a laptop. **For testing and debugging only** — the Android SDK and demo app are the supported capture path.

## `trinet_live_viewer.py`

Tkinter GUI that opens a Trinet camera over UVC, demuxes the raw H.264 bitstream, parses the `TRINETIMUSEI` SEI NAL units (see [`../trinet-sdk/README.md`](../trinet-sdk/README.md#h264-sei--trinet-imu-payload)), and shows:

- live camera preview
- the most recent IMU sample (accel / gyro / mag / temp / fsync delay)
- rolling accel + gyro plots

Cross-platform via PyAV: `v4l2` on Linux, `avfoundation` on macOS, `dshow` on Windows.

### Install

```bash
pip install -r requirements.txt
```

### Run

```bash
python3 trinet_live_viewer.py
# or override the device path:
python3 trinet_live_viewer.py --device /dev/video2
```

The Trinet camera advertises **only one UVC mode**: H.264 1920×1080 @ 30 fps. The Android SDK's native layer (`trinet-sdk/src/main/cpp/libuvc_jni.cpp`) refuses to fall back to MJPEG or any other resolution, and the firmware does not expose lower H.264 modes. Resolution and fps are therefore fixed in this tool — there is no knob to turn down.

Platform hints for the `--device` argument:

- **Linux** — `/dev/videoN`; the device dropdown auto-populates from `/dev/video*`.
- **macOS** — an avfoundation index (`0`, `1`, …). List devices with `ffmpeg -f avfoundation -list_devices true -i ""`.
- **Windows** — `video=<friendly name>` (e.g. `video=USB Video Device`). List devices with `ffmpeg -list_devices true -f dshow -i dummy`.

### Expect lag

The viewer software-decodes 1080p30 H.264 on the CPU and pushes RGB frames through a Python/Tk image pipeline. Even with the libswscale resize + worker-thread offload, this will be choppy on modest laptops — there is no way to ease it by dropping resolution, because the camera only emits 1080p30. The Android app stays smooth because it uses MediaCodec hardware decode straight to a SurfaceView.

The IMU rate in the readout is independent of video decode and should stay close to 562 Hz. If that number looks healthy, the USB transport and SEI parser are fine and the laggy preview is purely the CPU decode + Tk paint bottleneck.

This tool is intended for quick sanity checks (camera enumerates, stream negotiates, IMU SEI parses) — not for capturing data. Use the Android demo app for recording.
