# Changelog

## 0.3.5 — 2026-10-24: no freeze on Record, Stop or Share

- **Tapping Record no longer freezes the app.** Starting a recording also
  started the background keep-alive, and that activated the audio session
  and started an audio engine on the main thread. Those calls wait on the
  system's audio server, often for 100 ms to over a second. Stopping
  deactivated the session the same way. `BackgroundKeepAlive.start()` and
  `stop()` now return at once. The audio work runs on one serial queue,
  `TrinetAudioSession.queue`, and a quick start-then-stop costs at most one
  activation. The Library player's audio-session setup uses the same queue.
- **The recording counter no longer waits on the video thread.** The
  bytes-written display read its counter under the recorder's lock, four
  times a second. That lock is held for every MP4 append and for
  AVAssetWriter's slow first `startWriting()`. The counter now has its own
  lock, held only to add or read.
- **The live preview runs off the main thread.** Every 3840x1080 frame used
  to hop onto the main thread to be enqueued, 30 times a second. Frames now
  go to the display layer's `sampleBufferRenderer` from a background task,
  which iOS 17 supports. After a dropped frame the preview waits for the next
  keyframe instead of smearing.
- **The IMU plot redraws at most 15 times a second.** Each IMU sample was
  appended to the published plot arrays one at a time. At the IMU's sample rate that meant
  well over a thousand array copies and change notifications per second, and up to 30
  full plot redraws, all on the main thread. `ImuHistory` now buffers and
  republishes the window at most 15 times a second, plus a final update when
  samples stop.
- **Share opens without probing the movie.** The share sheet now gets a
  promised file: its type and name, plus a title and a stock icon. The file
  itself is handed over only once you pick an activity, so no file is opened
  while the sheet is built.
- **No leaked or doubled sessions.** If Record was left (or the stream
  restarted) while the session was still opening, the late session was kept
  and started. Nothing ever stopped it: a second stream ran against the
  camera. Late opens are now discarded. A double tap can't start two
  recordings, and a recording can't attach to a session that is stopping.
- **New diagnostics.** `TrinetDiagnostics` signposts the slow steps (Points
  of Interest in Instruments) and logs any that take 100 ms or more
  (subsystem `com.panoculon.trinet`, category `perf`). The new
  `MainThreadStallDetector`, which the app starts in DEBUG builds, logs every
  main-thread stall of 250 ms or more and names the operations that were
  running. New unit tests cover the plot throttling, the non-blocking
  keep-alive, recorder setup off the main thread, keyframe detection and the
  stall detector (35 tests).

## 0.3.4 — 2026-10-24: no crash when switching to Record; camera storage removed

- **Crash fixed.** Opening Record could crash the app (a trap in
  `Data.removeSubrange`; under Xcode it looks like a freeze). The video
  stream's network callbacks ran on a concurrent queue while `stop()` and the
  reconnect path replaced the stream parser from another thread, so the parser
  could be mutated mid-chunk. All connection callbacks and parsing state now
  live on one serial queue, and resets happen on that queue.
- **Stream parser hardened.** The Annex-B splitter no longer assumes its buffer
  starts at index 0. New unit tests cover start codes split across chunk
  boundaries and sliced input (25 tests).
- **"Storage on Trinet" removed** from Home. It showed the camera's SD card,
  which isn't used by the phone app. The SDK keeps `storage()`.

## 0.3.3 — 2026-10-24: recordings continue in the background and on lock

- **Recording keeps running** when the app is backgrounded or the phone is
  locked, like the Android app. Before, iOS suspended the app within seconds,
  which dropped the camera stream and ended the recording.
  - **How:** the new `BackgroundKeepAlive` (SDK) plays an inaudible audio loop
    while a recording runs. It mixes with other audio, restarts after calls and
    Siri, and stops when recording stops. The app declares
    `UIBackgroundModes: audio`.
  - **Thermal pause:** a thermal pause during a background recording keeps the
    app alive, so the recording resumes once the camera cools.
- **Not recording:** the stream closes when the app goes to the background and
  reopens automatically on return. Before, it could come back dead.
- **Preview:** it pauses while backgrounded, because iOS allows no video
  decoding there. On return it flushes and restarts at the next keyframe, with
  no smeared frames.
- **App Store note:** silent background audio can be questioned in review.
  TestFlight, ad-hoc and enterprise builds are unaffected.

## 0.3.2 — 2026-10-19: split recordings, 180-degree flip, PCM card audio

Three new camera controls, over the NCM HTTP API the firmware gained alongside.
Each one is read on connect and its section only appears when the camera
answers, so older firmware simply shows nothing rather than a dead control.

- **Split recordings** (`recordingChunk` / `setRecordingChunk(minutes:)`,
  `GET`/`POST /api/recording/chunk`). Long card recordings can be written as a
  series of parts of 0...240 minutes instead of one file — 0 means one
  continuous file, the default. Parts land in a folder named after the
  recording and each one plays on its own, so a power loss costs the last part
  rather than the whole take. Applies to the camera's next recording with no
  restart; a recording already running is unaffected.
- **Rotate picture 180°** (`imageFlip` / `setImageFlip`,
  `GET`/`POST /api/video/flip`). For wearing the camera upside-down, a cap
  mount for instance: an EXTRA half-turn on top of however the camera is
  built, so an inverted camera records and previews upright. On a stereo
  camera the two eyes swap with it, and the calibration served from
  `/api/calibration` is rotated to match, so a flipped camera does not have to
  be recalibrated. The camera restarts to apply, and the setting is kept by a
  settings reset — it describes how the camera is mounted, not a preference.
- **Recording audio format** (`recordingAudioFormat` /
  `setRecordingAudioFormat`, `GET`/`POST /api/audio/format`, plus the new
  `AudioFormat` enum). Also write the original uncompressed samples to the
  card, as a `.wav` beside each recording. **Additive, not a swap** — the MP4
  keeps exactly the same AAC track and the `.wav` is sample-aligned to it, so
  it drops in with no offset and nothing in an existing pipeline changes. It is
  a sidecar because raw PCM cannot go inside an MP4: the format has no object
  type for it, and the QuickTime `sowt` workaround is not decoded by several
  mainstream players. Costs about twelve times AAC's audio bitrate on the card.
  Card recordings only — the audio in the live stream is always AAC.

Needs camera firmware 0.5.12 or newer.

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
