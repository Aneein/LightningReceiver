// Offline tests of the airband AM demodulator with synthetic signals.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lr_radio/air_dsp.dart';

const double fs = AirDemod.fs;

/// Interleaved int16 IQ: AM carrier at [offHz] (amplitude [amp], depth [m],
/// tone [toneHz]) + optional second AM signal + complex Gaussian noise.
Int16List synth({
  double seconds = 1.0,
  double offHz = 0,
  double amp = 0,
  double m = 0.5,
  double toneHz = 1000,
  double amp2 = 0,
  double off2Hz = 0,
  double noiseRms = 0,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  double gauss() {
    final u1 = math.max(rnd.nextDouble(), 1e-12), u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  final n = (seconds * fs).round();
  final out = Int16List(2 * n);
  for (var i = 0; i < n; i++) {
    final t = i / fs;
    var re = 0.0, im = 0.0;
    if (amp > 0) {
      final env = amp * (1 + m * math.sin(2 * math.pi * toneHz * t));
      re += env * math.cos(2 * math.pi * offHz * t);
      im += env * math.sin(2 * math.pi * offHz * t);
    }
    if (amp2 > 0) {
      final env = amp2 * (1 + 0.8 * math.sin(2 * math.pi * 700 * t));
      re += env * math.cos(2 * math.pi * off2Hz * t);
      im += env * math.sin(2 * math.pi * off2Hz * t);
    }
    // per-component sigma = rms / sqrt(2) -> complex noise power = rms^2
    re += gauss() * noiseRms / math.sqrt2;
    im += gauss() * noiseRms / math.sqrt2;
    out[2 * i] = re.round().clamp(-32768, 32767);
    out[2 * i + 1] = im.round().clamp(-32768, 32767);
  }
  return out;
}

/// Amplitude of [f] in [x] (samples from [first]).
double toneAmp(Int16List x, double f, {int first = 0}) {
  var s = 0.0, c = 0.0;
  for (var i = first; i < x.length; i++) {
    s += x[i] * math.sin(2 * math.pi * f * i / fs);
    c += x[i] * math.cos(2 * math.pi * f * i / fs);
  }
  return 2 * math.sqrt(s * s + c * c) / (x.length - first);
}

double rms(Int16List x, {int first = 0}) {
  var a = 0.0;
  for (var i = first; i < x.length; i++) {
    a += x[i] * x[i].toDouble();
  }
  return math.sqrt(a / (x.length - first));
}

void main() {
  test('channel filter: flat to bw, stop band beyond bw + 2.2 kHz', () {
    final h = AirDemod.designLowpass(4000 + 1000, AirDemod.kTaps);
    double gainDb(double f) {
      var re = 0.0, im = 0.0;
      for (var n = 0; n < h.length; n++) {
        re += h[n] * math.cos(2 * math.pi * f * n / fs);
        im -= h[n] * math.sin(2 * math.pi * f * n / fs);
      }
      return 10 * math.log(re * re + im * im) / math.ln10;
    }

    expect(gainDb(0).abs(), lessThan(0.01));
    expect(gainDb(3000).abs(), lessThan(0.1));
    expect(gainDb(4000), greaterThan(-1.0));
    expect(gainDb(6200), lessThan(-60));
    expect(gainDb(12000), lessThan(-70));
  });

  test('AM tone is demodulated, squelch opens, carrier offset measured', () {
    final d = AirDemod();
    final out = d.process(synth(amp: 3000, m: 0.5, noiseRms: 40, offHz: 0));
    final a1k = toneAmp(out, 1000, first: 24000);
    final total = rms(out, first: 24000) * math.sqrt2;
    // 0.5 depth -> 0.5 * 0.8 * 32767 = 13107 before the band-pass (~1 at 1 kHz)
    expect(a1k, closeTo(13107, 1300));
    expect(a1k / total, greaterThan(0.95)); // clean tone
    expect(d.open, isTrue);
    expect(d.snrDb, greaterThan(25));
    expect(d.offsetHz!.abs(), lessThan(60));
  });

  test('carrier offset of 1.2 kHz still demodulates (oscillator error)', () {
    final d = AirDemod();
    final out = d.process(synth(amp: 3000, m: 0.5, noiseRms: 40, offHz: 1200));
    expect(toneAmp(out, 1000, first: 24000), closeTo(13107, 1300));
    expect(d.offsetHz!, closeTo(1200, 60));
  });

  test('carrier-normalised AGC: 32 dB level change -> same audio level', () {
    final weak = toneAmp(AirDemod().process(synth(amp: 250, noiseRms: 4)), 1000, first: 24000);
    final strong = toneAmp(AirDemod().process(synth(amp: 10000, noiseRms: 4)), 1000, first: 24000);
    expect(20 * math.log(strong / weak) / math.ln10, closeTo(0, 1.0));
  });

  test('noise only: (S+N)/N ~ 0 dB, squelch closed, output silent', () {
    final d = AirDemod();
    final x = synth(noiseRms: 300, seconds: 3, seed: 7);
    final snrs = <double>[];
    var opened = false;
    // feed in 50 ms blocks, record each decision
    for (var i = 0; i < x.length; i += 4800) {
      final last = d.decisions;
      final o = d.process(Int16List.sublistView(x, i, math.min(i + 4800, x.length)));
      if (d.decisions != last) snrs.add(d.snrDb);
      opened |= d.open;
      if (i > 48000) expect(o.every((v) => v == 0), isTrue);
    }
    final mean = snrs.reduce((a, b) => a + b) / snrs.length;
    expect(mean, closeTo(0, 1.5));
    expect(opened, isFalse);
  });

  test('weak signal at ~10 dB CNR opens the squelch', () {
    // noise 300 rms over 48 kHz -> ~150 rms in the 10 kHz channel (+/-4k +1k);
    // carrier 300 -> (S+N)/N ~ 10 dB
    final d = AirDemod();
    d.process(synth(amp: 300, m: 0.3, noiseRms: 300, seconds: 1, seed: 3));
    expect(d.snrDb, greaterThan(7));
    expect(d.open, isTrue);
  });

  test('8.33 kHz neighbour does not open the squelch (bw 3 kHz)', () {
    final d = AirDemod(bwHz: 3000);
    final out = d.process(synth(amp2: 6000, off2Hz: 8333.3, noiseRms: 60, seconds: 1.5, seed: 5));
    expect(d.open, isFalse);
    expect(d.snrDb, lessThan(3));
    expect(rms(out, first: 24000), lessThan(1));
    // the wanted channel opens when it carries a signal of its own
    final d2 = AirDemod(bwHz: 3000);
    final out2 = d2.process(synth(amp: 3000, amp2: 6000, off2Hz: 8333.3, noiseRms: 60, seed: 5));
    expect(d2.open, isTrue);
    expect(toneAmp(out2, 1000, first: 24000), closeTo(13107, 1500));
    expect(toneAmp(out2, 700, first: 24000), lessThan(200)); // neighbour's tone
  });

  test('squelch hangs ~0.5 s after the transmission ends', () {
    final d = AirDemod();
    d.process(synth(amp: 3000, noiseRms: 60, seconds: 1));
    expect(d.open, isTrue);
    final tail = synth(noiseRms: 60, seconds: 1.5, seed: 9);
    var closedAt = -1.0;
    for (var i = 0; i < tail.length; i += 960) {
      d.process(Int16List.sublistView(tail, i, i + 960));
      if (!d.open && closedAt < 0) closedAt = (i + 960) / 2 / fs;
    }
    expect(closedAt, inInclusiveRange(0.45, 0.75));
  });

  test('throughput: 1 s of IQ well below real time', () {
    final x = synth(amp: 3000, noiseRms: 60, seconds: 1);
    final d = AirDemod();
    d.process(x); // warm-up (JIT)
    final sw = Stopwatch()..start();
    d.process(x);
    sw.stop();
    // ignore: avoid_print
    print('AirDemod: 1 s of 48 kS/s IQ in ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(400));
  });
}
