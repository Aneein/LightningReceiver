"""Offline AM demodulation of an IQ WAV recorded by lr_air_survey.py --capture
(or the App's "录音同时保存 IQ").  Same chain as the App's AirDemod:
channel FIR -> envelope -> carrier-normalised AGC -> 300-3000 Hz band-pass.

  python lr_air_demod.py air_iq.wav [--bw 4000] [--out audio.wav]
"""
import argparse
import wave

import numpy as np
from scipy import signal

FS = 48000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("iq_wav")
    ap.add_argument("--bw", type=float, default=4000)
    ap.add_argument("--out")
    a = ap.parse_args()
    with wave.open(a.iq_wav) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)
    z = x[0::2] + 1j * x[1::2]
    n = len(z)
    # --- spectrum / carrier ---
    f, p = signal.welch(z, FS, nperseg=8192, return_onesided=False)
    f, p = np.fft.fftshift(f), np.fft.fftshift(p)
    inb = np.abs(f) <= a.bw
    noise = np.median(p[(np.abs(f) > a.bw + 1000) & (np.abs(f) < 14000)])
    k = np.argmax(np.where(inb, p, 0))
    print(f"carrier at {f[k]:+.0f} Hz, {10 * np.log10(p[k] / noise):.1f} dB above the noise density")
    snr = 10 * np.log10(p[inb].sum() / (noise * inb.sum()))
    print(f"channel (S+N)/N {snr:.1f} dB, IQ rms {np.sqrt(np.mean(np.abs(z) ** 2)):.0f} LSB")
    # --- demod ---
    h = signal.firwin(127, a.bw + 1000, fs=FS, window="blackman")
    y = signal.lfilter(h, 1, z)
    env = np.abs(y)
    car = signal.lfilter([2.0833e-4], [1, -(1 - 2.0833e-4)], env)
    au = np.where(car > 1, (env - car) / np.maximum(car, 1), 0).clip(-2, 2)
    sos = np.vstack([signal.butter(2, 300, "hp", fs=FS, output="sos"),
                     signal.butter(4, 3000, "lp", fs=FS, output="sos")])
    au = signal.sosfilt(sos, au)[FS // 2:]
    m = np.sqrt(np.mean(au ** 2))
    fa, pa = signal.welch(au, FS, nperseg=4096)
    voice = pa[(fa > 300) & (fa < 3000)].sum() / pa[(fa > 3500) & (fa < 6000)].sum() * (2500 / 3000)
    print(f"modulation rms {m:.3f} (depth), speech band / out-of-band density ratio {10*np.log10(voice):.1f} dB")
    # 1 s blocks: envelope modulation over time (speech comes and goes)
    blk = [np.sqrt(np.mean(au[i:i + FS] ** 2)) for i in range(0, len(au) - FS, FS)]
    print("per-second modulation rms:", " ".join(f"{b:.2f}" for b in blk))
    if a.out:
        pcm = (au / max(np.max(np.abs(au)), 1e-9) * 0.9 * 32767).astype("<i2")
        with wave.open(a.out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(FS)
            w.writeframes(pcm.tobytes())
        print("wrote", a.out)


if __name__ == "__main__":
    main()
