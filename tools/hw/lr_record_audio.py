"""Record FM audio from the LR DDR audio ring over JTAG and save a WAV file.

Needs the JTAG bridge (tools/hw/lr_jtag_bridge.tcl) and an initialised
AD9361 (tools/hw/ad9361_jtag).  Steps:
  1. optionally tune: DDC_FREQ = freq - RF_FREQ (RF_FREQ holds the AD9361 LO)
  2. AUDIO_CFG.REC = 1 for N seconds, then 0 (the FPGA pads the session to a
     32-byte ring word and latches AUDIO_REC_START)
  3. read ring words [AUDIO_REC_START, AUDIO_WR_WORDS) from 0xFF00_0000 and
     write int16 LE mono 48 kHz PCM as WAV.

    python tools/hw/lr_record_audio.py --freq-mhz 89.1 --seconds 10 --out fm.wav
"""
import argparse
import socket
import struct
import sys
import time
import wave

LR = 0x44A20000
REG_RF_FREQ = 0x010
REG_DDC_FREQ = 0x024
REG_AUDIO_CFG = 0x038
REG_AUDIO_STATUS = 0x068
REG_AUDIO_WR_WORDS = 0x06C
REG_AUDIO_RING_BASE = 0x070
REG_AUDIO_RING_WORDS = 0x074
REG_AUDIO_REC_START = 0x078
REC_BIT = 1 << 16


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

    def rd(self, addr):
        return int(self.cmd(f"R {addr:08X}").split()[1], 16)

    def wr(self, addr, val):
        self.cmd(f"W {addr:08X} {val & 0xFFFFFFFF:08X}")

    def burst(self, addr, n):
        return [int(w, 16) for w in self.cmd(f"B {addr:08X} {n}").split()[1:]]

    def close(self):
        try:
            self.f.write("Q\n")
            self.f.flush()
        except OSError:
            pass
        self.s.close()


def read_bytes(br, addr, nbytes):
    """Read nbytes from 32-bit aligned addr with 256-word (1 KiB) bursts that
    never cross a 1 KiB boundary (and therefore never a 4 KiB one)."""
    out = bytearray()
    end = addr + nbytes
    a = addr
    while a < end:
        chunk_end = min(end, (a // 1024 + 1) * 1024)
        n = (chunk_end - a) // 4
        for w in br.burst(a, n):
            out += struct.pack("<I", w)
        a = chunk_end
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--freq-mhz", type=float, help="tune before recording")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--out", default="fm_capture.wav")
    a = ap.parse_args()

    br = Bridge(a.port)
    try:
        lo = br.rd(LR + REG_RF_FREQ)
        if a.freq_mhz:
            ddc = int(round(a.freq_mhz * 1e6)) - lo
            br.wr(LR + REG_DDC_FREQ, ddc)
            print(f"tuned: LO {lo} Hz + DDC {ddc} Hz = {a.freq_mhz} MHz")
            time.sleep(0.2)
        base = br.rd(LR + REG_AUDIO_RING_BASE)
        ring_words = br.rd(LR + REG_AUDIO_RING_WORDS)
        max_s = ring_words * 16 / 48000.0
        if a.seconds > max_s:
            sys.exit(f"--seconds must be <= {max_s:.0f} (ring size)")

        cfg = br.rd(LR + REG_AUDIO_CFG)
        if cfg & REC_BIT:            # close any running session first
            br.wr(LR + REG_AUDIO_CFG, cfg & ~REC_BIT)
            time.sleep(0.05)
            cfg &= ~REC_BIT
        br.wr(LR + REG_AUDIO_CFG, cfg | REC_BIT)
        t0 = time.time()
        print(f"recording {a.seconds:.1f} s ...")
        time.sleep(a.seconds)
        br.wr(LR + REG_AUDIO_CFG, cfg)
        elapsed = time.time() - t0
        time.sleep(0.05)             # padding words drain into DDR

        start = br.rd(LR + REG_AUDIO_REC_START)
        end = br.rd(LR + REG_AUDIO_WR_WORDS)
        status = br.rd(LR + REG_AUDIO_STATUS)
        words = (end - start) & 0xFFFFFFFF
        exp = elapsed * 48000 / 16
        print(f"ring words {start}..{end} = {words} "
              f"(expected ~{exp:.0f}), AUDIO_STATUS 0x{status:08X}")
        if words == 0:
            sys.exit("no audio words recorded (is the AD9361 initialised?)")
        if words > ring_words:
            words = ring_words
            start = (end - words) & 0xFFFFFFFF

        t1 = time.time()
        pcm = bytearray()
        first = start % ring_words
        n1 = min(words, ring_words - first)
        pcm += read_bytes(br, base + first * 32, n1 * 32)
        if words > n1:
            pcm += read_bytes(br, base, (words - n1) * 32)
        print(f"read {len(pcm)} bytes in {time.time() - t1:.1f} s")

        with wave.open(a.out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes(bytes(pcm))
        samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
        peak = max(abs(x) for x in samples)
        rms = (sum(x * x for x in samples) / len(samples)) ** 0.5
        print(f"wrote {a.out}: {len(samples) / 48000:.2f} s, "
              f"peak {peak}, rms {rms:.0f}")
    finally:
        br.close()


if __name__ == "__main__":
    main()
