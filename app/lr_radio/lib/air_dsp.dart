// Lightning Receiver - airband AM demodulator (pure Dart, no Flutter).
//
// Input : 48 kS/s complex baseband from the FPGA narrowband IQ mode
//         (interleaved int16 I, Q; channel centred at 0 Hz by the DDC).
// Chain : channel FIR (complex low-pass, +/-bw) -> envelope |I+jQ|
//         -> carrier-normalised AGC  a = (e - c) / c   (c = slow carrier level)
//         -> speech band-pass 300-3000 Hz -> squelch gate -> 48 kHz mono PCM.
// Meter : 512-point FFT of the raw IQ, 4 frames averaged (~43 ms):
//         channel power (S+N) in +/-bw versus the noise floor estimated from
//         the 20th percentile of the bins outside the channel (|f| < 14 kHz),
//         which tolerates neighbouring 8.33 kHz channels.  The squelch opens
//         when (S+N)/N >= squelchDb and closes 0.5 s after it drops 2 dB
//         below.  The same metric drives the channel scanner.
import 'dart:math' as math;
import 'dart:typed_data';

class AirDemod {
  AirDemod({double bwHz = 4000}) {
    _initFft();
    this.bwHz = bwHz;
    _noiseCorr = 1.0 / _gammaQuantile(kFrames, kNoisePercentile);
    reset();
  }

  static const double fs = 48000.0;
  static const int kTaps = 127;
  static const int kFft = 512;
  static const int kFrames = 4; // FFT frames per squelch decision
  static const double kNoisePercentile = 0.2;
  static const double kNoiseEdgeHz = 14000; // FPGA FIR pass band ~15 kHz
  static const double kHangS = 0.5;
  static const double kHystDb = 2.0;

  // ---------------- configuration ----------------
  double _bw = 4000;
  double get bwHz => _bw;
  /// Channel half-bandwidth: flat to bw, >= 70 dB down beyond ~bw + 2 kHz
  /// (Blackman transition ~2.1 kHz centred on bw + 1 kHz).
  set bwHz(double v) {
    _bw = v;
    _h = designLowpass(v + 1000, kTaps);
  }

  /// Squelch threshold, (S+N)/N in dB; <= 0 keeps the squelch open.
  double squelchDb = 6.0;

  // ---------------- live metrics ----------------
  double snrDb = 0; // (S+N)/N of the channel
  double powerDb = -120; // channel power, dBFS (full-scale complex sine = 0)
  double noiseDb = -120; // noise in the channel bandwidth, dBFS
  double? offsetHz; // carrier offset from the channel centre (signal only)
  bool open = false;
  int decisions = 0; // squelch decisions since reset (scanner sync)
  final Float64List spectrumDb = Float64List(kFft); // -24..+24 kHz, dBFS/bin

  // ---------------- state ----------------
  late Float64List _h;
  final Float64List _bi = Float64List(2 * kTaps);
  final Float64List _bq = Float64List(2 * kTaps);
  int _bp = 0;
  double _carrier = 0;
  final _hp = Biquad.highpass(300, 0.7071, fs);
  final _lp1 = Biquad.lowpass(3000, 0.5412, fs);
  final _lp2 = Biquad.lowpass(3000, 1.3066, fs);
  double _gate = 0;
  int _hang = 0;
  late double _noiseCorr;

  final Float64List _fr = Float64List(kFft), _fi = Float64List(kFft);
  int _fn = 0;
  final Float64List _psd = Float64List(kFft);
  int _frames = 0;
  late Float64List _win, _cos, _sin;
  late Int32List _rev;
  late double _winPow;

  static const double _alphaCarrier = 2.0833e-4; // tau = 0.1 s
  static const double _gateStep = 1.0 / 240; // 5 ms fade

  void reset() {
    _bi.fillRange(0, _bi.length, 0);
    _bq.fillRange(0, _bq.length, 0);
    _bp = 0;
    _carrier = 0;
    _hp.reset();
    _lp1.reset();
    _lp2.reset();
    _gate = 0;
    _hang = 0;
    open = false;
    _fn = 0;
    _frames = 0;
    _psd.fillRange(0, kFft, 0);
    decisions = 0;
    snrDb = 0;
    offsetHz = null;
  }

