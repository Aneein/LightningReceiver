// Layout check: the main screen must render without overflow at every
// window size from the minimum window size up (FM and airband modes).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lr_radio/engine.dart';
import 'package:lr_radio/main.dart';

RadioEngine fakeEngine(RadioMode mode) {
  final e = RadioEngine()
    ..phase = Phase.ready
    ..connected = true
    ..radioReady = true
    ..connMsg = '已连接 · lr_jtagd · 下载器 0ABC01A · TCK 15 MHz · IDCODE 0x04A62093'
    ..info = '全波段搜索：760 个频道，遇到通话自动停留'
    ..designId = 0x4C520005
    ..mode = mode
    ..lo = mode == RadioMode.air ? 127962500 : 97950000
    ..freq = mode == RadioMode.air ? 118100000 : 99100000
    ..lagMs = 3
    ..recElapsed = const Duration(seconds: 75)
    ..airChannels = [AirChannel(118100000, '塔台'), AirChannel(121900000, '地面')]
    ..airIgnore = {120000000, 125000000}
    ..stations = [Station(89100000, 19.8, true), Station(99100000, 17.9, true)];
  return e;
}

void main() {
  // 960 x 640 is the minimum window size (windows/runner WM_GETMINMAXINFO)
  const sizes = [Size(1920, 1080), Size(1180, 760), Size(1024, 680), Size(960, 640)];
  for (final mode in RadioMode.values) {
    for (final sz in sizes) {
      testWidgets('${mode.name} ${sz.width.toInt()}x${sz.height.toInt()}', (t) async {
        t.view.physicalSize = sz;
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        await t.pumpWidget(RadioApp(engine: fakeEngine(mode)));
        await t.pump(const Duration(milliseconds: 50));
        expect(t.takeException(), isNull);
      });
    }
  }
}
