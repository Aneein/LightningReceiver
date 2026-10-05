// Lightning Receiver - radio engine: bridge connection, live audio, status
// polling, tuning/seek/scan, recording, bridge + AD9361 bring-up helpers.
// Two modes: FM broadcast (FPGA demodulates, 48 kHz PCM in the DDR ring) and
// airband AM (FPGA narrowband IQ mode, 48 kS/s complex; AirDemod on the PC).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'air_dsp.dart';
import 'bridge.dart';
import 'wave_out.dart';

// ---- register map (rtl/include/lr_defines.vh) ----
const int kLr = 0x44A20000;
const int kAdRx = 0x44A00000;
const int rId = 0x000, rControl = 0x008, rRfFreq = 0x010, rDdc = 0x024;
const int rAudioCfg = 0x038, rErr = 0x048;
const int rWrWords = 0x06C, rRingBase = 0x070, rRingWords = 0x074;
const int rUi = 0x07C, rSeek = 0x080, rSeekCfg = 0x084;
const int rPower = 0x088, rQual = 0x08C, rThr = 0x090;
const int rAudioStatus = 0x068, rRecStart = 0x078;
const Set<int> kIdsOk = {0x4C520002, 0x4C520003, 0x4C520004, 0x4C520005};
const int kIdAir = 0x4C520005; // first design with the narrowband IQ mode
const int kRecBit = 1 << 16, kDeem75Bit = 1 << 18, kIqBit = 1 << 19;
const int kStartLagWords = 600; // ~0.2 s queued when audio (re)starts (FM)

// ---- airband ----
/// LO for the whole airband: 12.5 kHz from every 25 kHz channel, so no
/// channel sits on the AD9361 DC / dc_correction notch; +/-10 MHz DDC window
/// covers 117.9625-137.9625 MHz.
const int kAirLo = 127962500;
const int kAirMin = 118000000, kAirMax = 137000000;
const int kAirSettleWords = 48; // ~8 ms of IQ discarded after a retune
const Map<String, double> kAirBw = {'窄 ±3 kHz': 3000, '标准 ±4 kHz': 4000, '宽 ±6 kHz': 6000};

enum RadioMode { fm, air }

class AirChannel {
  AirChannel(this.freq, this.name);
  final int freq;
  String name;
  Map<String, dynamic> toJson() => {'freq': freq, 'name': name};
  static AirChannel fromJson(Map<String, dynamic> j) =>
      AirChannel(j['freq'] as int, j['name'] as String? ?? '');
}

/// Snaps [hz] to the airband channel grid (25 kHz or 8.33 kHz = 25/3 kHz).
int airSnap(int hz, int step) {
  final st = step == 8333 ? 25000 / 3 : step.toDouble();
  return (kAirMin + ((hz - kAirMin) / st).round() * st).round();
}
const double kFullScalePower = 32768.0 * 32768.0;

const Map<String, int> kSensitivity = {
  '严格': 0x0133,
  '标准': 0x0140,
  '宽松': 0x015A,
  '很宽松': 0x0173,
};

int s32(int v) => (v & 0x80000000) != 0 ? v - 0x100000000 : v;

/// Carrier-to-noise ratio (dB) from the envelope flatness (fm_signal_meter).
double? cnrDb(double r) {
  if (r >= 1.999) return null;
  if (r <= 1.002) return 30.0;
  final a = 1.0 - r, b = 4.0 - 2.0 * r, c = 2.0 - r;
  final disc = b * b - 4 * a * c;
  if (disc < 0) return null;
  final s = (-b - math.sqrt(disc)) / (2 * a);
  return s > 0 ? 10 * math.log(s) / math.ln10 : null;
}

class Station {
  Station(this.freq, this.snrDb, this.isStation);
  final int freq;
  final double? snrDb;
  final bool isStation;
  Map<String, dynamic> toJson() =>
      {'freq': freq, 'snr_db': snrDb, 'station': isStation};
  static Station fromJson(Map<String, dynamic> j) => Station(
      j['freq'] as int, (j['snr_db'] as num?)?.toDouble(), j['station'] == true);
}

enum CheckState { pending, running, ok, warn, fail }

enum Phase { checking, ready, failed }

/// One line of the start-up self test.
class CheckItem {
  CheckItem(this.id, this.title, {this.required = true});
  final String id;
  final String title;
  final bool required;
  CheckState state = CheckState.pending;
  String detail = '';
  String hint = '';
}

class RadioEngine extends ChangeNotifier {
  // ---------------- settings ----------------
  String vivadoBat = r'D:\Xilinx\Vivado\2021.1\bin\vivado.bat';
  bool useVivadoBridge = false; // fallback for bitstreams without the LRJ bridge
  int port = 5555;
  double volume = 0.8;
  bool muted = false;
  String sensitivity = '标准';
  bool deem75 = false;
  List<int> favorites = [];
  List<Station> stations = [];
  RadioMode mode = RadioMode.fm;
  int airFreq = 118100000;
  int airStep = 25000; // 25000 or 8333
  String airBw = '标准 ±4 kHz';
  double airSquelch = 6.0; // dB; 0 = squelch off
  bool airRecIq = false;
  List<AirChannel> airChannels = [];
  int fmLo = 97950000, fmFreq = 98000000; // restored when leaving the airband
  bool fmPanelLock = false;

  // ---------------- live state ----------------
  Phase phase = Phase.checking;
  List<CheckItem> checks = [];
  int designId = 0;
  bool get airSupported => designId >= kIdAir;
  final AirDemod air = AirDemod();
  bool airScanning = false;
  int scanIndex = -1;
  bool get airListening => airScanning && _scanPhase == 'listen';
  String linkKind = '';
  bool connected = false;
  String connMsg = '正在连接…';
  bool radioReady = false;
  int lo = 0, freq = 0, rangeHz = 10000000;
  double flat = 2.0;
  bool station = false, seeking = false, panelLock = false;
  int power = 0, leds = 0, err = 0, seekStatus = 0;
  double levelDb = -90;
  double? lagMs;
  int lost = 0;
  String busy = '';
  String info = '';
  double? scanProgress;
  Duration? recElapsed;
  final _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;

