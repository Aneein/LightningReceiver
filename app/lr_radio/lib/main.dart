// Lightning Receiver - FM radio desktop app (Flutter, Windows).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'air_dsp.dart';
import 'engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = RadioEngine();
  runApp(RadioApp(engine: engine));
  unawaited(engine.start());
}

class RadioApp extends StatelessWidget {
  const RadioApp({super.key, required this.engine});
  final RadioEngine engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lightning Receiver FM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF4FC3F7),
        fontFamily: 'Microsoft YaHei UI',
      ),
      home: RadioHome(engine: engine),
    );
  }
}

const _good = Color(0xFF66BB6A);
const _warn = Color(0xFFFFB74D);
const _bad = Color(0xFFEF5350);
const _accent = Color(0xFF4FC3F7);

class RadioHome extends StatefulWidget {
  const RadioHome({super.key, required this.engine});
  final RadioEngine engine;

  @override
  State<RadioHome> createState() => _RadioHomeState();
}

class _RadioHomeState extends State<RadioHome> {
  RadioEngine get e => widget.engine;
  final _freqCtl = TextEditingController();
  final _freqFocus = FocusNode();
  StreamSubscription<String>? _errSub;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    e.addListener(_onChange);
    _errSub = e.errors.listen((m) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Lightning Receiver'),
          content: SelectableText(m),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('确定'))],
        ),
      );
    });
    _life = AppLifecycleListener(onExitRequested: () async {
      await e.shutdown();
      return AppExitResponse.exit;
    });
  }

  @override
  void dispose() {
    e.removeListener(_onChange);
    _errSub?.cancel();
    _life.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  bool get _ready => e.connected && e.radioReady && e.busy.isEmpty;

  // ---------------- actions ----------------
  Future<void> _tuneTo(int hz) async {
    if (await e.tune(hz)) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('超出调谐窗口'),
        content: Text('${(hz / 1e6).toStringAsFixed(1)} MHz 不在当前 ±'
            '${(e.rangeHz / 1e6).toStringAsFixed(0)} MHz 调谐窗口内。\n'
            '需要重新设置 AD9361 本振（约 20 秒，期间无声）。继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('重新设置')),
        ],
      ),
    );
    if (ok == true) await e.retune(hz);
  }

  void _onEnter() {
    final v = double.tryParse(_freqCtl.text.trim());
    if (v == null || v < 70 || v > 6000) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入 70–6000 之间的频率（MHz），例如 99.1')));
      return;
    }
    _freqFocus.unfocus();
    _tuneTo((v * 10).round() * 100000);
  }

  Future<void> _settings() async {
    final viv = TextEditingController(text: e.vivadoBat);
    final port = TextEditingController(text: '${e.port}');
    var useViv = e.useVivadoBridge;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 520,
          child: StatefulBuilder(builder: (c2, setD) => Column(mainAxisSize: MainAxisSize.min, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用 Vivado JTAG 桥（备用）'),
              subtitle: const Text('默认使用内置的 lr_jtagd 直连 FT2232H，不需要 Vivado。\n'
                  '仅当 FPGA 是没有 LR JTAG 桥的旧版 bitstream 时才需要打开。'),
              value: useViv,
              onChanged: (v) => setD(() => useViv = v),
            ),
            TextField(controller: viv, enabled: useViv, decoration: const InputDecoration(
                labelText: 'Vivado 2021.1 的 vivado.bat 路径（仅备用模式需要）')),
            const SizedBox(height: 12),
            TextField(controller: port, decoration: const InputDecoration(
                labelText: 'JTAG 桥端口'), keyboardType: TextInputType.number),
            const SizedBox(height: 16),
            Align(alignment: Alignment.centerLeft, child: Text(
                '录音保存在：${RadioEngine.recordDir}',
                style: Theme.of(c).textTheme.bodySmall)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
              onPressed: e.phase == Phase.ready
                  ? () { Navigator.pop(c); e.initRadio(); }
                  : null,
              icon: const Icon(Icons.settings_input_antenna, size: 18),
              label: const Text('重新初始化射频'),
            )),
          ])),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final changed = e.useVivadoBridge != useViv ||
                  e.port != (int.tryParse(port.text.trim()) ?? e.port);
              e.vivadoBat = viv.text.trim();
              e.port = int.tryParse(port.text.trim()) ?? e.port;
              e.useVivadoBridge = useViv;
              e.saveSettings();
              Navigator.pop(c);
              if (changed) e.runPreflight();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ---------------- build ----------------
  @override
  Widget build(BuildContext context) {
    if (e.phase != Phase.ready) return _preflight();
    final noEdit = !_freqFocus.hasFocus;
    final isAir = e.mode == RadioMode.air;
    return CallbackShortcuts(
      bindings: isAir
          ? {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () { if (noEdit && _ready) e.airStepBy(-1); },
              const SingleActivator(LogicalKeyboardKey.arrowRight): () { if (noEdit && _ready) e.airStepBy(1); },
              const SingleActivator(LogicalKeyboardKey.pageUp): () { if (_ready) e.toggleAirScan(); },
              const SingleActivator(LogicalKeyboardKey.pageDown): () { if (_ready) e.toggleAirScan(); },
            }
          : {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () { if (noEdit && _ready) e.step(-100000); },
              const SingleActivator(LogicalKeyboardKey.arrowRight): () { if (noEdit && _ready) e.step(100000); },
              const SingleActivator(LogicalKeyboardKey.pageUp): () { if (_ready) e.seek(true); },
              const SingleActivator(LogicalKeyboardKey.pageDown): () { if (_ready) e.seek(false); },
            },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              _topBar(),
              const SizedBox(height: 12),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 3, child: isAir ? _airTuner() : _tuner()),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: isAir ? _airChannelList() : _stationList()),
                ]),
              ),
              const SizedBox(height: 12),
              isAir ? _airBottomBar() : _bottomBar(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final color = e.connected ? _good : (e.connMsg.contains('连接…') ? _warn : _bad);
    return Row(children: [
      Icon(e.connected ? Icons.link : Icons.link_off, color: color, size: 20),
      const SizedBox(width: 8),
      Flexible(flex: 3, child: Text(e.connMsg, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color))),
      const SizedBox(width: 16),
      Tooltip(
        message: e.airSupported ? '' : '航空波段需要设计 ID 0x4C520005 或更新的 bitstream',
        child: SegmentedButton<RadioMode>(
          segments: [
            const ButtonSegment(value: RadioMode.fm, icon: Icon(Icons.radio, size: 18),
                label: Text('FM 广播')),
            ButtonSegment(value: RadioMode.air, enabled: e.airSupported,
                icon: const Icon(Icons.flight, size: 18), label: const Text('航空 AM')),
          ],
          selected: {e.mode},
          onSelectionChanged: _ready ? (v) => e.setMode(v.first) : null,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: e.busy.isNotEmpty
            ? Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Flexible(child: Text(e.busy, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _accent))),
              ])
            : Text(e.info, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right,
                style: TextStyle(color: Theme.of(context).hintColor)),
      ),
      IconButton(onPressed: e.runPreflight, icon: const Icon(Icons.fact_check_outlined),
          tooltip: '重新检测链路'),
      IconButton(onPressed: _settings, icon: const Icon(Icons.settings), tooltip: '设置'),
    ]);
  }

  // ---------------- start-up self test ----------------
  Widget _preflight() {
    final t = Theme.of(context);
    final failed = e.phase == Phase.failed;
    final autoRetry = failed &&
        e.checks.any((c) => c.state == CheckState.fail) &&
        !e.checks.any((c) => c.state == CheckState.fail && c.hint.contains('bitstream'));
    Widget icon(CheckState s) {
      switch (s) {
        case CheckState.pending:
          return Icon(Icons.radio_button_unchecked, color: t.hintColor);
        case CheckState.running:
          return const SizedBox(width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5));
        case CheckState.ok:
          return const Icon(Icons.check_circle, color: _good);
        case CheckState.warn:
          return const Icon(Icons.warning_amber_rounded, color: _warn);
        case CheckState.fail:
          return const Icon(Icons.cancel, color: _bad);
      }
    }

    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 760,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.radio, color: _accent, size: 28),
                  const SizedBox(width: 10),
                  Text('Lightning Receiver FM · 启动自检', style: t.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(onPressed: _settings, icon: const Icon(Icons.settings), tooltip: '设置'),
                ]),
                const SizedBox(height: 4),
                Text(failed ? '链路检测未通过，请按提示处理' : '正在逐级检测 电脑 → 下载器 → FPGA → 射频 …',
                    style: TextStyle(color: failed ? _bad : t.hintColor)),
                if (e.info.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(e.info, style: const TextStyle(color: _warn)),
                ],
                const SizedBox(height: 16),
                for (final c in e.checks)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 28, child: icon(c.state)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c.title + (c.required ? '' : ''),
                              style: TextStyle(fontWeight: FontWeight.w600,
                                  color: c.state == CheckState.pending ? t.hintColor : null)),
                          if (c.detail.isNotEmpty)
                            SelectableText(c.detail, style: TextStyle(color: t.hintColor)),
                          if (c.hint.isNotEmpty)
                            SelectableText('→ ${c.hint}', style: TextStyle(
                                color: c.state == CheckState.fail ? _bad : _warn)),
                        ]),
                      ),
                    ]),
                  ),
                const SizedBox(height: 16),
                Row(children: [
                  FilledButton.icon(
                    onPressed: failed ? e.runPreflight : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新检测'),
                  ),
                  const SizedBox(width: 12),
                  if (autoRetry)
                    Text('问题排除后会每 5 秒自动重试', style: TextStyle(color: t.hintColor)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tuner() {
    final t = Theme.of(context);
    final ready = e.connected && e.radioReady;
    String badge;
    Color badgeColor;
    if (!e.connected) {
      badge = '未连接';
      badgeColor = t.hintColor;
    } else if (!e.radioReady) {
      badge = '射频未初始化';
      badgeColor = _bad;
    } else if (e.seeking) {
      badge = '搜台中…';
      badgeColor = _accent;
    } else if (e.station) {
      badge = '有台';
      badgeColor = _good;
    } else {
      badge = '无台';
      badgeColor = t.hintColor;
    }
    final cnr = ready ? cnrDb(e.flat) : null;
    final dbfs = e.power > 0 ? 10 * _log10(e.power / kFullScalePower) : -90.0;
    final isFav = e.favorites.contains((e.freq / 100000).round() * 100000);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _fillOrScroll(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(e.freq > 0 ? (e.freq / 1e6).toStringAsFixed(2) : '--.--',
                style: const TextStyle(fontSize: 72, fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()], height: 1.0)),
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(bottom: 10),
                child: Text('MHz', style: TextStyle(fontSize: 20, color: t.hintColor))),
            const SizedBox(width: 16),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Chip(label: Text(badge), labelStyle: TextStyle(color: badgeColor),
                  side: BorderSide(color: badgeColor.withValues(alpha: 0.6))),
            ),
            ]))),
            IconButton(
              onPressed: ready ? e.toggleFavorite : null,
              icon: Icon(isFav ? Icons.star : Icons.star_border, color: isFav ? _warn : null),
              tooltip: '收藏当前频率',
            ),
          ]),
          if (e.lo > 0)
            Text('调谐窗口 ${((e.lo - e.rangeHz) / 1e6).toStringAsFixed(1)}–'
                '${((e.lo + e.rangeHz) / 1e6).toStringAsFixed(1)} MHz · 本振 '
                '${(e.lo / 1e6).toStringAsFixed(3)} MHz',
                style: TextStyle(color: t.hintColor)),
          const SizedBox(height: 18),
          _Meter('信号质量', cnr == null ? 0 : cnr / 30,
              cnr == null ? (ready ? '< 0 dB' : '--') : '${cnr.toStringAsFixed(1)} dB',
              cnr == null ? _bad : (cnr >= 10 ? _good : (cnr >= 6 ? _warn : _bad))),
          _Meter('信号电平', (dbfs + 90) / 90, '${dbfs.toStringAsFixed(1)} dBFS', _accent),
          _Meter('音频电平', (e.levelDb + 60) / 60, '${e.levelDb.toStringAsFixed(1)} dBFS',
              e.levelDb > -1 ? _bad : _accent),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: FilledButton.tonal(
                onPressed: _ready ? () => e.seek(false) : null,
                child: Text(e.seeking ? '停止' : '◀◀ 搜台'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _ready ? () => e.step(-100000) : null, child: const Text('−0.1')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _ready ? () => e.step(100000) : null, child: const Text('+0.1')),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonal(
                onPressed: _ready ? () => e.seek(true) : null,
                child: Text(e.seeking ? '停止' : '搜台 ▶▶'))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _freqCtl,
                focusNode: _freqFocus,
                enabled: _ready,
                decoration: const InputDecoration(
                    labelText: '直接输入频率', suffixText: 'MHz', isDense: true,
                    border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (_) => _onEnter(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _ready ? _onEnter : null, child: const Text('调谐')),
          ]),
          const Spacer(),
          _audioRow(ready),
        ])),
      ),
    );
  }

  /// Fills the available height (so Spacer works) but scrolls instead of
  /// overflowing when the window is too short.
  Widget _fillOrScroll(Widget column) => LayoutBuilder(
      builder: (c, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: IntrinsicHeight(child: column),
            ),
          ));

  /// Bottom-bar layout: setting groups wrap on the left (second line on
  /// narrow windows), the last group (status) stays pinned to the right.
  Widget _barWrap(List<Widget> groups) => Row(children: [
        Expanded(
          child: Wrap(
              spacing: 20,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: groups.sublist(0, groups.length - 1)),
        ),
        const SizedBox(width: 12),
        groups.last,
      ]);

  static Widget _grp(List<Widget> c) => Row(mainAxisSize: MainAxisSize.min, children: c);

  Widget _audioRow(bool ready) {
    return Row(children: [
      const Icon(Icons.volume_up, size: 20),
      Expanded(child: Slider(
          value: e.volume, onChanged: e.setVolume,
          onChangeEnd: (_) => e.saveSettings())),
      Text('${(e.volume * 100).round()}%'),
      const SizedBox(width: 8),
      FilterChip(label: const Text('静音'), selected: e.muted, onSelected: e.setMuted),
      const SizedBox(width: 12),
      e.recElapsed == null
          ? OutlinedButton.icon(
              onPressed: ready ? e.startRecording : null,
              icon: const Icon(Icons.fiber_manual_record, color: _bad, size: 18),
              label: const Text('录音'))
          : FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _bad),
              onPressed: e.stopRecording,
              icon: const Icon(Icons.stop, size: 18),
              label: Text('停止  ${_mmss(e.recElapsed!)}')),
    ]);
  }

  Widget _stationList() {
    final t = Theme.of(context);
    final rows = <int, Station>{for (final s in e.stations) s.freq: s};
    for (final f in e.favorites) {
      rows.putIfAbsent(f, () => Station(f, null, true));
    }
    final freqs = rows.keys.toList()..sort();
    final current = (e.freq / 100000).round() * 100000;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('电台', style: t.textTheme.titleMedium),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _ready && e.scanProgress == null ? e.scan : null,
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('扫描全波段'),
            ),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: e.scanProgress ?? 0),
          const SizedBox(height: 8),
          Expanded(
            child: freqs.isEmpty
                ? Center(child: Text('还没有电台\n点击“扫描全波段”', textAlign: TextAlign.center,
                    style: TextStyle(color: t.hintColor)))
                : ListView.builder(
                    itemCount: freqs.length,
                    itemBuilder: (c, i) {
                      final s = rows[freqs[i]]!;
                      final fav = e.favorites.contains(s.freq);
                      final dim = !s.isStation && !fav;
                      return ListTile(
                        dense: true,
                        selected: s.freq == current,
                        leading: Icon(fav ? Icons.star : (s.isStation ? Icons.radio : Icons.radio_outlined),
                            color: fav ? _warn : (dim ? t.hintColor : _accent)),
                        title: Text('${(s.freq / 1e6).toStringAsFixed(1)} MHz',
                            style: TextStyle(color: dim ? t.hintColor : null)),
                        subtitle: Text(
                            [if (s.snrDb != null) '信噪比 ${s.snrDb!.toStringAsFixed(1)} dB',
                             if (dim) '弱台'].join(' · '),
                            style: TextStyle(color: t.hintColor)),
                        onTap: _ready ? () => _tuneTo(s.freq) : null,
                      );
                    },
                  ),
          ),
          Text('点击收听 · 灰色为接近阈值的弱台', style: TextStyle(color: t.hintColor, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: _barWrap([
          _grp([
            const Text('搜台灵敏度'),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: e.sensitivity,
              items: kSensitivity.keys
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: e.connected ? (v) => e.setSensitivity(v!) : null,
            ),
          ]),
          _grp([
            const Text('去加重'),
            const SizedBox(width: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('50 µs')),
                ButtonSegment(value: true, label: Text('75 µs')),
              ],
              selected: {e.deem75},
              onSelectionChanged: (s) => e.setDeemph(s.first),
            ),
          ]),
          _grp([
            const Text('锁定板上按键'),
            Switch(value: e.panelLock, onChanged: e.connected ? e.setLock : null),
          ]),
          _grp(_statusTail()),
        ]),
      ),
    );
  }

  List<Widget> _statusTail() {
    final t = Theme.of(context);
    const ledNames = ['系统', '调谐', '录制', '网络'];
    const ledColors = [_good, _accent, _bad, _warn];
    return [
          if (e.lagMs != null)
            Text('延迟 ${e.lagMs!.toStringAsFixed(0)} ms${e.lost > 0 ? ' · 丢失 ${e.lost}' : ''}',
                style: TextStyle(color: t.hintColor)),
          const SizedBox(width: 16),
          ActionChip(
            avatar: Icon(e.err == 0 ? Icons.check_circle : Icons.error,
                color: e.err == 0 ? _good : _bad, size: 18),
            label: Text(e.err == 0 ? '无错误' : '错误 0x${e.err.toRadixString(16).toUpperCase()} · 点击清除'),
            onPressed: e.connected ? e.clearErrors : null,
          ),
          const SizedBox(width: 16),
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 12, height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (e.leds >> i) & 1 == 1 ? ledColors[i] : const Color(0xFF3A3F47),
              ),
            ),
            const SizedBox(width: 4),
            Text(ledNames[i], style: TextStyle(color: t.hintColor, fontSize: 12)),
            const SizedBox(width: 10),
          ],
    ];
  }

  // ======================================================================
  // Airband (AM, narrowband IQ demodulated on the PC)
  // ======================================================================
  static String _mhz3(int hz) => (hz / 1e6).toStringAsFixed(3);

  void _onAirEnter() {
    final v = double.tryParse(_freqCtl.text.trim());
    if (v == null || v < kAirMin / 1e6 || v > kAirMax / 1e6) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入 118.000–137.000 之间的频率（MHz），例如 118.100')));
      return;
    }
    _freqFocus.unfocus();
    e.airTune(airSnap((v * 1e6).round(), e.airStep));
  }

  Future<void> _addAirChannel() async {
    final name = TextEditingController();
    final f = TextEditingController(text: _mhz3(e.freq));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('加入频道列表'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: f, decoration: const InputDecoration(
                labelText: '频率', suffixText: 'MHz')),
            const SizedBox(height: 8),
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(
                labelText: '名称（如 塔台 / 地面 / 进近 / ATIS）')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('加入')),
        ],
      ),
    );
    final v = double.tryParse(f.text.trim());
    if (ok == true && v != null && v * 1e6 >= kAirMin && v * 1e6 <= kAirMax) {
      e.addAirChannel(airSnap((v * 1e6).round(), e.airStep), name.text.trim());
    }
  }

  Widget _airTuner() {
    final t = Theme.of(context);
    final ready = e.connected && e.radioReady;
    final a = e.air;
    String badge;
    Color badgeColor;
    if (!ready) {
      badge = '射频未就绪';
      badgeColor = _bad;
    } else if (e.airScanning && !e.airListening) {
      badge = '扫描中…';
      badgeColor = _accent;
    } else if (e.airSquelch <= 0) {
      badge = '静噪关闭';
      badgeColor = _warn;
    } else if (a.open) {
      badge = '有通话';
      badgeColor = _good;
    } else {
      badge = '静默';
      badgeColor = t.hintColor;
    }
    final ch = e.airChannels.where((c) => c.freq == e.freq).firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _fillOrScroll(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(e.freq > 0 ? _mhz3(e.freq) : '---.---',
                style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()], height: 1.0)),
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(bottom: 8),
                child: Text('MHz  AM', style: TextStyle(fontSize: 20, color: t.hintColor))),
            const SizedBox(width: 16),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Chip(label: Text(badge), labelStyle: TextStyle(color: badgeColor),
                  side: BorderSide(color: badgeColor.withValues(alpha: 0.6))),
            ),
            ]))),
            IconButton(onPressed: ready ? _addAirChannel : null,
                icon: const Icon(Icons.playlist_add), tooltip: '把当前频率加入频道列表'),
          ]),
          Text([
            if (ch != null && ch.name.isNotEmpty) ch.name,
            '航空波段 118.000–137.000 MHz',
            '本振 ${(e.lo / 1e6).toStringAsFixed(4)} MHz',
            if (a.offsetHz != null) '载波偏移 ${(a.offsetHz! / 1000).toStringAsFixed(2)} kHz',
          ].join(' · '), style: TextStyle(color: t.hintColor)),
          const SizedBox(height: 12),
          _Meter('信噪比', a.snrDb / 30, '${a.snrDb.toStringAsFixed(1)} dB',
              a.open ? _good : (a.snrDb >= e.airSquelch - 2 ? _warn : t.hintColor)),
          _Meter('信号电平', (a.powerDb + 100) / 100, '${a.powerDb.toStringAsFixed(1)} dBFS', _accent),
          _Meter('音频电平', (e.levelDb + 60) / 60, '${e.levelDb.toStringAsFixed(1)} dBFS',
              e.levelDb > -1 ? _bad : _accent),
          const SizedBox(height: 8),
          SizedBox(
            // 150 px from a 720 px tall window, down to 70 px at the 640 px minimum
            height: (MediaQuery.sizeOf(context).height - 570).clamp(70.0, 150.0),
            child: _SpectrumView(spectrum: a.spectrumDb, bwHz: a.bwHz, open: a.open),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton(onPressed: _ready ? () => e.airStepBy(-1) : null,
                child: Text('− ${e.airStep == 8333 ? '8.33' : '25'} kHz')),
            OutlinedButton(onPressed: _ready ? () => e.airStepBy(1) : null,
                child: Text('+ ${e.airStep == 8333 ? '8.33' : '25'} kHz')),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _freqCtl,
                focusNode: _freqFocus,
                enabled: _ready,
                decoration: const InputDecoration(
                    labelText: '直接输入频率', suffixText: 'MHz', isDense: true,
                    border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onSubmitted: (_) => _onAirEnter(),
              ),
            ),
            FilledButton(onPressed: _ready ? _onAirEnter : null, child: const Text('调谐')),
          ]),
          const Spacer(),
          _audioRow(ready),
        ])),
      ),
    );
  }

  Widget _airChannelList() {
    final t = Theme.of(context);
    final list = e.airChannels;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 8),
                child: Text('频道', style: t.textTheme.titleMedium)),
            const SizedBox(width: 8),
            Expanded(child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
            IconButton(onPressed: _ready ? _addAirChannel : null,
                icon: const Icon(Icons.add), tooltip: '添加频道'),
            if (e.airScanning)
              FilledButton.icon(
                  onPressed: e.stopAirScan,
                  icon: const Icon(Icons.stop, size: 18),
                  label: Text(e.airScanBand ? '停止搜索' : '停止扫描'))
            else ...[
              FilledButton.tonalIcon(
                  onPressed: _ready ? () => e.startAirScan(band: true) : null,
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: const Text('全波段搜索')),
              FilledButton.tonalIcon(
                  onPressed: _ready && list.isNotEmpty ? e.startAirScan : null,
                  icon: const Icon(Icons.radar, size: 18),
                  label: const Text('扫描频道')),
            ],
            ])),
          ]),
          if (e.airScanning && e.airScanBand) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text(
                  e.airListening
                      ? '停在 ${_mhz3(e.freq)} MHz（有通话）· 第 ${e.bandSweeps} 遍 · 已发现 ${e.bandFound}'
                      : '搜索中 ${_mhz3(e.freq)} MHz · 第 ${e.bandSweeps} 遍 · 已发现 ${e.bandFound}',
                  style: TextStyle(color: e.airListening ? _good : _accent))),
              if (e.airListening)
                TextButton(onPressed: e.ignoreCurrent, child: const Text('跳过此频率')),
            ]),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: list.isEmpty
                ? Center(child: Text('还没有频道\n点“全波段搜索”自动寻找有通话的频率\n或调到已知频率后点 ＋ 加入',
                    textAlign: TextAlign.center, style: TextStyle(color: t.hintColor)))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) {
                      final ch = list[i];
                      final scanningHere = e.airScanning && !e.airScanBand && e.scanIndex == i;
                      final active = scanningHere && e.airListening;
                      return ListTile(
                        dense: true,
                        selected: ch.freq == e.freq,
                        leading: Icon(
                            active ? Icons.record_voice_over : (scanningHere ? Icons.radar : Icons.flight),
                            color: active ? _good : (scanningHere ? _accent : t.hintColor)),
                        title: Text('${_mhz3(ch.freq)} MHz'
                            '${ch.name.isEmpty ? '' : '  ${ch.name}'}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '删除',
                          onPressed: () => e.removeAirChannel(ch),
                        ),
                        onTap: _ready ? () { e.stopAirScan(); e.airTune(ch.freq); } : null,
                      );
                    },
                  ),
          ),
          Row(children: [
            Expanded(child: Text('点击收听 · 遇到通话自动停留，静默 3 秒后继续',
                style: TextStyle(color: t.hintColor, fontSize: 12))),
            if (e.airIgnore.isNotEmpty)
              TextButton(
                onPressed: e.clearIgnore,
                child: Text('已跳过 ${e.airIgnore.length} 个固定载波 · 清除',
                    style: const TextStyle(fontSize: 12)),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _airBottomBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: _barWrap([
          _grp([
          const Text('静噪'),
          SizedBox(
            width: 160,
            // left end (3) = off; usable thresholds start at kAirSqMin (4 dB)
            child: Slider(
              value: e.airSquelch <= 0 ? 3 : e.airSquelch.clamp(kAirSqMin, 20),
              min: 3, max: 20, divisions: 17,
              onChanged: (v) => e.setAirSquelch(v < kAirSqMin ? 0 : v),
              onChangeEnd: (_) => e.saveSettings(),
            ),
          ),
          SizedBox(width: 48, child: Text(e.airSquelch <= 0 ? '关' : '${e.airSquelch.round()} dB')),
          ]),
          _grp([
            const Text('带宽'),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: e.airBw,
              items: kAirBw.keys.map((k) => DropdownMenuItem(value: k, child: Text(k))).toList(),
              onChanged: (v) => e.setAirBw(v!),
            ),
          ]),
          _grp([
            const Text('步进'),
            const SizedBox(width: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 25000, label: Text('25 kHz')),
                ButtonSegment(value: 8333, label: Text('8.33 kHz')),
              ],
              selected: {e.airStep},
              onSelectionChanged: (v) => e.setAirStep(v.first),
            ),
          ]),
          _grp([
            Checkbox(value: e.airRecIq, onChanged: (v) => e.setAirRecIq(v ?? false)),
            const Text('录音同时保存 IQ'),
          ]),
          _grp(_statusTail()),
        ]),
      ),
    );
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  static double _log10(double v) => math.log(v) / math.ln10;
}

