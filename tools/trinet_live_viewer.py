#!/usr/bin/env python3
"""
Trinet UVC live viewer — laptop tool.

Opens a Trinet camera over UVC, demuxes the raw H.264 bitstream, parses the
TRINET IMU SEI NAL units (see trinet-sdk/README.md), and shows a live camera
preview alongside live IMU readouts and rolling plots.

Cross-platform:
    Linux   — v4l2     (e.g. /dev/video0)
    macOS   — avfoundation (e.g. "0" or "0:none")
    Windows — dshow    (e.g. "video=USB Video Device")

Dependencies:
    pip install av pillow numpy matplotlib

Run:
    python3 trinet_live_viewer.py
    python3 trinet_live_viewer.py --device /dev/video2

Trinet cameras advertise H.264 1920x1080 @ 30 fps only — the native UVC
negotiation in the Android SDK rejects anything else, and the camera
firmware does not expose lower modes. Resolution / fps are therefore
fixed and not user-tunable.
"""

from __future__ import annotations

import argparse
import glob
import platform
import queue
import struct
import sys
import threading
import time
import tkinter as tk
from collections import deque
from tkinter import ttk

try:
    import av
except ImportError:
    sys.stderr.write("Missing dependency: PyAV. Install with `pip install av`.\n")
    sys.exit(1)

try:
    import numpy as np
    from PIL import Image, ImageTk
    from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
    from matplotlib.figure import Figure
except ImportError as exc:
    sys.stderr.write(
        f"Missing dependency ({exc}). Install with `pip install pillow numpy matplotlib`.\n"
    )
    sys.exit(1)


# --------------------------------------------------------------------------- #
# Trinet IMU SEI parsing
# --------------------------------------------------------------------------- #

# "TRINETIMUSEI" + payload version 0x0001 (big-endian) + 2 reserved bytes.
TRINET_IMU_SEI_UUID = bytes(
    [
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x49, 0x4D,
        0x55, 0x53, 0x45, 0x49, 0x00, 0x01, 0x00, 0x00,
    ]
)

# 80-byte little-endian per-sample record (see trinet-sdk/README.md).
#   u64 ts_ns | 3×f32 accel | 3×f32 gyro | 3×f32 mag | f32 temp
#   4×f32 quat_xyzw | 3×f32 lin_accel | f32 fsync_delay_us
_SAMPLE = struct.Struct("<Q3f3f3ff4f3ff")
assert _SAMPLE.size == 80


def _split_annexb_nals(buf: bytes) -> list[bytes]:
    """Return NAL payloads (header byte included, start code stripped)."""
    out: list[bytes] = []
    if not buf:
        return out
    n = len(buf)
    starts: list[tuple[int, int]] = []
    i = 0
    while i + 2 < n:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                starts.append((i, 3))
                i += 3
                continue
            if i + 3 < n and buf[i + 2] == 0 and buf[i + 3] == 1:
                starts.append((i, 4))
                i += 4
                continue
        i += 1
    for idx, (pos, sc_len) in enumerate(starts):
        start = pos + sc_len
        end = starts[idx + 1][0] if idx + 1 < len(starts) else n
        out.append(buf[start:end])
    return out


def _strip_emulation_prevention(data: bytes) -> bytes:
    out = bytearray()
    n = len(data)
    i = 0
    while i < n:
        if i + 2 < n and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0x03:
            out.append(0)
            out.append(0)
            i += 3
        else:
            out.append(data[i])
            i += 1
    return bytes(out)


