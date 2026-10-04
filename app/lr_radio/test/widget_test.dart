// Unit tests for the pure helpers of the radio engine.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lr_radio/engine.dart';

void main() {
  test('cnrDb inverts the fm_signal_meter flatness model', () {
    // flat = (s^2 + 4s + 2) / (s + 1)^2 for carrier-to-noise ratio s
    for (final s in [1.0, 3.0, 6.0, 10.0, 31.6]) {
      final flat = (s * s + 4 * s + 2) / ((s + 1) * (s + 1));
      final db = cnrDb(flat)!;
      expect(db, closeTo(10 * math.log(s) / math.ln10, 0.05));
    }
    expect(cnrDb(2.1), isNull);       // pure noise or worse
    expect(cnrDb(1.0), 30.0);         // clamp at a clean carrier
  });

  test('s32 sign-extends register values', () {
    expect(s32(0xFF78F5B2), -8849998);
    expect(s32(0x0000C352), 50002);
  });
}