  Bridge? _br;
  final WaveOut _wave = WaveOut();
  int? _rp;
  int _ring = 0, _base = 0;
  bool _running = true;
  bool _scanning = false;
  Process? _bridgeProc;
  Process? _jtagdProc;
  bool _preflightBusy = false;
  Timer? _retryTimer;
  RandomAccessFile? _rec;
  String? _recPath;
  int _recBytes = 0;
  RandomAccessFile? _recIq;
  int _recIqBytes = 0;
  bool _iq = false; // format of the ring session being read
  int _sessionStart = 0;
  int? _skipTo; // retune: resume reading here (ring words)
  int _tuneGen = 0, _appliedGen = 0;
  String _scanPhase = '';
  DateTime _scanT0 = DateTime.now();
  DateTime? _quietSince;
  DateTime? _recStart;
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
  int _dbgPolls = 0;

  // ---------------- paths ----------------
  static String get _appDataDir =>
      '${Platform.environment['APPDATA'] ?? '.'}\\LightningReceiver';
  static String get _settingsFile => '$_appDataDir\\settings.json';
  static String get recordDir =>
      '${Platform.environment['USERPROFILE'] ?? '.'}\\Music\\LightningReceiver';

  /// Bundled resource (installer: `<exe dir>\resources`) with a development
  /// fallback to the repository tools/hw tree.
  static String? resource(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir\\resources\\$name',
      'D:\\workspace\\LightningReceiver\\tools\\hw\\$name',
      'D:\\workspace\\LightningReceiver\\tools\\hw\\ad9361_jtag\\$name',
      'D:\\workspace\\LightningReceiver\\tools\\hw\\lr_jtagd\\$name',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  // ---------------- lifecycle ----------------
  Future<void> start() async {
    await _loadSettings();
    _wave.open();
    unawaited(_loop());
    await runPreflight();
  }

  Future<void> shutdown() async {
    _running = false;
    await stopRecording();
    await _disconnect('');
    _wave.close();
    _retryTimer?.cancel();
    if (_bridgeProc != null) {
      await Process.run('taskkill', ['/PID', '${_bridgeProc!.pid}', '/T', '/F']);
    }
    _jtagdProc?.kill();
    await _saveSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final j = jsonDecode(await File(_settingsFile).readAsString())
          as Map<String, dynamic>;
      vivadoBat = j['vivado_bat'] as String? ?? vivadoBat;
      useVivadoBridge = j['use_vivado_bridge'] == true;
      port = j['port'] as int? ?? port;
      volume = (j['volume'] as num?)?.toDouble() ?? volume;
      sensitivity = j['sensitivity'] as String? ?? sensitivity;
      if (!kSensitivity.containsKey(sensitivity)) sensitivity = '标准';
      deem75 = j['deem75'] == true;
      favorites = (j['favorites'] as List?)?.cast<int>() ?? [];
      stations = (j['stations'] as List?)
              ?.map((e) => Station.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      mode = j['mode'] == 'air' ? RadioMode.air : RadioMode.fm;
      airFreq = (j['air_freq'] as int? ?? airFreq).clamp(kAirMin, kAirMax);
      airStep = j['air_step'] == 8333 ? 8333 : 25000;
      airBw = kAirBw.containsKey(j['air_bw']) ? j['air_bw'] as String : airBw;
      airSquelch = (j['air_squelch'] as num?)?.toDouble() ?? airSquelch;
      airRecIq = j['air_rec_iq'] == true;
      airChannels = (j['air_channels'] as List?)
              ?.map((e) => AirChannel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      fmLo = j['fm_lo'] as int? ?? fmLo;
      fmFreq = j['fm_freq'] as int? ?? fmFreq;
      fmPanelLock = j['fm_panel_lock'] == true;
    } catch (_) {}
    air.bwHz = kAirBw[airBw]!;
    air.squelchDb = airSquelch;
  }

  Future<void> _saveSettings() async {
    try {
      await Directory(_appDataDir).create(recursive: true);
      await File(_settingsFile).writeAsString(const JsonEncoder.withIndent(' ')
          .convert({
        'vivado_bat': vivadoBat,
        'use_vivado_bridge': useVivadoBridge,
        'port': port,
        'volume': volume,
        'sensitivity': sensitivity,
        'deem75': deem75,
        'favorites': favorites,
        'stations': stations.map((s) => s.toJson()).toList(),
        'mode': mode == RadioMode.air ? 'air' : 'fm',
        'air_freq': airFreq,
        'air_step': airStep,
        'air_bw': airBw,
        'air_squelch': airSquelch,
        'air_rec_iq': airRecIq,
        'air_channels': airChannels.map((c) => c.toJson()).toList(),
        'fm_lo': fmLo,
        'fm_freq': fmFreq,
        'fm_panel_lock': fmPanelLock,
      }));
    } catch (_) {}
  }

  void saveSettings() => unawaited(_saveSettings());

  void _error(String msg) => _errors.add(msg);

  // ---------------- connection ----------------
  Future<void> _disconnect(String why) async {
    final br = _br;
    _br = null;
    _rp = null;
    radioReady = false;
    connected = false;
    if (why.isNotEmpty) connMsg = why;
    if (br != null) await br.close();
    notifyListeners();
  }

  Future<void> _loop() async {
    while (_running) {
      if (phase != Phase.ready || _br == null) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      if (_br!.closed) {
        await _linkLost('JTAG 服务连接已断开');
        continue;
      }
      try {
        final fed = await _pumpAudio();
        if (DateTime.now().difference(_lastPoll).inMilliseconds > 250) {
          _lastPoll = DateTime.now();
          await _pollStatus();
        }
        if (airScanning) await _airScanStep();
        if (!fed) {
          await Future.delayed(Duration(milliseconds: airScanning ? 4 : 20));
        }
      } catch (e) {
        await _linkLost('连接中断：$e');
      }
    }
  }

  /// Runtime link failure: back to the self test, which re-checks every
  /// stage and pinpoints what broke.
  Future<void> _linkLost(String why) async {
    await _disconnect(why);
    if (!_running) return;
    info = why;
    phase = Phase.checking;
    notifyListeners();
    await runPreflight();
  }

  // ======================================================================
  // Start-up self test
  // ======================================================================
  CheckItem _ck(String id) => checks.firstWhere((c) => c.id == id);

  void _set(String id, CheckState st, [String detail = '', String hint = '']) {
    final c = _ck(id);
    c.state = st;
    c.detail = detail;
    c.hint = hint;
    if (kDebugMode && st != CheckState.running) {
      debugPrint('PREFLIGHT ${c.id} ${st.name}: $detail${hint.isEmpty ? '' : ' | $hint'}');
    }
    notifyListeners();
  }

  static String _hex(int v) => '0x${v.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  /// Checks the whole chain PC -> cable -> FPGA -> AD9361 stage by stage,
  /// fixes what can be fixed automatically (starts the JTAG service,
  /// initialises the RF front end) and stops at the first broken stage.
  Future<void> runPreflight() async {
    if (_preflightBusy) return;
    _preflightBusy = true;
    _retryTimer?.cancel();
    phase = Phase.checking;
    checks = [
      CheckItem('audio', '音频输出设备', required: false),
      CheckItem('link', 'JTAG 下载器与通信服务'),
      CheckItem('fpga', 'FPGA 设计（FM 收音机 bitstream）'),
      CheckItem('fabric', 'FPGA 逻辑运行（时钟 / 复位 / DDR4）'),
      CheckItem('ad9361', 'AD9361 射频子卡（SPI）'),
      CheckItem('rf', '射频初始化与采样数据'),
      CheckItem('net', '100G 网络链路（可选）', required: false),
    ];
    notifyListeners();
    var retryable = true;
    try {
      // ---- 1. audio ----
      _set('audio', CheckState.running);
      if (_wave.isOpen || _wave.open()) {
        _set('audio', CheckState.ok, '系统默认输出设备，48 kHz 单声道');
      } else {
        _set('audio', CheckState.warn, '没有可用的音频输出设备', '可以继续使用，但听不到声音；请检查声卡或耳机');
      }

      // ---- 2. cable + JTAG service ----
      _set('link', CheckState.running, '正在连接…');
      final link = await _ensureLink();
      if (link != null) {
        retryable = link.$2;
        _set('link', CheckState.fail, link.$1, link.$3);
        return _fail(retryable);
      }
      final br = _br!;

      // ---- 3. FPGA design ----
      _set('fpga', CheckState.running);
      int ident;
      try {
        ident = await br.read(kLr + rId);
      } catch (e) {
        _set('fpga', CheckState.fail, 'FPGA 寄存器读不出来：$e',
            'FPGA 可能未配置、逻辑时钟/复位异常，或 JTAG 桥没有 AXI 响应');
        return _fail(true);
      }
      if (!kIdsOk.contains(ident)) {
        _set('fpga', CheckState.fail, '设计 ID ${_hex(ident)} 不是 FM 收音机版本',
            '请烧写 FM 版 bitstream（设计 ID 0x4C520002 – 0x4C520005）');
        return _fail(false);
      }
      designId = ident;
      _set('fpga', CheckState.ok, '设计 ID ${_hex(ident)}'
          '${airSupported ? ' · 支持航空波段' : ''}');

      // ---- 4. fabric alive + DDR ----
      _set('fabric', CheckState.running, '检查运行时间计数与 DDR4 校准…');
      final up0 = await br.read(kLr + 0x04C);
      await Future.delayed(const Duration(milliseconds: 1150));
      final up1 = await br.read(kLr + 0x04C);
      if (up1 == up0) {
        _set('fabric', CheckState.fail, '运行时间计数器不增长（$up0 s）',
            'FPGA 225 MHz 逻辑没有运行或一直处于复位，请检查 bitstream / 时钟 / 复位');
        return _fail(true);
      }
      final ddr = await br.read(kLr + 0x040);
      if ((ddr >> 29) & 1 == 0) {
        _set('fabric', CheckState.fail, 'DDR4 未完成校准',
            '音频环形缓冲依赖 DDR4；请给板卡断电重启后重新检测');
        return _fail(true);
      }
      final err = (await br.read(kLr + rErr)) & 0xFF;
      _set('fabric', err == 0 ? CheckState.ok : CheckState.warn,
          '已运行 $up1 s · DDR4 已校准${err == 0 ? '' : ' · 错误状态 0x${err.toRadixString(16)}'}',
          err == 0 ? '' : '可在主界面底部点击错误标记清除');

      // ---- 5. AD9361 present ----
      _set('ad9361', CheckState.running);
      final pid = int.parse((await br.cmd('S 003700')).trim(), radix: 16) & 0xFF;
      if (pid != 0x0A) {
        _set('ad9361', CheckState.fail,
            '产品 ID 寄存器读到 0x${pid.toRadixString(16).padLeft(2, '0')}（应为 0x0A）',
            '检查 FMC 子卡是否插好、是否供电，FMC 的 VADJ 是否为 1.8 V');
        return _fail(true);
      }
      _set('ad9361', CheckState.ok, 'AD9361 已应答（产品 ID 0x0A）');

      // ---- 6. RF initialised + samples flowing ----
      _set('rf', CheckState.running);
      if (!await _rfReady(br)) {
        _set('rf', CheckState.running, '射频尚未初始化，正在自动初始化（约 20 秒）…');
        final why = await _runInit();
        if (why != null) {
          _set('rf', CheckState.fail, '射频初始化失败', why);
          return _fail(false);
        }
        if (!await _rfReady(br)) {
          _set('rf', CheckState.fail, '初始化完成，但没有采样数据',
              'AD9361 与 FPGA 之间的 LVDS 数据链路异常，请重新检测或给板卡重新上电');
          return _fail(true);
        }
      }
      final lo0 = await br.read(kLr + rRfFreq);
      _set('rf', CheckState.ok, '本振 ${(lo0 / 1e6).toStringAsFixed(3)} MHz，采样数据正常');

      // ---- 7. network (optional) ----
      final net = await br.read(kLr + 0x044);
      if ((net >> 19) & 1 == 1) {
        _set('net', CheckState.ok, 'CMAC 100G 链路已建立');
      } else {
        _set('net', CheckState.warn, '未连接', '不影响收音；网络音频需要 QSFP28 连接到主机网卡');
      }

      await _attach(br);
      phase = Phase.ready;
      if (kDebugMode) debugPrint('PREFLIGHT READY');
      info = '';
      notifyListeners();
    } catch (e) {
      final c = checks.firstWhere((c) => c.state == CheckState.running,
          orElse: () => _ck('link'));
      c.state = CheckState.fail;
      c.detail = '检测中出错：$e';
      _fail(true);
    } finally {
      _preflightBusy = false;
    }
  }

  void _fail(bool retryable) {
    phase = Phase.failed;
    notifyListeners();
    if (retryable && _running) {
      // Transient problems (cable, power, busy) clear themselves: re-check.
      _retryTimer = Timer(const Duration(seconds: 5), () => unawaited(runPreflight()));
    }
  }

  Future<bool> _rfReady(Bridge br) async {
    final rstn = await br.read(kAdRx + 0x40);
    final ui = await br.read(kLr + rUi);
    return (rstn & 3) == 3 && ((ui >> 22) & 1) == 1;
  }

  /// Makes sure a JTAG service answers on [port]; starts lr_jtagd (or the
  /// Vivado bridge if configured).  Returns null on success, otherwise
  /// (message, retryable, hint).
  Future<(String, bool, String)?> _ensureLink() async {
    if (_br != null && !_br!.closed) {
      await _br!.close();
      _br = null;
    }
    // Already running (our daemon from a previous start, or a Vivado bridge)?
    final existing = await _tryConnect();
    if (existing != null) return null;

    if (useVivadoBridge) {
      if (!File(vivadoBat).existsSync()) {
        return ('找不到 Vivado：$vivadoBat', false, '在“设置”中指定 vivado.bat，或关闭“使用 Vivado JTAG 桥”');
      }
      _set('link', CheckState.running, '正在启动 Vivado JTAG 桥（约 30 秒）…');
      await startBridge();
      return await _tryConnect() == null
          ? ('Vivado JTAG 桥启动失败', true, '详见 %APPDATA%\\LightningReceiver\\bridge.log')
          : null;
    }

    final exe = resource('lr_jtagd.exe');
    if (exe == null) {
      return ('缺少 lr_jtagd.exe', false, '请重新安装本软件');
    }
    _set('link', CheckState.running, '正在检测 JTAG 下载器与 FPGA…');
    final pr = await Process.run(exe, ['--probe']);
    final out = '${pr.stdout}';
    String kv(String k) {
      final m = RegExp('$k=(\\S+)').firstMatch(out);
      return m == null ? '' : m.group(1)!;
    }
    switch (pr.exitCode) {
      case 0:
      case 8:
        break;
      case 2:
        return ('未安装 FTDI 驱动（找不到 ftd2xx.dll）', false,
            '安装 FTDI D2XX 驱动（ftdichip.com）后重新检测');
      case 3:
        return ('未检测到 JTAG 下载器（FT2232H）', true,
            '检查 USB-C 线与板卡电源；设备管理器中应出现 “USB Serial Converter A”');
      case 4:
        return ('JTAG 下载器被其他程序占用', true,
            '请关闭 Vivado 的 Hardware Manager（或 hw_server）后重新检测');
      case 5:
        return ('JTAG 链无响应（IDCODE ${kv('idcode')}）', true,
            '板卡是否上电？FPGA 是否在 JTAG 链上？');
      case 6:
        return ('FPGA 中没有 LR JTAG 桥（IDCODE ${kv('idcode')}）', false,
            '请烧写设计 ID 0x4C520004 或更新的 bitstream；旧版 bitstream 可在“设置”中改用 Vivado JTAG 桥');
      case 7:
        return ('JTAG 桥没有 AXI 响应', true,
            'FPGA 逻辑时钟或复位异常；请给板卡断电重启');
      default:
        return ('JTAG 检测失败（代码 ${pr.exitCode}）', true, out.trim());
    }
    _set('link', CheckState.running,
        '下载器 ${kv('serial')} · IDCODE ${kv('idcode')} · 正在启动 lr_jtagd…');
    _jtagdProc?.kill();
    final proc = await Process.start(exe, ['--port', '$port']);
    _jtagdProc = proc;
    final ready = Completer<String?>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (ready.isCompleted) return;
      if (l.startsWith('LR_JTAGD_READY')) ready.complete(null);
      if (l.startsWith('LR_JTAGD_FAIL')) ready.complete(l);
    });
    unawaited(proc.exitCode.then((c) {
      if (!ready.isCompleted) ready.complete('lr_jtagd 退出（代码 $c）');
    }));
    final r = await ready.future
        .timeout(const Duration(seconds: 15), onTimeout: () => 'lr_jtagd 启动超时');
    if (r != null) return ('JTAG 服务启动失败：$r', true, '');
    if (await _tryConnect() == null) return ('无法连接 lr_jtagd（端口 $port）', true, '');
    return null;
  }