def parse_imu_samples(access_unit: bytes) -> list[dict]:
    """Walk an Annex-B access unit and return all Trinet IMU samples found in SEI NALs."""
    samples: list[dict] = []
    for nal in _split_annexb_nals(access_unit):
        if not nal:
            continue
        if (nal[0] & 0x1F) != 6:  # not SEI
            continue
        rbsp = _strip_emulation_prevention(nal[1:])
        i = 0
        n = len(rbsp)
        while i < n:
            # End-of-NAL trailing bits: a single 0x80 (or nothing meaningful) — stop.
            if n - i == 1:
                break
            # payload_type and payload_size are both encoded as sums of leading 0xFF
            # bytes plus a terminating non-0xFF byte (H.264 §7.3.2.3).
            payload_type = 0
            while i < n and rbsp[i] == 0xFF:
                payload_type += 255
                i += 1
            if i >= n:
                break
            payload_type += rbsp[i]
            i += 1
            payload_size = 0
            while i < n and rbsp[i] == 0xFF:
                payload_size += 255
                i += 1
            if i >= n:
                break
            payload_size += rbsp[i]
            i += 1
            if payload_size == 0 or i + payload_size > n:
                break
            payload = rbsp[i : i + payload_size]
            i += payload_size
            if payload_type != 5 or len(payload) < 23:
                continue
            if payload[:16] != TRINET_IMU_SEI_UUID:
                continue
            num_samples = int.from_bytes(payload[17:19], "little")
            off = 23
            for _ in range(num_samples):
                if off + _SAMPLE.size > len(payload):
                    break
                v = _SAMPLE.unpack_from(payload, off)
                off += _SAMPLE.size
                samples.append(
                    {
                        "ts_ns": v[0],
                        "accel": (v[1], v[2], v[3]),
                        "gyro": (v[4], v[5], v[6]),
                        "mag": (v[7], v[8], v[9]),
                        "temp_c": v[10],
                        "quat_xyzw": (v[11], v[12], v[13], v[14]),
                        "lin_accel": (v[15], v[16], v[17]),
                        "fsync_delay_us": v[18],
                    }
                )
    return samples


# --------------------------------------------------------------------------- #
# Platform device defaults
# --------------------------------------------------------------------------- #

def default_format() -> str:
    sysname = platform.system()
    return {"Linux": "v4l2", "Darwin": "avfoundation", "Windows": "dshow"}.get(sysname, "v4l2")


def list_device_candidates() -> list[str]:
    sysname = platform.system()
    if sysname == "Linux":
        return sorted(glob.glob("/dev/video*"))
    if sysname == "Darwin":
        # avfoundation expects an index for video (and optionally ":<audio>")
        return ["0", "1", "2"]
    if sysname == "Windows":
        return ["video=USB Video Device"]
    return []


# --------------------------------------------------------------------------- #
# Capture worker thread
# --------------------------------------------------------------------------- #

class CaptureWorker(threading.Thread):
    """Demux + decode in a background thread; push (frame_bgr, [samples]) to a queue."""

    def __init__(
        self,
        device: str,
        fmt: str,
        width: int,
        height: int,
        fps: int,
        out_queue: queue.Queue,
        stop_event: threading.Event,
    ):
        super().__init__(daemon=True)
        self.device = device
        self.fmt = fmt
        self.width = width
        self.height = height
        self.fps = fps
        self.out_queue = out_queue
        self.stop_event = stop_event
        self.error: Exception | None = None
        self.opened = threading.Event()

        scale = min(PREVIEW_MAX_W / width, PREVIEW_MAX_H / height, 1.0)
        self.preview_w = max(2, int(width * scale)) & ~1
        self.preview_h = max(2, int(height * scale)) & ~1

    def run(self) -> None:
        try:
            options = {
                "video_size": f"{self.width}x{self.height}",
                "framerate": str(self.fps),
                "input_format": "h264",
            }
            container = av.open(self.device, format=self.fmt, options=options)
        except Exception as exc:
            self.error = exc
            self.opened.set()
            return

        self.opened.set()
        try:
            stream = container.streams.video[0]
            stream.thread_type = "AUTO"
            for packet in container.demux(stream):
                if self.stop_event.is_set():
                    break
                pkt_bytes = bytes(packet) if packet.size else b""
                samples = parse_imu_samples(pkt_bytes) if pkt_bytes else []
                # Decode every packet (H.264 inter-frame deps), but only colour-
                # convert / downscale the latest frame in this AU — and skip even
                # that if the GUI is already behind.
                preview_rgb = None
                latest = None
                try:
                    for f in packet.decode():
                        latest = f
                except av.AVError:
                    latest = None
                if latest is not None and not self.out_queue.full():
                    try:
                        resized = latest.reformat(
                            width=self.preview_w,
                            height=self.preview_h,
                            format="rgb24",
                        )
                        preview_rgb = resized.to_ndarray()
                    except av.AVError:
                        preview_rgb = None
                try:
                    self.out_queue.put_nowait((preview_rgb, samples))
                except queue.Full:
                    try:
                        self.out_queue.get_nowait()
                    except queue.Empty:
                        pass
                    try:
                        self.out_queue.put_nowait((preview_rgb, samples))
                    except queue.Full:
                        pass
        except Exception as exc:
            self.error = exc
        finally:
            try:
                container.close()
            except Exception:
                pass