  /// Demodulates interleaved int16 I/Q; returns one int16 audio sample per
  /// complex input sample (48 kHz mono).
  Int16List process(Int16List iq) {
    final n = iq.length ~/ 2;
    final out = Int16List(n);
    final h = _h;
    for (var s = 0; s < n; s++) {
      final xi = iq[2 * s].toDouble(), xq = iq[2 * s + 1].toDouble();
      // ---- spectrum / squelch meter on the raw IQ ----
      _fr[_fn] = xi;
      _fi[_fn] = xq;
      if (++_fn == kFft) {
        _fn = 0;
        _frame();
      }
      // ---- channel filter (circular buffer stored twice: no modulo) ----
      _bp = _bp == 0 ? kTaps - 1 : _bp - 1;
      _bi[_bp] = xi;
      _bi[_bp + kTaps] = xi;
      _bq[_bp] = xq;
      _bq[_bp + kTaps] = xq;
      var yi = 0.0, yq = 0.0;
      for (var k = 0; k < kTaps; k++) {
        final c = h[k];
        yi += c * _bi[_bp + k];
        yq += c * _bq[_bp + k];
      }
      // ---- AM envelope, carrier-normalised ----
      final e = math.sqrt(yi * yi + yq * yq);
      _carrier += _alphaCarrier * (e - _carrier);
      var a = _carrier > 1.0 ? (e - _carrier) / _carrier : 0.0;
      if (a > 2.0) a = 2.0;
      if (a < -2.0) a = -2.0;
      a = _lp2.run(_lp1.run(_hp.run(a)));
      // ---- squelch gate with a short fade ----
      final target = open ? 1.0 : 0.0;
      if (_gate < target) {
        _gate = math.min(target, _gate + _gateStep);
      } else if (_gate > target) {
        _gate = math.max(target, _gate - _gateStep);
      }
      final v = a * _gate * 0.8 * 32767.0;
      out[s] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v.round());
    }
    return out;
  }

  // ---------------- meter ----------------
  void _frame() {
    for (var i = 0; i < kFft; i++) {
      _fr[i] *= _win[i];
      _fi[i] *= _win[i];
    }
    fftInPlace(_fr, _fi, _cos, _sin, _rev);
    for (var i = 0; i < kFft; i++) {
      _psd[i] += _fr[i] * _fr[i] + _fi[i] * _fi[i];
    }
    if (++_frames < kFrames) return;
    _frames = 0;
    // bin power normalised so that sum over bins = mean |x|^2, in units of
    // full scale (32768^2): sum_k |X_k|^2 / (N * sum w^2)
    const fsPow = 32768.0 * 32768.0;
    final scale = 1.0 / (kFrames * kFft * _winPow * fsPow);
    final binHz = fs / kFft;
    var pin = 0.0;
    var nin = 0;
    final noiseBins = <double>[];
    var peak = -1, peakV = -1.0;
    for (var i = 0; i < kFft; i++) {
      final p = _psd[i] * scale;
      final k = i < kFft ~/ 2 ? i : i - kFft; // signed bin
      final f = (k * binHz).abs();
      spectrumDb[k + kFft ~/ 2] = 10 * math.log(p + 1e-20) / math.ln10;
      if (f <= _bw) {
        pin += p;
        nin++;
        if (p > peakV) {
          peakV = p;
          peak = i;
        }
      } else if (f > _bw + 1000 && f < kNoiseEdgeHz) {
        noiseBins.add(p);
      }
    }
    _psd.fillRange(0, kFft, 0);
    noiseBins.sort();
    final perBin = noiseBins.isEmpty
        ? 1e-20
        : noiseBins[(noiseBins.length * kNoisePercentile).floor()] * _noiseCorr;
    final noise = perBin * nin;
    snrDb = 10 * math.log(math.max(pin, 1e-20) / math.max(noise, 1e-20)) / math.ln10;
    powerDb = 10 * math.log(pin + 1e-20) / math.ln10;
    noiseDb = 10 * math.log(noise + 1e-20) / math.ln10;
    // carrier offset: parabolic interpolation around the strongest in-band bin
    if (peak >= 0) {
      final k = peak < kFft ~/ 2 ? peak : peak - kFft;
      final l = spectrumDb[(k - 1 + kFft ~/ 2).clamp(0, kFft - 1)];
      final c = spectrumDb[k + kFft ~/ 2];
      final r = spectrumDb[(k + 1 + kFft ~/ 2).clamp(0, kFft - 1)];
      final den = l - 2 * c + r;
      final d = den.abs() < 1e-9 ? 0.0 : 0.5 * (l - r) / den;
      offsetHz = (k + d.clamp(-0.5, 0.5)) * binHz;
    }
    // squelch with hysteresis and hang time
    final hangDecisions = (kHangS * fs / (kFft * kFrames)).ceil();
    if (squelchDb <= 0 || snrDb >= squelchDb) {
      open = true;
      _hang = hangDecisions;
    } else if (open && snrDb < squelchDb - kHystDb) {
      if (--_hang <= 0) open = false;
    } else if (open) {
      _hang = hangDecisions;
    }
    if (!open) offsetHz = null;
    decisions++;
  }

  void _initFft() {
    _win = Float64List(kFft);
    var wp = 0.0;
    for (var i = 0; i < kFft; i++) {
      _win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / kFft);
      wp += _win[i] * _win[i];
    }
    _winPow = wp;
    _cos = Float64List(kFft ~/ 2);
    _sin = Float64List(kFft ~/ 2);
    for (var i = 0; i < kFft ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / kFft);
      _sin[i] = -math.sin(2 * math.pi * i / kFft);
    }
    _rev = Int32List(kFft);
    final bits = (math.log(kFft) / math.ln2).round();
    for (var i = 0; i < kFft; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if ((i >> b) & 1 == 1) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  // ---------------- helpers (public for tests) ----------------

  /// Blackman-windowed sinc low-pass, unity DC gain.
  static Float64List designLowpass(double cutoffHz, int taps) {
    final h = Float64List(taps);
    final m = (taps - 1) / 2;
    final fc = cutoffHz / fs;
    var sum = 0.0;
    for (var n = 0; n < taps; n++) {
      final x = n - m;
      final sinc = x == 0 ? 2 * fc : math.sin(2 * math.pi * fc * x) / (math.pi * x);
      final w = 0.42 -
          0.5 * math.cos(2 * math.pi * n / (taps - 1)) +
          0.08 * math.cos(4 * math.pi * n / (taps - 1));
      h[n] = sinc * w;
      sum += h[n];
    }
    for (var n = 0; n < taps; n++) {
      h[n] /= sum;
    }
    return h;
  }

  /// Radix-2 in-place complex FFT (forward).
  static void fftInPlace(Float64List re, Float64List im, Float64List cosT,
      Float64List sinT, Int32List rev) {
    final n = re.length;
    for (var i = 0; i < n; i++) {
      final j = rev[i];
      if (j > i) {
        final tr = re[i], ti = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tr;
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = cosT[k * step], wi = sinT[k * step];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }

  /// p-quantile of the mean of [k] unit-mean exponential variables
  /// (Gamma(k, 1/k)): the distribution of an averaged noise-only FFT bin.
  static double _gammaQuantile(int k, double p) {
    double cdf(double x) {
      final y = k * x;
      var term = 1.0, sum = 1.0;
      for (var j = 1; j < k; j++) {
        term *= y / j;
        sum += term;
      }
      return 1 - math.exp(-y) * sum;
    }

    var lo = 0.0, hi = 10.0;
    for (var i = 0; i < 60; i++) {
      final mid = 0.5 * (lo + hi);
      if (cdf(mid) < p) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return 0.5 * (lo + hi);
  }
}

/// RBJ biquad, direct form I.
class Biquad {
  Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad.lowpass(double f0, double q, double fs) {
    final w = 2 * math.pi * f0 / fs, al = math.sin(w) / (2 * q), c = math.cos(w);
    final a0 = 1 + al;
    return Biquad._((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0,
        -2 * c / a0, (1 - al) / a0);
  }

  factory Biquad.highpass(double f0, double q, double fs) {
    final w = 2 * math.pi * f0 / fs, al = math.sin(w) / (2 * q), c = math.cos(w);
    final a0 = 1 + al;
    return Biquad._((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
        -2 * c / a0, (1 - al) / a0);
  }

  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void reset() => _x1 = _x2 = _y1 = _y2 = 0;

  double run(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