  /// Connects to the JTAG service and describes it in the link check.
  Future<Bridge?> _tryConnect() async {
    try {
      final br = await Bridge.connect(port: port);
      String what;
      try {
        final info = await br.cmd('I');
        final m = RegExp(r'serial=(\S+).*tck_khz=(\d+)').firstMatch(info);
        final idc = RegExp(r'idcode=(\S+)').firstMatch(info)?.group(1) ?? '';
        what = 'lr_jtagd · 下载器 ${m?.group(1) ?? '?'} · TCK ${(int.parse(m?.group(2) ?? '0') / 1000).toStringAsFixed(0)} MHz · IDCODE $idc';
      } on BridgeException {
        what = 'Vivado JTAG 桥';
      }
      _br = br;
      linkKind = what;
      _set('link', CheckState.ok, what);
      return br;
    } on SocketException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Final hand-over to the radio: ring geometry, REC on, preferences.
  Future<void> _attach(Bridge br) async {
    _base = await br.read(kLr + rRingBase);
    _ring = await br.read(kLr + rRingWords);
    final cfg = await br.read(kLr + rAudioCfg);
    await br.write(kLr + rAudioCfg, cfg | kRecBit);
    await br.write(kLr + rThr,
        (await br.read(kLr + rThr)) & 0xFFFF0000 | kSensitivity[sensitivity]!);
    final c2 = await br.read(kLr + rAudioCfg);
    await br.write(kLr + rAudioCfg, deem75 ? c2 | kDeem75Bit : c2 & ~kDeem75Bit);
    _rp = null;
    if (mode == RadioMode.air && !airSupported) {
      mode = RadioMode.fm;
      info = '当前 bitstream（${_hex(designId)}）不支持航空波段，已切换到 FM 广播';
    }
    if (mode == RadioMode.air) {
      final why = await _enterAir(br);
      if (why != null) {
        mode = RadioMode.fm;
        _error('进入航空波段失败：\n$why');
        await _setStreamFormat(br, false);
      }
    } else {
      await _setStreamFormat(br, false);
    }
    connected = true;
    radioReady = true;
    connMsg = '已连接 · $linkKind';
  }

  /// Puts the DDR audio ring into FM-PCM or narrowband-IQ format.  The
  /// packer latches the format at a recording-session start, so a change
  /// restarts the session; reading resumes at the new session's start.
  Future<void> _setStreamFormat(Bridge br, bool iq) async {
    final cfg = await br.read(kLr + rAudioCfg);
    final st = await br.read(kLr + rAudioStatus);
    final want = iq ? cfg | kIqBit : cfg & ~kIqBit;
    final sessionIq = ((st >> 3) & 1) == 1;
    if (sessionIq != iq || (cfg & kRecBit) == 0 || want != cfg) {
      await br.write(kLr + rAudioCfg, want & ~kRecBit);
      await Future.delayed(const Duration(milliseconds: 5));
      await br.write(kLr + rAudioCfg, want | kRecBit);
    }
    _sessionStart = await br.read(kLr + rRecStart);
    _iq = iq;
    _rp = null;
    _skipTo = null;
    air.reset();
  }

  /// Airband hardware setup: LO at [kAirLo], channel on the DDC, panel keys
  /// locked (the FM seek would move the DDC), IQ stream.  Null = success.
  Future<String?> _enterAir(Bridge br) async {
    final curLo = await br.read(kLr + rRfFreq);
    if ((curLo - kAirLo).abs() > 1000) {
      final why = await _runInit(loHz: kAirLo, tuneHz: airFreq);
      if (why != null) return why;
    } else {
      await br.write(kLr + rDdc, airFreq - curLo);
    }
    lo = await br.read(kLr + rRfFreq); // airTune() computes the DDC from it
    freq = airFreq;
    await setLock(true);
    air.bwHz = kAirBw[airBw]!;
    air.squelchDb = airSquelch;
    await _setStreamFormat(br, true);
    return null;
  }

  /// Switches between FM broadcast and the airband (LO change, ~5 s).
  Future<void> setMode(RadioMode m) async {
    final br = _br;
    if (m == mode || br == null || busy.isNotEmpty) return;
    if (m == RadioMode.air && !airSupported) {
      _error('当前 bitstream（${_hex(designId)}）不支持航空波段。\n'
          '请烧写设计 ID 0x4C520005 或更新的 bitstream。');
      return;
    }
    stopAirScan();
    await stopRecording();
    busy = m == RadioMode.air
        ? '正在切换到航空波段（重设本振，约 5 秒）…'
        : '正在切换到 FM 广播（重设本振，约 5 秒）…';
    notifyListeners();
    try {
      if (m == RadioMode.air) {
        fmLo = lo;
        fmFreq = freq;
        fmPanelLock = panelLock;
        mode = m;
        final why = await _enterAir(br);
        if (why != null) {
          mode = RadioMode.fm;
          await _setStreamFormat(br, false);
          _error('切换到航空波段失败：\n$why');
        }
      } else {
        mode = m;
        await _setStreamFormat(br, false);
        await setLock(fmPanelLock);
        final why = await _runInit(loHz: fmLo, tuneHz: fmFreq);
        if (why != null) _error('射频重设失败：\n$why');
      }
    } catch (e) {
      _error('切换模式失败：$e');
    } finally {
      busy = '';
      saveSettings();
      notifyListeners();
    }
  }

  // ---------------- audio ----------------
  Future<bool> _pumpAudio() async {
    final br = _br;
    if (br == null || !radioReady || _ring == 0) return false;
    _wave.pump();
    final wp = await br.read(kLr + rWrWords);
    final lagW = _iq ? 2 * kStartLagWords : kStartLagWords;
    if (_skipTo != null) {
      // retune: drop everything up to the settled point
      if (((wp - _skipTo!) & 0xFFFFFFFF) >= 0x80000000) return false;
      _rp = _skipTo;
      _skipTo = null;
      air.reset();
      _appliedGen = _tuneGen;
    }
    if (_rp == null) {
      // a new session must not be read before its start (other format)
      if (((wp - _sessionStart) & 0xFFFFFFFF) < lagW) return false;
      _rp = (wp - lagW) & 0xFFFFFFFF;
    }
    var avail = (wp - _rp!) & 0xFFFFFFFF;
    if (avail > _ring - 2048) {
      lost += avail;
      _rp = (wp - lagW) & 0xFFFFFFFF;
      avail = lagW;
    }
    if (avail == 0) return false;
    avail = math.min(avail, 1500);
    final first = _rp! % _ring;
    final n1 = math.min(avail, _ring - first);
    final bb = BytesBuilder(copy: false)
      ..add(await br.readRingWords(_base + first * 32, n1));
    if (avail > n1) bb.add(await br.readRingWords(_base, avail - n1));
    _rp = (_rp! + avail) & 0xFFFFFFFF;
    final raw = bb.takeBytes();
    Int16List x;
    if (_iq) {
      if (_recIq != null) {
        await _recIq!.writeFrom(raw);
        _recIqBytes += raw.length;
      }
      x = air.process(raw.buffer.asInt16List(raw.offsetInBytes, raw.length ~/ 2));
    } else {
      x = raw.buffer.asInt16List(raw.offsetInBytes, raw.length ~/ 2);
    }
    if (_rec != null) {
      await _rec!.writeFrom(x.buffer.asUint8List(x.offsetInBytes, x.lengthInBytes));
      _recBytes += x.lengthInBytes;
    }
    var acc = 0.0;
    for (final v in x) {
      acc += v * v;
    }
    final rms = x.isEmpty ? 0.0 : math.sqrt(acc / x.length);
    levelDb = 20 * math.log(math.max(rms, 1.0) / 32768.0) / math.ln10;
    final g = (muted || _scanning || (airScanning && !airListening)) ? 0.0 : volume;
    final out = Int16List(x.length);
    for (var i = 0; i < x.length; i++) {
      out[i] = (x[i] * g).round().clamp(-32768, 32767);
    }
    _wave.push(out.buffer.asUint8List());
    return true;
  }

  // ---------------- status ----------------
  Future<void> _pollStatus() async {
    final br = _br!;
    lo = await br.read(kLr + rRfFreq);
    final ddc = s32(await br.read(kLr + rDdc));
    freq = lo + ddc;
    final q = await br.read(kLr + rQual);
    flat = (q & 0xFFFF) / 256.0;
    station = ((q >> 16) & 1) == 1;
    power = await br.read(kLr + rPower);
    final ui = await br.read(kLr + rUi);
    leds = (ui >> 16) & 0xF;
    panelLock = ((ui >> 20) & 1) == 1;
    final adcActive = ((ui >> 22) & 1) == 1;
    seekStatus = await br.read(kLr + rSeek);
    seeking = (seekStatus & 1) == 1;
    err = (await br.read(kLr + rErr)) & 0xFF;
    rangeHz = ((await br.read(kLr + rSeekCfg)) >> 16) * 1000;
    final acfg = await br.read(kLr + rAudioCfg);
    if (acfg & kRecBit == 0) {
      // Live audio rides on the DDR audio ring: re-enable it if KEY3 (or
      // anything else) switched recording off.
      await br.write(kLr + rAudioCfg, acfg | kRecBit);
      info = '实时播放依赖板上 DDR 音频录制，已自动重新开启（GUI 运行时 KEY3 无效）';
    }
    final rstn = await br.read(kAdRx + 0x40);
    radioReady = (rstn & 3) == 3 && adcActive;
    if (_rp != null) {
      lagMs = ((await br.read(kLr + rWrWords)) - _rp! & 0xFFFFFFFF) * (_iq ? 8 : 16) / 48.0;
    }
    if (_recStart != null) recElapsed = DateTime.now().difference(_recStart!);
    if (kDebugMode && ++_dbgPolls % 8 == 0) {
      debugPrint('STAT mode=${mode.name} f=$freq lag=${lagMs?.toStringAsFixed(0)}ms '
          'lost=$lost audio=${levelDb.toStringAsFixed(1)}dBFS'
          '${_iq ? ' snr=${air.snrDb.toStringAsFixed(1)} open=${air.open}' : ''}');
    }
    notifyListeners();
  }

  // ---------------- tuning ----------------
  Future<void> seek(bool up) async {
    final br = _br;
    if (br == null) return;
    await br.write(kLr + rSeek, seeking ? 3 : (up ? 1 : 2));
  }

  Future<void> step(int hz) async {
    final br = _br;
    if (br == null) return;
    final ddc = s32(await br.read(kLr + rDdc)) + hz;
    if (ddc.abs() <= rangeHz) {
      await br.write(kLr + rDdc, ddc);
    } else {
      info = '已到调谐窗口边界，可直接输入频率以重新设置本振';
      notifyListeners();
    }
  }

  /// Returns false if [hz] lies outside the current LO window (needs retune).
  Future<bool> tune(int hz) async {
    final br = _br;
    if (br == null) return true;
    final ddc = hz - await br.read(kLr + rRfFreq);
    if (ddc.abs() > rangeHz) return false;
    await br.write(kLr + rDdc, ddc);
    return true;
  }

  Future<void> setDeemph(bool us75) async {
    deem75 = us75;
    saveSettings();
    final br = _br;
    if (br == null) return;
    final c = await br.read(kLr + rAudioCfg);
    await br.write(kLr + rAudioCfg, us75 ? c | kDeem75Bit : c & ~kDeem75Bit);
  }

  Future<void> setLock(bool on) async {
    final br = _br;
    if (br == null) return;
    final c = (await br.read(kLr + rControl)) & ~4;
    await br.write(kLr + rControl, on ? c | 2 : c & ~2);
  }

  Future<void> clearErrors() async {
    final br = _br;
    if (br == null) return;
    await br.write(kLr + rControl, ((await br.read(kLr + rControl)) & ~4) | 4);
  }

  Future<void> setSensitivity(String name) async {
    sensitivity = name;
    saveSettings();
    final br = _br;
    if (br == null) return;
    final t = await br.read(kLr + rThr);
    await br.write(kLr + rThr, (t & 0xFFFF0000) | kSensitivity[name]!);
  }

  void setVolume(double v) {
    volume = v;
    notifyListeners();
  }

  void setMuted(bool m) {
    muted = m;
    notifyListeners();
  }

  // ---------------- scan ----------------
  Future<void> scan() async {
    final br = _br;
    if (br == null || _scanning) return;
    _scanning = true;
    scanProgress = 0;
    notifyListeners();
    try {
      final lo0 = await br.read(kLr + rRfFreq);
      final thr = ((await br.read(kLr + rThr)) & 0xFFFF) / 256.0;
      final ddc0 = await br.read(kLr + rDdc);
      final grid = <int>[];
      for (var f = ((lo0 - rangeHz) / 100000).ceil() * 100000;
          f <= lo0 + rangeHz;
          f += 100000) {
        grid.add(f);
      }
      final rows = <List<num>>[];
      for (var i = 0; i < grid.length; i++) {
        await br.write(kLr + rDdc, grid[i] - lo0);
        await Future.delayed(const Duration(milliseconds: 10));
        for (var k = 0; k < 2; k++) {
          final c = (await br.read(kLr + rQual)) >> 24;
          final t0 = DateTime.now();
          while (((await br.read(kLr + rQual)) >> 24) == c) {
            if (DateTime.now().difference(t0).inMilliseconds > 200) break;
          }
        }
        final q = await br.read(kLr + rQual);
        rows.add([grid[i], await br.read(kLr + rPower), (q & 0xFFFF) / 256.0]);
        scanProgress = (i + 1) / grid.length;
        if (i % 4 == 0) notifyListeners();
      }
      await br.write(kLr + rDdc, ddc0);
      final powers = rows.map((r) => r[1]).toList()..sort();
      final med = math.max(powers[powers.length ~/ 2].toDouble(), 1.0);
      final pw = {for (final r in rows) r[0]: r[1]};
      final found = <Station>[];
      for (final r in rows) {
        final f = r[0] as int, p = r[1], fl = r[2] as double;
        final peak = p >= (pw[f - 100000] ?? 0) && p >= (pw[f + 100000] ?? 0);
        if (peak && fl <= math.max(thr, 1.45)) {
          found.add(Station(f, 10 * math.log(math.max(p, 1) / med) / math.ln10,
              fl <= thr));
        }
      }
      stations = found;
      saveSettings();
      final n = found.where((s) => s.isStation).length;
      info = '扫描完成：$n 个电台，${found.length - n} 个弱台';
    } catch (e) {
      _error('扫描失败：$e');
    } finally {
      _scanning = false;
      scanProgress = null;
      notifyListeners();
    }
  }

  // ---------------- airband ----------------
  /// Tunes the airband channel [hz] (DDC only, the LO stays at kAirLo).
  Future<void> airTune(int hz) async {
    final br = _br;
    if (br == null || mode != RadioMode.air) return;
    hz = hz.clamp(kAirMin, kAirMax);
    airFreq = hz;
    await br.write(kLr + rDdc, hz - lo);
    freq = hz;
    _tuneGen++;
    _skipTo = ((await br.read(kLr + rWrWords)) + kAirSettleWords) & 0xFFFFFFFF;
    notifyListeners();
  }

  Future<void> airStepBy(int dir) =>
      airTune(airSnap(airFreq + dir * (airStep == 8333 ? 8334 : airStep), airStep));

  void setAirBw(String name) {
    airBw = name;
    air.bwHz = kAirBw[name]!;
    saveSettings();
    notifyListeners();
  }

  void setAirSquelch(double db) {
    airSquelch = db;
    air.squelchDb = db;
    notifyListeners();
  }

  void setAirStep(int step) {
    airStep = step;
    saveSettings();
    notifyListeners();
  }

  void setAirRecIq(bool on) {
    airRecIq = on;
    saveSettings();
    notifyListeners();
  }

  void addAirChannel(int hz, String name) {
    airChannels.removeWhere((c) => c.freq == hz);
    airChannels.add(AirChannel(hz, name));
    airChannels.sort((a, b) => a.freq.compareTo(b.freq));
    saveSettings();
    notifyListeners();
  }

  void removeAirChannel(AirChannel c) {
    airChannels.remove(c);
    saveSettings();
    notifyListeners();
  }

  void toggleAirScan() => airScanning ? stopAirScan() : startAirScan();

  void startAirScan() {
    if (airChannels.isEmpty) {
      info = '频道列表为空：先把要监听的频率加入列表';
      notifyListeners();
      return;
    }
    airScanning = true;
    scanIndex = -1;
    _scanPhase = 'next';
    notifyListeners();
  }

  void stopAirScan() {
    if (!airScanning) return;
    airScanning = false;
    _scanPhase = '';
    notifyListeners();
  }

  /// Channel scanner: hop -> measure one squelch decision (~45 ms after the
  /// settle time) -> stop on activity, resume 3 s after the channel is quiet.
  Future<void> _airScanStep() async {
    final now = DateTime.now();
    switch (_scanPhase) {
      case 'next':
        if (airChannels.isEmpty) return stopAirScan();
        scanIndex = (scanIndex + 1) % airChannels.length;
        await airTune(airChannels[scanIndex].freq);
        _scanPhase = 'measure';
        _scanT0 = now;
      case 'measure':
        if (_appliedGen == _tuneGen && air.decisions >= 1) {
          if (air.open) {
            _scanPhase = 'listen';
            _quietSince = null;
            notifyListeners();
          } else {
            _scanPhase = 'next';
          }
        } else if (now.difference(_scanT0).inMilliseconds > 600) {
          _scanPhase = 'next'; // no data (should not happen): move on
        }
      case 'listen':
        if (air.open) {
          _quietSince = null;
        } else {
          _quietSince ??= now;
          if (now.difference(_quietSince!).inMilliseconds > 3000) _scanPhase = 'next';
        }
    }
  }

  void toggleFavorite() {
    final f = (freq / 100000).round() * 100000;
    favorites.contains(f) ? favorites.remove(f) : favorites.add(f);
    saveSettings();
    notifyListeners();
  }

  // ---------------- recording (PC side WAV) ----------------
  Future<void> startRecording() async {
    if (_rec != null) return;
    await Directory(recordDir).create(recursive: true);
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final name = mode == RadioMode.air
        ? 'AIR_${(freq / 1e6).toStringAsFixed(3)}MHz_$stamp'
        : 'FM_${(freq / 1e6).toStringAsFixed(1)}MHz_$stamp';
    _recPath = '$recordDir\\$name.wav';
    _rec = await File(_recPath!).open(mode: FileMode.write);
    await _rec!.writeFrom(_wavHeader(0));
    _recBytes = 0;
    if (mode == RadioMode.air && airRecIq) {
      // raw 48 kS/s IQ as a stereo WAV (left = I, right = Q)
      _recIq = await File('$recordDir\\${name}_IQ.wav').open(mode: FileMode.write);
      await _recIq!.writeFrom(_wavHeader(0, channels: 2));
      _recIqBytes = 0;
    }
    _recStart = t;
    recElapsed = Duration.zero;
    notifyListeners();
  }

  Future<void> stopRecording() async {
    final f = _rec;
    if (f == null) return;
    _rec = null;
    await f.setPosition(0);
    await f.writeFrom(_wavHeader(_recBytes));
    await f.close();
    final fq = _recIq;
    if (fq != null) {
      _recIq = null;
      await fq.setPosition(0);
      await fq.writeFrom(_wavHeader(_recIqBytes, channels: 2));
      await fq.close();
    }
    _recStart = null;
    recElapsed = null;
    info = '录音已保存：$_recPath';
    notifyListeners();
  }

  static Uint8List _wavHeader(int dataBytes, {int channels = 1}) {
    final b = ByteData(44);
    void str(int o, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, 48000, Endian.little);
    b.setUint32(28, 96000 * channels, Endian.little);
    b.setUint16(32, 2 * channels, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }

  // ---------------- bring-up helpers ----------------
  Future<void> startBridge() async {
    final tcl = resource('lr_jtag_bridge.tcl');
    if (!File(vivadoBat).existsSync()) {
      _error('找不到 Vivado：$vivadoBat\n请在“设置”中指定 vivado.bat 的位置。');
      return;
    }
    if (tcl == null) {
      _error('找不到 lr_jtag_bridge.tcl（安装目录 resources 下）');
      return;
    }
    busy = '正在启动 JTAG 桥（Vivado，约 30 秒）…';
    notifyListeners();
    final env = Map<String, String>.from(Platform.environment)
      ..['PROCESSOR_ARCHITECTURE'] = 'AMD64';
    final logDir = Directory(_appDataDir)..createSync(recursive: true);
    _bridgeProc = await Process.start(
        vivadoBat,
        ['-mode', 'batch', '-nojournal', '-nolog', '-source', tcl,
         '-tclargs', '$port'],
        runInShell: true,
        environment: env,
        workingDirectory: logDir.path);
    final log = File('${logDir.path}\\bridge.log').openWrite();
    _bridgeProc!.stdout.pipe(log);
    _bridgeProc!.stderr.drain<void>();
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0).inSeconds < 120) {
      try {
        final s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(seconds: 1));
        s.destroy();
        busy = '';
        notifyListeners();
        return;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    busy = '';
    notifyListeners();
    _error('JTAG 桥启动失败，详见 ${logDir.path}\\bridge.log');
  }

  /// Runs the AD9361 init tool; returns null on success, else an error text.
  Future<String?> _runInit({int? loHz, int? tuneHz}) async {
    final exe = resource('ad9361_jtag.exe');
    if (exe == null) return '找不到 ad9361_jtag.exe（安装目录 resources 下）';
    final lo0 = loHz ?? (lo >= 70000000 ? lo : 97950000);
    final args = ['--port', '$port', '--lo-hz', '$lo0',
      '--tune-hz', '${tuneHz ?? lo0 + 50000}'];
    if (deem75) args.addAll(['--deemph', '75']);
    final r = await Process.run(exe, args);
    _rp = null;
    final out = '${r.stdout}${r.stderr}';
    if (r.exitCode != 0 || !out.contains('AD9361_BRINGUP_OK')) {
      final tail = out.trim().split('\n');
      return tail.sublist(math.max(0, tail.length - 6)).join('\n');
    }
    return null;
  }

  /// Initialises the AD9361 (ADI no-OS driver over JTAG, ~20 s).
  Future<void> initRadio({int? loHz, int? tuneHz}) async {
    busy = '正在初始化射频 AD9361（约 20 秒）…';
    notifyListeners();
    final why = await _runInit(loHz: loHz, tuneHz: tuneHz);
    busy = '';
    if (why != null) {
      _error('射频初始化失败：\n$why');
    } else {
      info = '射频已初始化：本振 ${((loHz ?? lo) / 1e6).toStringAsFixed(3)} MHz';
    }
    notifyListeners();
  }

  /// Moves the LO so that [hz] becomes tunable (station 50 kHz above LO).
  Future<void> retune(int hz) => initRadio(loHz: hz - 50000, tuneHz: hz);
}
