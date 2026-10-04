"""Live FM radio from the LR board over JTAG (no CMAC link needed).

The FPGA records the 48 kHz PCM into the DDR audio ring (AUDIO_CFG.REC); this
tool follows AUDIO_WR_WORDS, reads the new ring words through the JTAG bridge
(tools/hw/lr_jtag_bridge.tcl) and pipes them to ffplay.  JTAG burst reads move
~260 kB/s, the audio needs 96 kB/s.

    python tools/hw/lr_live_audio.py [--freq-mhz 99.1]

Keys:  u / d  seek up / down     + / -  step +/-100 kHz
       0      back to LO centre  q      quit
"""
import argparse
import msvcrt
import shutil
import socket
import struct
import subprocess
import sys
import time

LR = 0x44A20000
R_RF_FREQ, R_DDC_FREQ, R_AUDIO_CFG = 0x010, 0x024, 0x038
R_AUDIO_STATUS, R_WR_WORDS = 0x068, 0x06C
R_RING_BASE, R_RING_WORDS = 0x070, 0x074
R_SEEK_CTRL, R_SIG_POWER, R_SIG_QUALITY = 0x080, 0x088, 0x08C
REC_BIT = 1 << 16
WORD_BYTES = 32                     # one ring word = 16 PCM samples
START_LAG_WORDS = 600               # ~0.2 s of audio queued at start


class Bridge:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.f = self.s.makefile("rw", newline="\n")

    def cmd(self, c):
        self.f.write(c + "\n")
        self.f.flush()
        r = self.f.readline().strip()
        if not r.startswith("OK"):
            raise RuntimeError(f"bridge: {c} -> {r}")
        return r

    def rd(self, off):
        return int(self.cmd(f"R {LR + off:08X}").split()[1], 16)

    def wr(self, off, v):
        self.cmd(f"W {LR + off:08X} {v & 0xFFFFFFFF:08X}")

    def burst(self, addr, n):
        return self.cmd(f"B {addr:08X} {n}").split()[1:]

    def close(self):
        try:
            self.f.write("Q\n")
            self.f.flush()
        except OSError:
            pass
        self.s.close()


def s32(v):
    return v - (1 << 32) if v & 0x80000000 else v


def read_words(br, addr, nwords):
    """Ring words -> PCM bytes; 256-word (1 KiB) bursts, 1 KiB aligned."""
    out = bytearray()
    a, end = addr, addr + nwords * WORD_BYTES
    while a < end:
        chunk_end = min(end, (a // 1024 + 1) * 1024)
        for w in br.burst(a, (chunk_end - a) // 4):
            out += struct.pack("<I", int(w, 16))
        a = chunk_end
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--freq-mhz", type=float)
    ap.add_argument("--no-play", action="store_true", help="read but discard (test)")
    ap.add_argument("--seconds", type=float, default=0, help="stop after N s (test)")
    a = ap.parse_args()

    ffplay = shutil.which("ffplay")
    if not ffplay and not a.no_play:
        sys.exit("ffplay not found (install ffmpeg, e.g. winget install ffmpeg)")

    br = Bridge(a.port)
    lo = br.rd(R_RF_FREQ)
    if a.freq_mhz:
        br.wr(R_DDC_FREQ, int(round(a.freq_mhz * 1e6)) - lo)
    base = br.rd(R_RING_BASE)
    ring = br.rd(R_RING_WORDS)

    cfg0 = br.rd(R_AUDIO_CFG)
    br.wr(R_AUDIO_CFG, cfg0 | REC_BIT)
    time.sleep(0.25)
    rp = (br.rd(R_WR_WORDS) - START_LAG_WORDS) & 0xFFFFFFFF

    if a.no_play:
        player = subprocess.Popen([sys.executable, "-c",
                                   "import sys; sys.stdin.buffer.read()"],
                                  stdin=subprocess.PIPE)
    else:
        player = subprocess.Popen(
            [ffplay, "-hide_banner", "-loglevel", "error", "-nodisp",
             "-f", "s16le", "-ar", "48000", "-ch_layout", "mono",
             "-fflags", "nobuffer", "-flags", "low_delay", "-i", "-"],
            stdin=subprocess.PIPE)
    t_start = time.time()
    bytes_out = 0
    print(__doc__.split("Keys:")[1].strip())
    print()

    last_status = 0.0
    lost = 0
    try:
        while True:
            # ---------------- audio ----------------
            wp = br.rd(R_WR_WORDS)
            avail = (wp - rp) & 0xFFFFFFFF
            if avail > ring - 2048:          # fell behind: resync
                lost += avail
                rp = (wp - START_LAG_WORDS) & 0xFFFFFFFF
                avail = START_LAG_WORDS
            if avail:
                avail = min(avail, 1500)     # <= ~0.5 s per pass
                first = rp % ring
                n1 = min(avail, ring - first)
                pcm = read_words(br, base + first * WORD_BYTES, n1)
                if avail > n1:
                    pcm += read_words(br, base, avail - n1)
                rp = (rp + avail) & 0xFFFFFFFF
                bytes_out += len(pcm)
                try:
                    player.stdin.write(pcm)
                    player.stdin.flush()
                except (BrokenPipeError, OSError):
                    print("\nplayer closed")
                    break
            else:
                time.sleep(0.02)

            if a.seconds and time.time() - t_start > a.seconds:
                raise KeyboardInterrupt
            # ---------------- keys ----------------
            while msvcrt.kbhit():
                k = msvcrt.getwch().lower()
                if k == "q":
                    raise KeyboardInterrupt
                if k == "u":
                    br.wr(R_SEEK_CTRL, 1)
                elif k == "d":
                    br.wr(R_SEEK_CTRL, 2)
                elif k in "+=-":
                    step = 100_000 if k in "+=" else -100_000
                    br.wr(R_DDC_FREQ, s32(br.rd(R_DDC_FREQ)) + step)
                elif k == "0":
                    br.wr(R_DDC_FREQ, 0)

            # ---------------- status line ----------------
            now = time.time()
            if now - last_status > 0.3:
                last_status = now
                f_hz = lo + s32(br.rd(R_DDC_FREQ))
                q = br.rd(R_SIG_QUALITY)
                p = br.rd(R_SIG_POWER)
                sk = br.rd(R_SEEK_CTRL)
                flat = (q & 0xFFFF) / 256.0
                tag = "SEEKING" if sk & 1 else ("station" if (q >> 16) & 1 else "-------")
                lag_ms = ((br.rd(R_WR_WORDS) - rp) & 0xFFFFFFFF) * 16 / 48.0
                sys.stdout.write(f"\r {f_hz / 1e6:7.2f} MHz  {tag}  flat {flat:4.2f}  "
                                 f"power {p:>10d}  lag {lag_ms:5.0f} ms  lost {lost}   ")
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        el = time.time() - t_start
        print()
        print(f"{bytes_out} PCM bytes in {el:.1f} s = "
              f"{bytes_out / 2 / max(el, 1e-6):.0f} samples/s, lost {lost} words")
        br.wr(R_AUDIO_CFG, cfg0)             # restore the REC state
        br.close()
        try:
            player.stdin.close()
        except OSError:
            pass
        player.terminate()


if __name__ == "__main__":
    main()