/// Baseband spectrum of the 48 kS/s IQ (+/-24 kHz) with the channel filter
/// band shaded.
class _SpectrumView extends StatelessWidget {
  const _SpectrumView({required this.spectrum, required this.bwHz, required this.open});
  final List<double> spectrum;
  final double bwHz;
  final bool open;

  @override
  Widget build(BuildContext context) => CustomPaint(
      painter: _SpectrumPainter(List<double>.of(spectrum), bwHz, open,
          Theme.of(context).hintColor),
      size: Size.infinite);
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.db, this.bwHz, this.open, this.hint);
  final List<double> db;
  final double bwHz;
  final bool open;
  final Color hint;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)),
        Paint()..color = const Color(0xFF1B1F26));
    const span = AirDemod.fs / 2;
    double x(double hz) => (hz + span) / (2 * span) * size.width;
    // channel band
    canvas.drawRect(Rect.fromLTRB(x(-bwHz), 0, x(bwHz), size.height),
        Paint()..color = _accent.withValues(alpha: 0.12));
    final grid = Paint()..color = const Color(0xFF2E333D)..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var k = -20; k <= 20; k += 10) {
      final gx = x(k * 1000.0);
      canvas.drawLine(Offset(gx, 0), Offset(gx, size.height), grid);
      tp.text = TextSpan(text: k == 0 ? '0' : '${k > 0 ? '+' : ''}$k kHz',
          style: TextStyle(color: hint, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(gx + 3, size.height - tp.height - 2));
    }
    if (db.isEmpty || db.every((v) => v == 0)) return;
    final sorted = List<double>.of(db)..sort();
    final floor = sorted[sorted.length ~/ 5];
    final lo = floor - 10, hi = floor + 60;
    final path = Path();
    for (var i = 0; i < db.length; i++) {
      final px = i / (db.length - 1) * size.width;
      final py = size.height * (1 - ((db[i] - lo) / (hi - lo)).clamp(0.0, 1.0));
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = open ? _good : _accent);
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) => true;
}

class _Meter extends StatelessWidget {
  const _Meter(this.label, this.frac, this.text, this.color);
  final String label;
  final double frac;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: TextStyle(color: Theme.of(context).hintColor))),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: frac.clamp(0.0, 1.0), minHeight: 12, color: color,
              backgroundColor: const Color(0xFF2B2F38)),
          ),
        ),
        SizedBox(width: 96, child: Text(text, textAlign: TextAlign.right)),
      ]),
    );
  }
}
