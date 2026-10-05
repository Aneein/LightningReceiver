"""Lightning Receiver - FM radio GUI (tkinter).

Talks to the FPGA through the JTAG-AXI bridge (tools/hw/lr_jtag_bridge.tcl,
started on demand), initialises the AD9361 with tools/hw/ad9361_jtag when
needed, streams the 48 kHz PCM from the DDR audio ring to ffplay and drives
the FPGA tuning / seek / panel registers.

    python tools/hw/lr_radio_gui.py        (or pythonw for no console)

All board access happens in one worker thread; the Tk thread only exchanges
messages with it through queues.
"""
import json
import math
import os
import queue
import shutil
import socket
import struct
import subprocess
import threading
import time
import wave
from pathlib import Path

import tkinter as tk
from tkinter import messagebox, ttk

try:
    import numpy as np
except ImportError:                      # volume/level still work without it
    np = None

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BRIDGE_TCL = HERE / "lr_jtag_bridge.tcl"
INIT_EXE = HERE / "ad9361_jtag" / "ad9361_jtag.exe"
VIVADO = Path(r"D:\Xilinx\Vivado\2021.1\bin\vivado.bat")
STATE_FILE = HERE / "lr_radio_gui.json"
REC_DIR = HERE / "recordings"
PORT = 5555

LR = 0x44A20000
AD_RX = 0x44A00000
R_ID, R_CONTROL, R_RF_FREQ, R_DDC = 0x000, 0x008, 0x010, 0x024
R_AUDIO_CFG, R_ERR = 0x038, 0x048
R_WR_WORDS, R_RING_BASE, R_RING_WORDS = 0x06C, 0x070, 0x074
R_UI, R_SEEK, R_SEEK_CFG, R_POWER, R_QUAL, R_THR = 0x07C, 0x080, 0x084, 0x088, 0x08C, 0x090
def id_ok(i):
    # any FM-family design from 0x4C520002 on
    return (i & 0xFFFFFF00) == 0x4C520000 and (i & 0xFF) >= 2
REC_BIT, DEEM75_BIT = 1 << 16, 1 << 18
WORD_BYTES = 32
START_LAG_WORDS = 600                    # ~0.2 s queued when audio (re)starts
FULL_SCALE_POWER = 32768.0 ** 2
SENSITIVITY = [("严格", 0x0133), ("标准", 0x0140), ("宽松", 0x015A), ("很宽松", 0x0173)]


def s32(v):
    return v - (1 << 32) if v & 0x80000000 else v


def cnr_db(flat):
    """Carrier-to-noise ratio from the envelope flatness (see fm_signal_meter)."""
    r = flat
    if r >= 1.999:
        return None
    if r <= 1.002:
        return 30.0
    a, b, c = 1.0 - r, 4.0 - 2.0 * r, 2.0 - r
    disc = b * b - 4 * a * c
    if disc < 0:
        return None
    s = (-b - math.sqrt(disc)) / (2 * a)
    return 10 * math.log10(s) if s > 0 else None