# --------------------------------------------------------------------------- #
# GUI
# --------------------------------------------------------------------------- #

# Trinet cameras only advertise this single H.264 mode over UVC.
CAPTURE_WIDTH = 1920
CAPTURE_HEIGHT = 1080
CAPTURE_FPS = 30

PREVIEW_MAX_W = 960
PREVIEW_MAX_H = 540
PLOT_WINDOW_SAMPLES = 1500  # ~2.7 s at 562 Hz
PLOT_MAX_POINTS = 300       # decimate plot for redraw cost
PLOT_REDRAW_HZ = 5
UI_TICK_MS = 33  # ~30 Hz


class LiveViewerApp:
    def __init__(self, root: tk.Tk, args: argparse.Namespace) -> None:
        self.root = root
        self.args = args
        self.width = CAPTURE_WIDTH
        self.height = CAPTURE_HEIGHT
        self.fps = CAPTURE_FPS
        self.frame_queue: queue.Queue = queue.Queue(maxsize=4)
        self.stop_event = threading.Event()
        self.worker: CaptureWorker | None = None
        self.preview_imgtk: ImageTk.PhotoImage | None = None

        # Rolling buffers for plots (timestamps in seconds, axes split by sensor).
        self._ts = deque(maxlen=PLOT_WINDOW_SAMPLES)
        self._accel = [deque(maxlen=PLOT_WINDOW_SAMPLES) for _ in range(3)]
        self._gyro = [deque(maxlen=PLOT_WINDOW_SAMPLES) for _ in range(3)]
        self._t0_ns: int | None = None

        # FPS / sample-rate counters.
        self._frames_since_tick = 0
        self._samples_since_tick = 0
        self._last_rate_t = time.monotonic()
        self._fps = 0.0
        self._sample_hz = 0.0
        self._last_plot_t = 0.0

        self._build_ui()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.after(UI_TICK_MS, self._tick)

    # -- UI layout --------------------------------------------------------- #

    def _build_ui(self) -> None:
        self.root.title("Trinet UVC Live Viewer")
        self.root.geometry("1400x780")
        self.root.minsize(1100, 640)

        top = ttk.Frame(self.root, padding=8)
        top.pack(fill="x")

        ttk.Label(top, text="Device:").pack(side="left")
        self.device_var = tk.StringVar(value=self.args.device)
        device_combo = ttk.Combobox(
            top, textvariable=self.device_var, width=32, values=list_device_candidates()
        )
        device_combo.pack(side="left", padx=4)

        ttk.Label(top, text="Format:").pack(side="left", padx=(8, 0))
        self.format_var = tk.StringVar(value=self.args.format)
        ttk.Combobox(
            top,
            textvariable=self.format_var,
            width=12,
            values=["v4l2", "avfoundation", "dshow"],
        ).pack(side="left", padx=4)

        ttk.Label(
            top,
            text=f"  Stream: {CAPTURE_WIDTH}x{CAPTURE_HEIGHT} @ {CAPTURE_FPS} fps H.264 (fixed)",
            foreground="#777",
        ).pack(side="left", padx=(8, 0))

        self.start_btn = ttk.Button(top, text="Start", command=self._on_start)
        self.start_btn.pack(side="left", padx=(16, 4))
        self.stop_btn = ttk.Button(top, text="Stop", command=self._on_stop, state="disabled")
        self.stop_btn.pack(side="left")

        self.status_var = tk.StringVar(value="idle")
        ttk.Label(top, textvariable=self.status_var, foreground="#555").pack(
            side="right", padx=8
        )

        body = ttk.Frame(self.root)
        body.pack(fill="both", expand=True)

        # Preview pane (left)
        preview_frame = ttk.Frame(body, padding=8)
        preview_frame.pack(side="left", fill="both", expand=True)
        self.preview_label = tk.Label(preview_frame, background="#111")
        self.preview_label.pack(fill="both", expand=True)

        # IMU pane (right)
        imu_frame = ttk.Frame(body, padding=8, width=440)
        imu_frame.pack(side="right", fill="y")
        imu_frame.pack_propagate(False)

        ttk.Label(imu_frame, text="IMU (latest)", font=("TkDefaultFont", 11, "bold")).pack(
            anchor="w"
        )
        self.imu_var = tk.StringVar(value="—")
        self.imu_label = ttk.Label(
            imu_frame,
            textvariable=self.imu_var,
            font=("TkFixedFont", 10),
            justify="left",
        )
        self.imu_label.pack(anchor="w", pady=(4, 8), fill="x")

        # Embedded matplotlib plots.
        self.fig = Figure(figsize=(4.4, 5.0), dpi=90, tight_layout=True)
        self.ax_accel = self.fig.add_subplot(2, 1, 1)
        self.ax_gyro = self.fig.add_subplot(2, 1, 2)
        self._init_axes()
        self.plot_canvas = FigureCanvasTkAgg(self.fig, master=imu_frame)
        self.plot_canvas.get_tk_widget().pack(fill="both", expand=True)

    def _init_axes(self) -> None:
        for ax, ylabel in ((self.ax_accel, "accel (m/s²)"), (self.ax_gyro, "gyro (rad/s)")):
            ax.clear()
            ax.set_ylabel(ylabel)
            ax.grid(True, alpha=0.3)
            ax.set_xlabel("t (s)")
        self.accel_lines = [
            self.ax_accel.plot([], [], label=lbl, linewidth=1)[0] for lbl in ("x", "y", "z")
        ]
        self.gyro_lines = [
            self.ax_gyro.plot([], [], label=lbl, linewidth=1)[0] for lbl in ("x", "y", "z")
        ]
        self.ax_accel.legend(loc="upper right", fontsize=8)
        self.ax_gyro.legend(loc="upper right", fontsize=8)

    # -- start / stop ------------------------------------------------------ #

    def _on_start(self) -> None:
        if self.worker is not None and self.worker.is_alive():
            return
        device = self.device_var.get().strip()
        fmt = self.format_var.get().strip()
        if not device:
            self.status_var.set("no device specified")
            return

        self._reset_buffers()
        self.stop_event = threading.Event()
        self.worker = CaptureWorker(
            device,
            fmt,
            self.width,
            self.height,
            self.fps,
            self.frame_queue,
            self.stop_event,
        )
        self.status_var.set(
            f"opening {device} ({fmt}, {self.width}x{self.height}@{self.fps}) …"
        )
        self.worker.start()
        self.start_btn.configure(state="disabled")
        self.stop_btn.configure(state="normal")
        self.root.after(150, self._check_open)

    def _check_open(self) -> None:
        if self.worker is None:
            return
        if not self.worker.opened.is_set():
            self.root.after(150, self._check_open)
            return
        if self.worker.error is not None:
            self.status_var.set(f"open failed: {self.worker.error}")
            self.start_btn.configure(state="normal")
            self.stop_btn.configure(state="disabled")
            self.worker = None
            return
        self.status_var.set("streaming")

    def _on_stop(self) -> None:
        self.stop_event.set()
        if self.worker is not None:
            self.worker.join(timeout=2.0)
        self.worker = None
        # Drain queue.
        try:
            while True:
                self.frame_queue.get_nowait()
        except queue.Empty:
            pass
        self.status_var.set("stopped")
        self.start_btn.configure(state="normal")
        self.stop_btn.configure(state="disabled")

    def _reset_buffers(self) -> None:
        self._ts.clear()
        for d in self._accel:
            d.clear()
        for d in self._gyro:
            d.clear()
        self._t0_ns = None
        self._frames_since_tick = 0
        self._samples_since_tick = 0
        self._last_rate_t = time.monotonic()
        self._fps = 0.0
        self._sample_hz = 0.0
        self._last_plot_t = 0.0
        self.imu_var.set("—")

    # -- per-tick UI refresh ---------------------------------------------- #

    def _tick(self) -> None:
        try:
            last_frame = None
            new_samples: list[dict] = []
            while True:
                try:
                    frame_bgr, samples = self.frame_queue.get_nowait()
                except queue.Empty:
                    break
                if frame_bgr is not None:
                    last_frame = frame_bgr
                    self._frames_since_tick += 1
                if samples:
                    new_samples.extend(samples)
                    self._samples_since_tick += len(samples)

            if last_frame is not None:
                self._render_frame(last_frame)
            if new_samples:
                self._consume_samples(new_samples)

            # rate counters
            now = time.monotonic()
            dt = now - self._last_rate_t
            if dt >= 1.0:
                self._fps = self._frames_since_tick / dt
                self._sample_hz = self._samples_since_tick / dt
                self._frames_since_tick = 0
                self._samples_since_tick = 0
                self._last_rate_t = now

            if new_samples:
                self._update_imu_text(new_samples[-1])
            if (now - self._last_plot_t) > (1.0 / PLOT_REDRAW_HZ) and len(self._ts) >= 2:
                self._redraw_plots()
                self._last_plot_t = now

            # Surface worker errors (e.g. device unplugged mid-stream).
            if self.worker is not None and not self.worker.is_alive():
                if self.worker.error is not None:
                    self.status_var.set(f"stream ended: {self.worker.error}")
                else:
                    self.status_var.set("stream ended")
                self.start_btn.configure(state="normal")
                self.stop_btn.configure(state="disabled")
                self.worker = None
        finally:
            self.root.after(UI_TICK_MS, self._tick)

    def _render_frame(self, rgb: np.ndarray) -> None:
        # Worker already produced display-sized RGB via libswscale — just hand
        # it to Tk. Image.fromarray is zero-copy on a contiguous uint8 array.
        img = Image.fromarray(rgb)
        self.preview_imgtk = ImageTk.PhotoImage(img)
        self.preview_label.configure(image=self.preview_imgtk)

    def _consume_samples(self, samples: list[dict]) -> None:
        if self._t0_ns is None and samples:
            self._t0_ns = samples[0]["ts_ns"]
        t0 = self._t0_ns or 0
        for s in samples:
            self._ts.append((s["ts_ns"] - t0) / 1e9)
            for k in range(3):
                self._accel[k].append(s["accel"][k])
                self._gyro[k].append(s["gyro"][k])

    def _update_imu_text(self, s: dict) -> None:
        ax, ay, az = s["accel"]
        gx, gy, gz = s["gyro"]
        mx, my, mz = s["mag"]
        text = (
            f"accel (m/s²)   x={ax:+8.3f}  y={ay:+8.3f}  z={az:+8.3f}\n"
            f"gyro  (rad/s)  x={gx:+8.4f}  y={gy:+8.4f}  z={gz:+8.4f}\n"
            f"mag   (µT)     x={mx:+8.2f}  y={my:+8.2f}  z={mz:+8.2f}\n"
            f"temp           {s['temp_c']:.2f} °C\n"
            f"fsync delay    {s['fsync_delay_us']:.1f} µs\n"
            f"\n"
            f"video        {self._fps:5.1f} fps\n"
            f"imu          {self._sample_hz:6.1f} Hz\n"
            f"buffer       {len(self._ts)} samples"
        )
        self.imu_var.set(text)

    def _redraw_plots(self) -> None:
        ts_all = list(self._ts)
        if not ts_all:
            return
        n = len(ts_all)
        stride = max(1, n // PLOT_MAX_POINTS)
        ts = ts_all[::stride]
        accel_d = [list(d)[::stride] for d in self._accel]
        gyro_d = [list(d)[::stride] for d in self._gyro]
        t_max = ts[-1]
        t_min = ts[0]
        for line, data in zip(self.accel_lines, accel_d):
            line.set_data(ts, data)
        for line, data in zip(self.gyro_lines, gyro_d):
            line.set_data(ts, data)
        self.ax_accel.set_xlim(t_min, t_max if t_max > t_min else t_min + 1e-3)
        self.ax_gyro.set_xlim(t_min, t_max if t_max > t_min else t_min + 1e-3)
        self.ax_accel.relim()
        self.ax_accel.autoscale_view(scalex=False, scaley=True)
        self.ax_gyro.relim()
        self.ax_gyro.autoscale_view(scalex=False, scaley=True)
        self.plot_canvas.draw_idle()

    def _on_close(self) -> None:
        self._on_stop()
        self.root.destroy()


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def _platform_default_device() -> str:
    sysname = platform.system()
    if sysname == "Linux":
        cands = list_device_candidates()
        return cands[0] if cands else "/dev/video0"
    if sysname == "Darwin":
        return "0"
    if sysname == "Windows":
        return "video=USB Video Device"
    return ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Trinet UVC live viewer")
    parser.add_argument(
        "--device",
        default=_platform_default_device(),
        help="UVC device (Linux: /dev/videoN, macOS: avfoundation index, Windows: 'video=<name>')",
    )
    parser.add_argument(
        "--format",
        default=default_format(),
        choices=["v4l2", "avfoundation", "dshow"],
        help="PyAV input format (auto-detected from OS by default)",
    )
    args = parser.parse_args(argv)

    root = tk.Tk()
    LiveViewerApp(root, args)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
