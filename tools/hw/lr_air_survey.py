"""Airband helper for the narrowband IQ mode (design ID >= 0x4C520005).

  python lr_air_survey.py --iq-test            # format / rate / throughput check
  python lr_air_survey.py --survey 180         # sweep 118-137 MHz for activity
  python lr_air_survey.py --capture 118.1 10   # save 10 s of IQ as a stereo WAV

Talks to lr_jtagd (or the Vivado bridge) on 127.0.0.1:5555.  The AD9361 LO
must already be in the airband (ad9361_jtag --lo-hz 127962500).
The channel metric is the same as the App's AirDemod: (S+N)/N of the +/-4 kHz
channel against the 20th-percentile noise floor of the bins outside it.
"""
import argparse
import socket
import sys
import time
import wave

import numpy as np

LR = 0x44A20000
R_RF, R_DDC, R_CFG, R_AST, R_WR, R_BASE, R_WORDS, R_RS = (
    0x010, 0x024, 0x038, 0x068, 0x06C, 0x070, 0x074, 0x078)
REC, IQ = 1 << 16, 1 << 19
FS = 48000.0


class Link:
    def __init__(self, port=5555):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.f = self.s.makefile("rw", newline="\n")

    def cmds(self, cs):
        self.f.write("".join(c + "\n" for c in cs))
        self.f.flush()
        out = []
        for c in cs:
            r = self.f.readline().strip()
            if not r.startswith("OK"):
                raise RuntimeError(f"{c} -> {r}")
            out.append(r[3:])
        return out

    def rd(self, a):
        return int(self.cmds([f"R {a:08X}"])[0], 16)

    def wr(self, a, v):
        self.cmds([f"W {a:08X} {v & 0xFFFFFFFF:08X}"])

    def ring(self, addr, nwords):
        """nwords 32-byte ring words -> bytes (pipelined 1 KiB bursts)."""
        cs, a, end = [], addr, addr + nwords * 32
        while a < end:
            ce = min((a // 1024 + 1) * 1024, end)
            cs.append(f"B {a:08X} {(ce - a) // 4}")
            a = ce
        words = []
        for g in range(0, len(cs), 16):
            for r in self.cmds(cs[g:g + 16]):
                words += [int(w, 16) for w in r.split()]
        return np.array(words, dtype=np.uint32).tobytes()


class Ring:
    def __init__(self, ln):
        self.ln = ln
        self.base = ln.rd(LR + R_BASE)
        self.words = ln.rd(LR + R_WORDS)

    def read(self, start, n):
        """n ring words from absolute word counter 'start' -> complex IQ."""
        first = start % self.words
        n1 = min(n, self.words - first)
        b = self.ln.ring(self.base + first * 32, n1)
        if n > n1:
            b += self.ln.ring(self.base, n - n1)
        x = np.frombuffer(b, dtype="<i2").astype(np.float64)
        return x[0::2] + 1j * x[1::2]


def iq_mode(ln, on=True):
    cfg = ln.rd(LR + R_CFG)
    want = (cfg | IQ) if on else (cfg & ~IQ)
    ln.wr(LR + R_CFG, want & ~REC)
    time.sleep(0.01)
    ln.wr(LR + R_CFG, want | REC)
    time.sleep(0.01)
    return ln.rd(LR + R_AST), ln.rd(LR + R_RS)


def chan_metric(z, bw=4000.0):
    """(S+N)/N dB, channel power dBFS, peak offset Hz for >= 2048 samples."""
    n, frames = 512, len(z) // 512
    w = np.hanning(n + 1)[:-1]
    seg = z[:frames * n].reshape(frames, n) * w
    p = (np.abs(np.fft.fft(seg, axis=1)) ** 2).mean(axis=0)
    p /= n * (w ** 2).sum() * 32768.0 ** 2
    f = np.fft.fftfreq(n, 1 / FS)
    inb = np.abs(f) <= bw
    nb = (np.abs(f) > bw + 1000) & (np.abs(f) < 14000)
    # Gamma(frames) 20th percentile correction (as in AirDemod)
    from math import exp
    def cdf(x, k):
        y, term, s = k * x, 1.0, 1.0
        for j in range(1, k):
            term *= y / j
            s += term
        return 1 - exp(-y) * s
    lo, hi = 0.0, 10.0
    for _ in range(60):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if cdf(mid, frames) < 0.2 else (lo, mid)
    floor = np.sort(p[nb])[int(nb.sum() * 0.2)] / ((lo + hi) / 2)
    pin = p[inb].sum()
    k = np.argmax(np.where(inb, p, 0))
    return (10 * np.log10(pin / (floor * inb.sum())), 10 * np.log10(pin + 1e-20),
            f[k])


def iq_test(ln):
    ring = Ring(ln)
    st, rs = iq_mode(ln, True)
    print(f"AUDIO_STATUS 0x{st:08X} (rec {st >> 2 & 1}, IQ session {st >> 3 & 1}), "
          f"REC_START {rs}")
    w0, t0 = ln.rd(LR + R_WR), time.time()
    time.sleep(2.0)
    w1, t1 = ln.rd(LR + R_WR), time.time()
    rate = (w1 - w0) / (t1 - t0)
    print(f"ring rate {rate:.0f} words/s = {rate * 8:.0f} complex S/s (expect 6000 / 48000)")
    z = ring.read(w1 - 6000, 6000)
    print(f"1 s IQ: I rms {np.std(z.real):.1f}  Q rms {np.std(z.imag):.1f}  "
          f"DC {np.mean(z.real):+.1f}{np.mean(z.imag):+.1f}j  peak {np.abs(z).max():.0f}")
    snr, pdb, off = chan_metric(z)
    print(f"channel (S+N)/N {snr:.1f} dB, power {pdb:.1f} dBFS, peak at {off:+.0f} Hz")
    # sustained read: can the link keep up with 192 KB/s?
    rp, lost, t0, nread = ln.rd(LR + R_WR), 0, time.time(), 0
    while time.time() - t0 < 10:
        wp = ln.rd(LR + R_WR)
        n = min(wp - rp, 1500)
        if n <= 0:
            time.sleep(0.005)
            continue
        ring.read(rp, n)
        rp += n
        nread += n
    lag = ln.rd(LR + R_WR) - rp
    print(f"sustained 10 s: read {nread * 32 / 10 / 1024:.0f} KiB/s, "
          f"backlog at end {lag} words ({lag / 6:.0f} ms)")


def survey(ln, seconds, thr):
    ring = Ring(ln)
    lo = ln.rd(LR + R_RF)
    st, _ = iq_mode(ln, True)
    chans = [118_000_000 + 25_000 * k for k in range(int((137_000_000 - 118_000_000) / 25_000))]
    chans = [c for c in chans if abs(c - lo) <= 10_000_000]
    best = {c: -99.0 for c in chans}
    hits = {c: 0 for c in chans}
    t_end, sweep = time.time() + seconds, 0
    while time.time() < t_end:
        t0 = time.time()
        for c in chans:
            ln.wr(LR + R_DDC, c - lo)
            wt = ln.rd(LR + R_WR)
            while True:
                wp = ln.rd(LR + R_WR)
                if wp - wt >= 48 + 256:
                    break
                time.sleep(0.004)
            snr, _, _ = chan_metric(ring.read(wp - 256, 256))
            best[c] = max(best[c], snr)
            if snr >= thr:
                hits[c] += 1
                print(f"  {c / 1e6:.3f} MHz  (S+N)/N {snr:5.1f} dB")
        sweep += 1
        print(f"sweep {sweep}: {len(chans)} channels in {time.time() - t0:.1f} s")
    print("\nchannels with activity (max (S+N)/N, sweeps active):")
    for c in sorted(chans, key=lambda c: -best[c])[:25]:
        if best[c] >= thr:
            print(f"  {c / 1e6:.3f} MHz  {best[c]:5.1f} dB  {hits[c]}/{sweep}")


def capture(ln, mhz, seconds, path):
    ring = Ring(ln)
    lo = ln.rd(LR + R_RF)
    iq_mode(ln, True)
    ln.wr(LR + R_DDC, int(round(mhz * 1e6)) - lo)
    time.sleep(0.05)
    rp, chunks = ln.rd(LR + R_WR), []
    t_end = time.time() + seconds
    while time.time() < t_end:
        wp = ln.rd(LR + R_WR)
        n = min(wp - rp, 1500)
        if n > 0:
            chunks.append(ring.read(rp, n))
            rp += n
        else:
            time.sleep(0.005)
    z = np.concatenate(chunks)
    pcm = np.empty(2 * len(z), dtype="<i2")
    pcm[0::2], pcm[1::2] = z.real, z.imag
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(pcm.tobytes())
    print(f"wrote {path}: {len(z) / FS:.1f} s IQ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--iq-test", action="store_true")
    ap.add_argument("--survey", type=float, metavar="SECONDS")
    ap.add_argument("--thr", type=float, default=8.0)
    ap.add_argument("--capture", nargs=2, metavar=("MHZ", "SECONDS"))
    ap.add_argument("--out", default="air_iq.wav")
    ap.add_argument("--fm", action="store_true", help="switch the ring back to FM audio")
    a = ap.parse_args()
    ln = Link(a.port)
    if a.iq_test:
        iq_test(ln)
    if a.survey:
        survey(ln, a.survey, a.thr)
    if a.capture:
        capture(ln, float(a.capture[0]), float(a.capture[1]), a.out)
    if a.fm:
        print("FM mode:", [hex(v) for v in iq_mode(ln, False)])


if __name__ == "__main__":
    sys.exit(main())
