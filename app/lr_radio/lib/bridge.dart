// Lightning Receiver - JTAG-AXI bridge client.
//
// Line protocol of tools/hw/lr_jtag_bridge.tcl (127.0.0.1:5555):
//   R <addr>        -> OK <data>
//   W <addr> <data> -> OK
//   B <addr> <n>    -> OK <w0> ... <wn-1>   (burst read, n = 1..256)
//   S <tx24>        -> OK <rx24>            (AD9361 SPI)
// Commands are strictly serialised: each request waits for its reply.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Bridge {
  Bridge._(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _lines = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
  }

  static Future<Bridge> connect({int port = 5555}) async {
    final s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 3));
    return Bridge._(s);
  }

  final Socket _socket;
  late final StreamSubscription<String> _lines;
  final _pending = <Completer<String>>[];
  Future<void> _tail = Future.value();
  bool closed = false;

  void _onLine(String line) {
    if (_pending.isEmpty) return;
    _pending.removeAt(0).complete(line.trim());
  }

  void _onDone() {
    closed = true;
    for (final c in _pending) {
      if (!c.isCompleted) c.completeError(BridgeException('JTAG 桥连接已断开'));
    }
    _pending.clear();
  }

  /// Sends one command and returns the reply payload (after "OK").
  Future<String> cmd(String c) {
    final result = Completer<String>();
    _tail = _tail.then((_) async {
      if (closed) {
        result.completeError(BridgeException('JTAG 桥连接已断开'));
        return;
      }
      final reply = Completer<String>();
      _pending.add(reply);
      try {
        _socket.write('$c\n');
        final r = await reply.future.timeout(const Duration(seconds: 30),
            onTimeout: () => throw BridgeException('$c：30 秒无应答'));
        if (r.startsWith('OK')) {
          result.complete(r.length > 3 ? r.substring(3) : '');
        } else {
          result.completeError(BridgeException('$c -> $r'));
        }
      } catch (e) {
        if (!result.isCompleted) result.completeError(e);
      }
    });
    return result.future;
  }

  /// Sends several commands back to back (one TCP write, replies in order):
  /// hides the per-command round trip for bulk ring reads.
  Future<List<String>> cmds(List<String> cs) {
    final result = Completer<List<String>>();
    _tail = _tail.then((_) async {
      if (closed) {
        result.completeError(BridgeException('JTAG 桥连接已断开'));
        return;
      }
      final replies = [for (final _ in cs) Completer<String>()];
      _pending.addAll(replies);
      try {
        _socket.write(cs.map((c) => '$c\n').join());
        final out = <String>[];
        for (var i = 0; i < cs.length; i++) {
          final r = await replies[i].future.timeout(const Duration(seconds: 30),
              onTimeout: () => throw BridgeException('${cs[i]}：30 秒无应答（批量 ${cs.length}）'));
          if (!r.startsWith('OK')) throw BridgeException('${cs[i]} -> $r');
          out.add(r.length > 3 ? r.substring(3) : '');
        }
        result.complete(out);
      } catch (e) {
        if (!result.isCompleted) result.completeError(e);
      }
    });
    return result.future;
  }

  static String _hex(int v, [int w = 8]) =>
      (v & 0xFFFFFFFF).toRadixString(16).padLeft(w, '0').toUpperCase();

  Future<int> read(int addr) async =>
      int.parse((await cmd('R ${_hex(addr)}')).trim(), radix: 16);

  Future<void> write(int addr, int value) =>
      cmd('W ${_hex(addr)} ${_hex(value)}');

  /// Reads [nwords] 32-byte ring words starting at [addr] as raw bytes.
  /// Bursts are <= 256 x 32-bit and never cross a 1 KiB boundary.
  /// Bursts are sent pipelined in groups of [kPipeline].
  static const int kPipeline = 16;

  Future<Uint8List> readRingWords(int addr, int nwords) async {
    final cs = <String>[];
    var a = addr;
    final end = addr + nwords * 32;
    while (a < end) {
      final ce = ((a ~/ 1024) + 1) * 1024 < end ? ((a ~/ 1024) + 1) * 1024 : end;
      cs.add('B ${_hex(a)} ${(ce - a) ~/ 4}');
      a = ce;
    }
    final bd = ByteData(nwords * 32);
    var o = 0;
    for (var g = 0; g < cs.length; g += kPipeline) {
      final replies = await cmds(cs.sublist(g, g + kPipeline < cs.length ? g + kPipeline : cs.length));
      for (final r in replies) {
        for (final w in r.trim().split(' ')) {
          bd.setUint32(o, int.parse(w, radix: 16), Endian.little);
          o += 4;
        }
      }
    }
    return bd.buffer.asUint8List();
  }

  Future<void> close() async {
    if (closed) return;
    // mark closed first: commands queued behind us fail fast instead of
    // writing into the flushing sink ("StreamSink is bound to a stream")
    closed = true;
    try {
      _socket.write('Q\n');
      await _socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await _lines.cancel();
    _socket.destroy();
    for (final c in _pending) {
      if (!c.isCompleted) c.completeError(BridgeException('JTAG 桥连接已关闭'));
    }
    _pending.clear();
  }
}