# ============================================================================
# Bridge connection
# ============================================================================
class Bridge:
    def __init__(self, port=PORT, timeout=5.0):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.s.settimeout(30.0)
        self.f = self.s.makefile("rw", newline="\n")

    def cmd(self, c):
        self.f.write(c + "\n")
        self.f.flush()
        r = self.f.readline().strip()
        if not r.startswith("OK"):
            raise RuntimeError(f"bridge: {c} -> {r or 'connection closed'}")
        return r

    def rd(self, addr):
        return int(self.cmd(f"R {addr:08X}").split()[1], 16)

    def wr(self, addr, v):
        self.cmd(f"W {addr:08X} {v & 0xFFFFFFFF:08X}")

    def lr(self, off):
        return self.rd(LR + off)

    def lw(self, off, v):
        self.wr(LR + off, v)

    def words(self, addr, nwords):
        out = bytearray()
        a, end = addr, addr + nwords * WORD_BYTES
        while a < end:
            ce = min(end, (a // 1024 + 1) * 1024)
            for w in self.cmd(f"B {a:08X} {(ce - a) // 4}").split()[1:]:
                out += struct.pack("<I", int(w, 16))
            a = ce
        return bytes(out)

    def close(self):
        try:
            self.f.write("Q\n")
            self.f.flush()
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


# ============================================================================
# Worker thread: owns the bridge, the audio stream and ffplay
# ============================================================================
class Worker(threading.Thread):
    def __init__(self, cmdq, outq):
        super().__init__(daemon=True)
        self.cmdq, self.outq = cmdq, outq
        self.br = None
        self.player = None
        self.running = True
        self.volume = 0.8
        self.muted = False
        self.audio_on = True
        self.rp = None
        self.ring = self.base = 0
        self.lo = 0
        self.lost = 0
        self.rec = None                  # (wave writer, path, start time)
        self.cfg_rec_saved = None
        self.radio_ready = False
        self.level_db = -90.0
        self.last_poll = 0.0
        self.bridge_proc = None

    # ---------------- helpers ----------------
    def post(self, kind, **kw):
        self.outq.put((kind, kw))

    def disconnect(self, why=""):
        if self.br:
            try:
                if self.cfg_rec_saved is not None:
                    self.br.lw(R_AUDIO_CFG, (self.br.lr(R_AUDIO_CFG) & ~REC_BIT) |
                               (self.cfg_rec_saved & REC_BIT))
            except Exception:
                pass
            self.br.close()
        self.br = None
        self.rp = None
        self.cfg_rec_saved = None
        self.radio_ready = False
        self.post("conn", ok=False, msg=why)

    def ensure_player(self):
        if self.player and self.player.poll() is None:
            return True
        ff = shutil.which("ffplay")
        if not ff:
            self.post("error", msg="未找到 ffplay，无法播放（请安装 ffmpeg）。")
            self.audio_on = False
            return False
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        self.player = subprocess.Popen(
            [ff, "-hide_banner", "-loglevel", "error", "-nodisp",
             "-f", "s16le", "-ar", "48000", "-ch_layout", "mono",
             "-fflags", "nobuffer", "-flags", "low_delay", "-i", "-"],
            stdin=subprocess.PIPE, creationflags=flags)
        return True

    def stop_player(self):
        if self.player:
            try:
                self.player.stdin.close()
            except OSError:
                pass
            self.player.terminate()
            self.player = None

    def connect(self):
        try:
            self.br = Bridge()
            ident = self.br.lr(R_ID)
            if not id_ok(ident):
                self.br.close()
                self.br = None
                self.post("conn", ok=False, msg=f"设计 ID 0x{ident:08X} 不是 FM 版本")
                return
            self.base = self.br.lr(R_RING_BASE)
            self.ring = self.br.lr(R_RING_WORDS)
            cfg = self.br.lr(R_AUDIO_CFG)
            self.cfg_rec_saved = cfg
            self.br.lw(R_AUDIO_CFG, cfg | REC_BIT)
            self.rp = None
            self.post("conn", ok=True, msg=f"已连接，设计 ID 0x{ident:08X}")
        except OSError:
            self.br = None
            self.post("conn", ok=False, msg="JTAG 桥未运行")
        except Exception as e:                       # noqa: BLE001
            self.disconnect(str(e))

    # ---------------- audio ----------------
    def pump_audio(self):
        if not (self.audio_on and self.radio_ready):
            return False
        wp = self.br.lr(R_WR_WORDS)
        if self.rp is None:
            self.rp = (wp - START_LAG_WORDS) & 0xFFFFFFFF
        avail = (wp - self.rp) & 0xFFFFFFFF
        if avail > self.ring - 2048:
            self.lost += avail
            self.rp = (wp - START_LAG_WORDS) & 0xFFFFFFFF
            avail = START_LAG_WORDS
        if avail == 0:
            return False
        avail = min(avail, 1500)
        first = self.rp % self.ring
        n1 = min(avail, self.ring - first)
        pcm = self.br.words(self.base + first * WORD_BYTES, n1)
        if avail > n1:
            pcm += self.br.words(self.base, avail - n1)
        self.rp = (self.rp + avail) & 0xFFFFFFFF

        if self.rec:
            self.rec[0].writeframes(pcm)
        if np is not None:
            x = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
            rms = float(np.sqrt(np.mean(x * x))) if x.size else 0.0
            self.level_db = 20 * math.log10(max(rms, 1.0) / 32768.0)
            gain = 0.0 if self.muted else self.volume
            if gain != 1.0:
                x = np.clip(x * gain, -32768, 32767)
            out = x.astype("<i2").tobytes()
        else:
            out = bytes(len(pcm)) if self.muted else pcm
        if self.ensure_player():
            try:
                self.player.stdin.write(out)
                self.player.stdin.flush()
            except (BrokenPipeError, OSError):
                self.stop_player()
        return True

    # ---------------- status ----------------
    def poll_status(self):
        b = self.br
        self.lo = b.lr(R_RF_FREQ)
        ddc = s32(b.lr(R_DDC))
        q = b.lr(R_QUAL)
        p = b.lr(R_POWER)
        ui = b.lr(R_UI)
        sk = b.lr(R_SEEK)
        err = b.lr(R_ERR)
        ctrl = b.lr(R_CONTROL)
        acfg = b.lr(R_AUDIO_CFG)
        thr = b.lr(R_THR) & 0xFFFF
        rng = (b.lr(R_SEEK_CFG) >> 16) * 1000
        if not acfg & REC_BIT:
            # Live audio rides on the DDR audio ring: if the front-panel KEY3
            # (or anything else) switched recording off, switch it back on.
            b.lw(R_AUDIO_CFG, acfg | REC_BIT)
            acfg |= REC_BIT
            self.post("info", msg="实时播放依赖板上 DDR 音频录制，已自动重新开启（KEY3 在 GUI 运行时无效）")
        rstn = b.rd(AD_RX + 0x40)
        adc_active = bool((ui >> 22) & 1)
        self.radio_ready = (rstn & 3) == 3 and adc_active
        lag_ms = None
        if self.rp is not None:
            lag_ms = ((b.lr(R_WR_WORDS) - self.rp) & 0xFFFFFFFF) * 16 / 48.0
        self.post("status", lo=self.lo, freq=self.lo + ddc, ddc=ddc,
                  flat=(q & 0xFFFF) / 256.0, station=bool((q >> 16) & 1),
                  power=p, leds=(ui >> 16) & 0xF, lock=bool((ui >> 20) & 1),
                  fm=bool((ui >> 21) & 1), adc=adc_active, seek=sk, err=err,
                  ctrl=ctrl, deem75=bool(acfg & DEEM75_BIT), thr=thr,
                  range_hz=rng, radio_ready=self.radio_ready,
                  level_db=self.level_db, lag_ms=lag_ms, lost=self.lost,
                  rec=(time.time() - self.rec[2]) if self.rec else None)

    def wait_block(self, n=2):
        for _ in range(n):
            c = self.br.lr(R_QUAL) >> 24
            t0 = time.time()
            while (self.br.lr(R_QUAL) >> 24) == c:
                if time.time() - t0 > 0.2:
                    return False
        return True

    def scan(self):
        b = self.br
        lo = b.lr(R_RF_FREQ)
        rng = (b.lr(R_SEEK_CFG) >> 16) * 1000
        thr = (b.lr(R_THR) & 0xFFFF) / 256.0
        ddc0 = b.lr(R_DDC)
        muted0 = self.muted
        self.muted = True
        f = math.ceil((lo - rng) / 100_000) * 100_000
        stop = lo + rng
        grid = []
        while f <= stop:
            grid.append(f)
            f += 100_000
        rows = []
        for i, fhz in enumerate(grid):
            b.lw(R_DDC, fhz - lo)
            time.sleep(0.01)
            if not self.wait_block(2):
                break
            q = b.lr(R_QUAL)
            rows.append((fhz, b.lr(R_POWER), (q & 0xFFFF) / 256.0))
            if i % 8 == 0:
                self.post("scan_progress", done=i + 1, total=len(grid))
                self.pump_audio()               # keep the stream fed (muted)
        b.lw(R_DDC, ddc0)
        self.muted = muted0
        if not rows:
            self.post("error", msg="扫描失败：没有收到测量结果（射频是否已初始化？）")
            return
        med = sorted(r[1] for r in rows)[len(rows) // 2] or 1
        pw = {r[0]: r[1] for r in rows}
        found = []
        for fhz, p, fl in rows:
            peak = p >= pw.get(fhz - 100_000, 0) and p >= pw.get(fhz + 100_000, 0)
            if peak and fl <= max(thr, 1.45):
                found.append({"freq": fhz, "flat": round(fl, 3),
                              "snr_db": round(10 * math.log10(max(p, 1) / med), 1),
                              "station": fl <= thr})
        found.sort(key=lambda d: d["freq"])
        self.post("scan_done", stations=found, noise=med)

    def init_radio(self, lo_hz, tune_hz):
        if not INIT_EXE.exists():
            self.post("error", msg=f"找不到 {INIT_EXE}")
            return
        self.post("busy", msg="正在初始化 AD9361（约 20 秒）…")
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        args = [str(INIT_EXE), "--lo-hz", str(int(lo_hz)), "--tune-hz", str(int(tune_hz))]
        if self.deem75_pref:
            args += ["--deemph", "75"]
        r = subprocess.run(args, capture_output=True, text=True, creationflags=flags)
        ok = r.returncode == 0 and "AD9361_BRINGUP_OK" in r.stdout
        self.rp = None
        self.post("busy", msg="")
        if not ok:
            tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
            self.post("error", msg="AD9361 初始化失败：\n" + "\n".join(tail))
        else:
            self.post("info", msg=f"射频已初始化：本振 {lo_hz / 1e6:.3f} MHz")

    def start_bridge(self):
        if not VIVADO.exists():
            self.post("error", msg=f"找不到 {VIVADO}")
            return
        env = dict(os.environ, PROCESSOR_ARCHITECTURE="AMD64")
        log = open(HERE / "bridge.log", "w")
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        self.post("busy", msg="正在启动 JTAG 桥（Vivado，约 30 秒）…")
        self.bridge_proc = subprocess.Popen(
            [str(VIVADO), "-mode", "batch", "-nojournal", "-nolog",
             "-source", str(BRIDGE_TCL)],
            cwd=str(ROOT), env=env, stdout=log, stderr=subprocess.STDOUT,
            creationflags=flags)
        t0 = time.time()
        while time.time() - t0 < 120:
            if self.bridge_proc.poll() is not None:
                break
            try:
                socket.create_connection(("127.0.0.1", PORT), timeout=1).close()
                self.post("busy", msg="")
                return
            except OSError:
                time.sleep(1.0)
        self.post("busy", msg="")
        self.post("error", msg="JTAG 桥启动失败，详见 tools/hw/bridge.log")

    # ---------------- command handling ----------------
    def handle(self, cmd, kw):
        b = self.br
        if cmd == "start_bridge":
            self.start_bridge()
            return
        if b is None:
            return
        if cmd == "seek":
            b.lw(R_SEEK, 1 if kw["up"] else 2)
        elif cmd == "cancel_seek":
            b.lw(R_SEEK, 3)
        elif cmd == "step":
            ddc = s32(b.lr(R_DDC)) + kw["hz"]
            rng = (b.lr(R_SEEK_CFG) >> 16) * 1000
            if abs(ddc) <= rng:
                b.lw(R_DDC, ddc)
            else:
                self.post("info", msg="已到当前调谐窗口边界，可直接输入频率以重新设置本振。")
        elif cmd == "tune":
            lo = b.lr(R_RF_FREQ)
            rng = (b.lr(R_SEEK_CFG) >> 16) * 1000
            ddc = kw["hz"] - lo
            if abs(ddc) <= rng:
                b.lw(R_DDC, ddc)
            else:
                self.post("need_retune", hz=kw["hz"])
        elif cmd == "retune":
            # LO 50 kHz below a 100 kHz grid point keeps stations off DC.
            hz = kw["hz"]
            self.init_radio(hz - 50_000, hz)
        elif cmd == "init_radio":
            lo = b.lr(R_RF_FREQ) or 97_950_000
            if lo < 70_000_000:
                lo = 97_950_000
            self.init_radio(lo, kw.get("tune", lo + 50_000))
        elif cmd == "zero":
            b.lw(R_DDC, 0)
        elif cmd == "deemph":
            cfg = b.lr(R_AUDIO_CFG)
            b.lw(R_AUDIO_CFG, (cfg | DEEM75_BIT) if kw["us75"] else (cfg & ~DEEM75_BIT))
        elif cmd == "lock":
            c = b.lr(R_CONTROL) & ~4
            b.lw(R_CONTROL, (c | 2) if kw["on"] else (c & ~2))
        elif cmd == "clear_err":
            b.lw(R_CONTROL, (b.lr(R_CONTROL) & ~4) | 4)
        elif cmd == "threshold":
            t = b.lr(R_THR)
            b.lw(R_THR, (t & 0xFFFF0000) | kw["value"])
        elif cmd == "scan":
            self.scan()
        elif cmd == "rec_start":
            REC_DIR.mkdir(exist_ok=True)
            fhz = self.lo + s32(b.lr(R_DDC))
            path = REC_DIR / time.strftime(f"FM_{fhz / 1e6:.1f}MHz_%Y%m%d_%H%M%S.wav")
            w = wave.open(str(path), "wb")
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(48000)
            self.rec = (w, path, time.time())
        elif cmd == "rec_stop":
            if self.rec:
                self.rec[0].close()
                self.post("info", msg=f"录音已保存：{self.rec[1]}")
                self.rec = None

    def run(self):
        self.deem75_pref = False
        while self.running:
            try:
                while True:
                    cmd, kw = self.cmdq.get_nowait()
                    if cmd == "quit":
                        self.running = False
                        break
                    if cmd == "volume":
                        self.volume = kw["value"]
                    elif cmd == "mute":
                        self.muted = kw["on"]
                    elif cmd == "audio":
                        self.audio_on = kw["on"]
                        if not self.audio_on:
                            self.stop_player()
                    elif cmd == "deemph_pref":
                        self.deem75_pref = kw["us75"]
                    else:
                        self.handle(cmd, kw)
            except queue.Empty:
                pass
            except Exception as e:                       # noqa: BLE001
                self.disconnect(f"连接中断：{e}")
            if not self.running:
                break
            if self.br is None:
                self.connect()
                if self.br is None:
                    time.sleep(1.0)
                    continue
            try:
                fed = self.pump_audio()
                if time.time() - self.last_poll > 0.25:
                    self.last_poll = time.time()
                    self.poll_status()
                if not fed:
                    time.sleep(0.02)
            except Exception as e:                       # noqa: BLE001
                self.disconnect(f"连接中断：{e}")
                time.sleep(1.0)
        # shutdown
        if self.rec:
            self.rec[0].close()
        self.stop_player()
        self.disconnect()
        if self.bridge_proc and self.bridge_proc.poll() is None:
            self.bridge_proc.terminate()


# ============================================================================
# GUI
# ============================================================================
class RadioGUI:
    BG, PANEL, FG, DIM, ACC = "#16181d", "#1f2229", "#e8eaed", "#8a9099", "#4fc3f7"
    GOOD, WARN, BAD = "#66bb6a", "#ffb74d", "#ef5350"

    def __init__(self, root):
        self.root = root
        self.cmdq, self.outq = queue.Queue(), queue.Queue()
        self.worker = Worker(self.cmdq, self.outq)
        self.state = self.load_state()
        self.connected = False
        self.radio_ready = False
        self.last = {}
        self.noise = self.state.get("noise")
        self.busy_msg = ""
        self.build()
        self.worker.start()
        self.send("volume", value=self.vol.get() / 100.0)
        self.send("deemph_pref", us75=self.deem.get() == 75)
        self.root.after(100, self.pump)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---------------- persistence ----------------
    def load_state(self):
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def save_state(self):
        self.state["volume"] = self.vol.get()
        self.state["sensitivity"] = self.sens.get()
        self.state["deemph"] = self.deem.get()
        try:
            STATE_FILE.write_text(json.dumps(self.state, ensure_ascii=False, indent=1),
                                  encoding="utf-8")
        except OSError:
            pass

    def send(self, cmd, **kw):
        self.cmdq.put((cmd, kw))

    # ---------------- layout ----------------
    def build(self):
        r = self.root
        r.title("Lightning Receiver · FM 收音机")
        r.configure(bg=self.BG)
        r.minsize(900, 560)
        st = ttk.Style()
        st.theme_use("clam")
        st.configure(".", background=self.BG, foreground=self.FG, fieldbackground=self.PANEL)
        st.configure("TFrame", background=self.BG)
        st.configure("Panel.TFrame", background=self.PANEL)
        st.configure("TLabel", background=self.BG, foreground=self.FG)
        st.configure("Panel.TLabel", background=self.PANEL, foreground=self.FG)
        st.configure("Dim.TLabel", background=self.PANEL, foreground=self.DIM)
        st.configure("TButton", background="#2b2f38", foreground=self.FG, padding=6)
        st.map("TButton", background=[("active", "#38404d"), ("disabled", "#23262d")],
               foreground=[("disabled", "#5c6370")])
        st.configure("Accent.TButton", background="#1e6f95")
        st.configure("TCheckbutton", background=self.PANEL, foreground=self.FG)
        st.configure("TRadiobutton", background=self.PANEL, foreground=self.FG)
        st.configure("Treeview", background=self.PANEL, foreground=self.FG,
                     fieldbackground=self.PANEL, rowheight=24)
        st.configure("Treeview.Heading", background="#2b2f38", foreground=self.FG)
        st.configure("Horizontal.TProgressbar", background=self.ACC)

        # --- connection bar ---
        top = ttk.Frame(r, padding=(12, 8))
        top.pack(fill="x")
        self.conn_lbl = ttk.Label(top, text="● 正在连接…", foreground=self.WARN)
        self.conn_lbl.pack(side="left")
        self.btn_bridge = ttk.Button(top, text="启动 JTAG 桥", command=lambda: self.send("start_bridge"))
        self.btn_init = ttk.Button(top, text="初始化射频", command=self.on_init_radio)
        self.busy_lbl = ttk.Label(top, text="", foreground=self.ACC)
        self.busy_lbl.pack(side="right")

        body = ttk.Frame(r, padding=(12, 0, 12, 8))
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        # --- left: tuner ---
        left = ttk.Frame(body, style="Panel.TFrame", padding=16)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        self.freq_lbl = tk.Label(left, text="--.--", font=("Segoe UI", 54, "bold"),
                                 bg=self.PANEL, fg=self.FG)
        self.freq_lbl.pack(anchor="w")
        row = ttk.Frame(left, style="Panel.TFrame")
        row.pack(anchor="w", fill="x")
        ttk.Label(row, text="MHz", style="Dim.TLabel", font=("Segoe UI", 14)).pack(side="left")
        self.badge = tk.Label(row, text="", font=("Segoe UI", 11, "bold"), bg=self.PANEL,
                              fg=self.DIM, padx=10)
        self.badge.pack(side="left", padx=12)
        self.win_lbl = ttk.Label(row, text="", style="Dim.TLabel")
        self.win_lbl.pack(side="right")

        meters = ttk.Frame(left, style="Panel.TFrame")
        meters.pack(fill="x", pady=(14, 6))
        self.m_cnr = self.meter(meters, "信号质量")
        self.m_pow = self.meter(meters, "信号电平")
        self.m_aud = self.meter(meters, "音频电平")

        tune = ttk.Frame(left, style="Panel.TFrame")
        tune.pack(fill="x", pady=(10, 4))
        self.btn_sd = ttk.Button(tune, text="◀◀ 搜台", command=lambda: self.seek(False))
        self.btn_m = ttk.Button(tune, text="−0.1", width=6, command=lambda: self.send("step", hz=-100_000))
        self.btn_p = ttk.Button(tune, text="+0.1", width=6, command=lambda: self.send("step", hz=100_000))
        self.btn_su = ttk.Button(tune, text="搜台 ▶▶", command=lambda: self.seek(True))
        for i, w in enumerate((self.btn_sd, self.btn_m, self.btn_p, self.btn_su)):
            w.grid(row=0, column=i, padx=4, sticky="ew")
            tune.columnconfigure(i, weight=1)

        ent = ttk.Frame(left, style="Panel.TFrame")
        ent.pack(fill="x", pady=(8, 4))
        ttk.Label(ent, text="频率", style="Panel.TLabel").pack(side="left")
        self.ent = ttk.Entry(ent, width=10, font=("Segoe UI", 12))
        self.ent.pack(side="left", padx=6)
        self.ent.bind("<Return>", lambda e: self.on_tune())
        ttk.Label(ent, text="MHz", style="Dim.TLabel").pack(side="left")
        ttk.Button(ent, text="调谐", command=self.on_tune).pack(side="left", padx=6)
        ttk.Button(ent, text="★ 收藏", command=self.on_fav).pack(side="right")

        audio = ttk.Frame(left, style="Panel.TFrame")
        audio.pack(fill="x", pady=(14, 0))
        ttk.Label(audio, text="音量", style="Panel.TLabel").pack(side="left")
        self.vol = tk.IntVar(value=int(self.state.get("volume", 80)))
        ttk.Scale(audio, from_=0, to=100, variable=self.vol, length=180,
                  command=lambda v: self.send("volume", value=float(v) / 100.0)).pack(side="left", padx=6)
        self.mute = tk.BooleanVar(value=False)
        ttk.Checkbutton(audio, text="静音", variable=self.mute,
                        command=lambda: self.send("mute", on=self.mute.get())).pack(side="left", padx=8)
        self.btn_rec = ttk.Button(audio, text="● 录音", command=self.on_rec)
        self.btn_rec.pack(side="right")
        self.rec_lbl = ttk.Label(audio, text="", style="Dim.TLabel")
        self.rec_lbl.pack(side="right", padx=8)

        # --- right: stations ---
        right = ttk.Frame(body, style="Panel.TFrame", padding=12)
        right.grid(row=0, column=1, sticky="nsew")
        hdr = ttk.Frame(right, style="Panel.TFrame")
        hdr.pack(fill="x")
        ttk.Label(hdr, text="电台", style="Panel.TLabel", font=("Segoe UI", 12, "bold")).pack(side="left")
        self.btn_scan = ttk.Button(hdr, text="扫描全波段", command=self.on_scan)
        self.btn_scan.pack(side="right")
        self.prog = ttk.Progressbar(right, mode="determinate")
        self.prog.pack(fill="x", pady=6)
        self.tree = ttk.Treeview(right, columns=("f", "q", "k"), show="headings", height=12)
        self.tree.heading("f", text="频率 MHz")
        self.tree.heading("q", text="信噪比")
        self.tree.heading("k", text="")
        self.tree.column("f", width=90, anchor="center")
        self.tree.column("q", width=80, anchor="center")
        self.tree.column("k", width=70, anchor="center")
        self.tree.pack(fill="both", expand=True)
        self.tree.bind("<Double-1>", self.on_pick)
        self.tree.tag_configure("st", foreground=self.FG)
        self.tree.tag_configure("weak", foreground=self.DIM)
        self.tree.tag_configure("fav", foreground=self.WARN)
        ttk.Label(right, text="双击收听  ·  灰色为接近阈值的弱台", style="Dim.TLabel").pack(anchor="w", pady=(4, 0))
        self.fill_tree()

        # --- bottom: settings + board status ---
        bot = ttk.Frame(r, style="Panel.TFrame", padding=(12, 8))
        bot.pack(fill="x", padx=12, pady=(0, 12))
        ttk.Label(bot, text="搜台灵敏度", style="Panel.TLabel").pack(side="left")
        self.sens = tk.StringVar(value=self.state.get("sensitivity", "标准"))
        cb = ttk.Combobox(bot, textvariable=self.sens, values=[s for s, _ in SENSITIVITY],
                          width=6, state="readonly")
        cb.pack(side="left", padx=6)
        cb.bind("<<ComboboxSelected>>", lambda e: self.apply_sensitivity())
        ttk.Label(bot, text="去加重", style="Panel.TLabel").pack(side="left", padx=(16, 4))
        self.deem = tk.IntVar(value=int(self.state.get("deemph", 50)))
        for us in (50, 75):
            ttk.Radiobutton(bot, text=f"{us} µs", value=us, variable=self.deem,
                            command=self.on_deemph).pack(side="left")
        self.lock = tk.BooleanVar(value=False)
        ttk.Checkbutton(bot, text="锁定板上按键", variable=self.lock,
                        command=lambda: self.send("lock", on=self.lock.get())).pack(side="left", padx=16)

        self.leds = []
        ledf = ttk.Frame(bot, style="Panel.TFrame")
        ledf.pack(side="right")
        for name in ("系统", "调谐", "录制", "网络"):
            c = tk.Canvas(ledf, width=14, height=14, bg=self.PANEL, highlightthickness=0)
            c.create_oval(2, 2, 12, 12, fill="#333", outline="", tags="led")
            c.pack(side="left", padx=(8, 2))
            ttk.Label(ledf, text=name, style="Dim.TLabel").pack(side="left")
            self.leds.append(c)
        self.err_btn = ttk.Button(bot, text="错误: --", command=lambda: self.send("clear_err"))
        self.err_btn.pack(side="right", padx=12)
        self.stat_lbl = ttk.Label(bot, text="", style="Dim.TLabel")
        self.stat_lbl.pack(side="right", padx=8)

        def key(fn):
            # shortcuts are ignored while typing in the frequency entry
            return lambda e: None if r.focus_get() is self.ent else fn()
        r.bind("<Left>", key(lambda: self.send("step", hz=-100_000)))
        r.bind("<Right>", key(lambda: self.send("step", hz=100_000)))
        r.bind("<Prior>", key(lambda: self.seek(True)))
        r.bind("<Next>", key(lambda: self.seek(False)))
        self.set_enabled(False)

    def meter(self, parent, label):
        f = ttk.Frame(parent, style="Panel.TFrame")
        f.pack(fill="x", pady=3)
        ttk.Label(f, text=label, style="Dim.TLabel", width=8).pack(side="left")
        c = tk.Canvas(f, height=14, bg="#2b2f38", highlightthickness=0)
        c.pack(side="left", fill="x", expand=True, padx=6)
        c.create_rectangle(0, 0, 0, 14, fill=self.ACC, outline="", tags="bar")
        v = ttk.Label(f, text="", style="Panel.TLabel", width=10)
        v.pack(side="left")
        return c, v

    def set_meter(self, m, frac, text, color=None):
        c, v = m
        w = max(c.winfo_width(), 1)
        c.coords("bar", 0, 0, int(w * max(0.0, min(1.0, frac))), 14)
        c.itemconfigure("bar", fill=color or self.ACC)
        v.configure(text=text)

    def set_enabled(self, on):
        for w in (self.btn_sd, self.btn_m, self.btn_p, self.btn_su, self.btn_scan, self.btn_rec):
            w.state(["!disabled"] if on else ["disabled"])

    # ---------------- stations list ----------------
    def fill_tree(self):
        self.tree.delete(*self.tree.get_children())
        favs = set(self.state.get("favorites", []))
        rows = {d["freq"]: d for d in self.state.get("stations", [])}
        for f in favs:
            rows.setdefault(f, {"freq": f, "snr_db": None, "station": True})
        for f in sorted(rows):
            d = rows[f]
            snr = f"{d['snr_db']:+.1f} dB" if d.get("snr_db") is not None else ""
            tag = "fav" if f in favs else ("st" if d.get("station") else "weak")
            kind = "★" if f in favs else ("有台" if d.get("station") else "弱")
            self.tree.insert("", "end", iid=str(f), values=(f"{f / 1e6:.1f}", snr, kind), tags=(tag,))

    def on_pick(self, _e):
        sel = self.tree.selection()
        if sel:
            self.tune_to(int(sel[0]))

    def on_fav(self):
        f = self.last.get("freq")
        if not f:
            return
        f = int(round(f / 100_000) * 100_000)
        favs = self.state.setdefault("favorites", [])
        if f in favs:
            favs.remove(f)
        else:
            favs.append(f)
        self.save_state()
        self.fill_tree()

    # ---------------- actions ----------------
    def seek(self, up):
        if self.last.get("seek", 0) & 1:
            self.send("cancel_seek")
        else:
            self.send("seek", up=up)

    def tune_to(self, hz):
        self.send("tune", hz=int(hz))

    def on_tune(self):
        try:
            mhz = float(self.ent.get().strip())
        except ValueError:
            messagebox.showwarning("频率", "请输入频率，例如 99.1")
            return
        if not 70.0 <= mhz <= 6000.0:
            messagebox.showwarning("频率", "AD9361 接收范围为 70 MHz – 6 GHz")
            return
        self.tune_to(round(mhz * 10) * 100_000)

    def on_scan(self):
        self.prog["value"] = 0
        self.btn_scan.state(["disabled"])
        self.send("scan")

    def on_rec(self):
        if self.last.get("rec") is None:
            self.send("rec_start")
        else:
            self.send("rec_stop")

    def on_deemph(self):
        self.send("deemph", us75=self.deem.get() == 75)
        self.send("deemph_pref", us75=self.deem.get() == 75)
        self.save_state()

    def apply_sensitivity(self):
        v = dict(SENSITIVITY).get(self.sens.get(), 0x0140)
        self.send("threshold", value=v)
        self.save_state()

    def on_init_radio(self):
        self.send("init_radio")

    # ---------------- message pump ----------------
    def pump(self):
        try:
            while True:
                kind, kw = self.outq.get_nowait()
                getattr(self, "on_" + kind)(**kw)
        except queue.Empty:
            pass
        self.root.after(80, self.pump)

    def on_conn(self, ok, msg):
        was = self.connected
        self.connected = ok
        self.conn_lbl.configure(text=("● " if ok else "○ ") + msg,
                                foreground=self.GOOD if ok else self.BAD)
        if ok:
            self.btn_bridge.pack_forget()
            if not was:
                self.apply_sensitivity()
                self.send("deemph", us75=self.deem.get() == 75)
        else:
            self.btn_bridge.pack(side="left", padx=10)
            self.btn_init.pack_forget()
            self.set_enabled(False)

    def on_status(self, **s):
        self.last = s
        ready = s["radio_ready"]
        if ready != self.radio_ready or not hasattr(self, "_shown"):
            self._shown = True
            self.radio_ready = ready
            if ready:
                self.btn_init.pack_forget()
            else:
                self.btn_init.pack(side="left", padx=10)
            self.set_enabled(ready and not self.busy_msg)
        self.freq_lbl.configure(text=f"{s['freq'] / 1e6:.2f}")
        lo, rng = s["lo"], s["range_hz"]
        self.win_lbl.configure(text=f"调谐窗口 {(lo - rng) / 1e6:.1f}–{(lo + rng) / 1e6:.1f} MHz")
        seeking = bool(s["seek"] & 1)
        if not ready:
            self.badge.configure(text="射频未初始化", fg=self.BAD)
        elif seeking:
            self.badge.configure(text="搜台中…", fg=self.ACC)
        elif s["station"]:
            self.badge.configure(text="有台", fg=self.GOOD)
        else:
            self.badge.configure(text="无台", fg=self.DIM)
        self.btn_su.configure(text="停止" if seeking else "搜台 ▶▶")
        self.btn_sd.configure(text="停止" if seeking else "◀◀ 搜台")

        c = cnr_db(s["flat"]) if ready else None
        if c is None:
            self.set_meter(self.m_cnr, 0, "< 0 dB" if ready else "--", self.BAD)
        else:
            col = self.GOOD if c >= 10 else (self.WARN if c >= 6 else self.BAD)
            self.set_meter(self.m_cnr, c / 30.0, f"{c:4.1f} dB", col)
        p = s["power"]
        dbfs = 10 * math.log10(max(p, 1) / FULL_SCALE_POWER)
        self.set_meter(self.m_pow, (dbfs + 90) / 90.0, f"{dbfs:5.1f} dBFS")
        a = s["level_db"]
        self.set_meter(self.m_aud, (a + 60) / 60.0, f"{a:5.1f} dBFS",
                       self.BAD if a > -1 else self.ACC)

        colors = [self.GOOD, self.ACC, self.BAD, self.WARN]
        for i, cv in enumerate(self.leds):
            cv.itemconfigure("led", fill=colors[i] if (s["leds"] >> i) & 1 else "#333")
        err = s["err"] & 0xFF
        self.err_btn.configure(text="错误: 无" if err == 0 else f"错误 0x{err:02X}（点击清除）")
        lag = s["lag_ms"]
        self.stat_lbl.configure(text=(f"延迟 {lag:.0f} ms" if lag is not None else "") +
                                (f" · 丢失 {s['lost']}" if s["lost"] else ""))
        self.lock.set(s["lock"])
        if s["rec"] is None:
            self.btn_rec.configure(text="● 录音")
            self.rec_lbl.configure(text="")
        else:
            self.btn_rec.configure(text="■ 停止录音")
            t = int(s["rec"])
            self.rec_lbl.configure(text=f"{t // 60:02d}:{t % 60:02d}", foreground=self.BAD)

    def on_scan_progress(self, done, total):
        self.prog["value"] = 100.0 * done / max(total, 1)

    def on_scan_done(self, stations, noise):
        self.prog["value"] = 100
        self.btn_scan.state(["!disabled"])
        self.state["stations"] = stations
        self.state["noise"] = noise
        self.save_state()
        self.fill_tree()
        n = sum(1 for d in stations if d["station"])
        self.busy_lbl.configure(text=f"扫描完成：{n} 个电台，{len(stations) - n} 个弱台")

    def on_need_retune(self, hz):
        if messagebox.askyesno("超出调谐窗口",
                               f"{hz / 1e6:.1f} MHz 不在当前 ±10 MHz 调谐窗口内。\n"
                               "需要重新设置 AD9361 本振（约 20 秒，期间无声）。继续吗？"):
            self.send("retune", hz=hz)

    def on_busy(self, msg):
        self.busy_msg = msg
        self.busy_lbl.configure(text=msg)
        self.set_enabled(self.radio_ready and not msg)

    def on_error(self, msg):
        self.btn_scan.state(["!disabled"])
        messagebox.showerror("Lightning Receiver", msg)

    def on_info(self, msg):
        self.busy_lbl.configure(text=msg)

    def on_close(self):
        self.save_state()
        self.send("quit")
        self.worker.join(timeout=5)
        self.root.destroy()


def main():
    root = tk.Tk()
    try:
        root.tk.call("tk", "scaling", 1.25)
    except tk.TclError:
        pass
    RadioGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
