# Changelog

## 0.3.1 — 2026-10-16: silent preview, audio in phone recordings, H.265 live stream

- **Silent preview.** The Record screen no longer plays the camera's audio
  while previewing. Audio is still recorded. Library playback sets its own
  audio session, so recorded files play with sound.
- **Audio reliably recorded.**
  - **Missing track:** the MP4 writer only created the AAC track if an audio
    frame arrived before the first video frame. A recording that began on a
    frame without audio was silent from start to finish. The writer now opens
    on a keyframe once the audio format is known, or after about 0.5 s with no
    audio (cameras without a microphone).
  - **Timing:** video frame times now come from the SEI v6 `frame_sof_ts_ns`,
    the same clock mapping the camera uses for audio timestamps.
  - **Fallback:** if the camera's audio clock is grossly off, audio is lined up
    with the video frames it arrived with, and this is logged once
    (`audioRebased=1` in the `Mp4Writer.finish` log).
- **H.265.**
  - **Codec selection:** the live session uses the codec the camera actually
    streams. It asks `GET /api/video/stream_codec`, and the HTTP
    `Content-Type` overrides that answer.
  - **Controls:** a new "Stream codec (iPhone)" picker sets the camera's NCM
    stream codec. The camera restarts its stream and the app reconnects. A
    "Card recording codec" picker sets the SD recording codec
    (`/api/video/codec`). Both are hidden on firmware without these endpoints.
  - **Fix:** the `Content-Type` parser never matched, because `"\r\n"` is a
    single `Character` in Swift.
- **Tests:** 21 SDK tests on the iOS simulator. New: the session start gate,
  audio rebasing, v6 frame time, H.265 SEI and `Content-Type` parsing. The old
  IMU tests compile again (decoded samples are unwrapped, and the test for the
  retired UDP IMU packet is gone).
- **Requires** camera firmware with `/api/video/stream_codec` for the H.265
  switch. Older firmware stays on H.264 and the picker is hidden.

## 0.3.0 — 2026-10-07: NCM parity, stereo cameras

- **Added:** AAC audio recorded into the MP4, full camera controls, and the
  `FRAME_CENTERED` timing flag.
- **Device info:** device model and generation awareness (`TrinetDeviceInfo`),
  with a fallback to the generation number on older firmware.
- **Stereo:** a 3840×1080 side-by-side preview with an L / Both / R lens
  picker. Recordings keep the full canvas.
- **Calibration:** the 300-byte stereo calibration blob, byte-identical to
  Android.
- **New controls:** hue, manual exposure time, thermal limit, BLE status
  broadcast, AWB tune, and noise reduction on GS. LED state is read back.
