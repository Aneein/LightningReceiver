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
      _socket.write('$c\n');
      try {
        final r = await reply.future.timeout(const Duration(seconds: 30));
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

  static String _hex(int v, [int w = 8]) =>
      (v & 0xFFFFFFFF).toRadixString(16).padLeft(w, '0').toUpperCase();

  Future<int> read(int addr) async =>
      int.parse((await cmd('R ${_hex(addr)}')).trim(), radix: 16);

  Future<void> write(int addr, int value) =>
      cmd('W ${_hex(addr)} ${_hex(value)}');

  /// Reads [nwords] 32-byte ring words starting at [addr] as raw bytes.
  /// Bursts are <= 256 x 32-bit and never cross a 1 KiB boundary.
  Future<Uint8List> readRingWords(int addr, int nwords) async {
    final out = BytesBuilder(copy: false);
    var a = addr;
    final end = addr + nwords * 32;
    while (a < end) {
      final ce = ((a ~/ 1024) + 1) * 1024 < end ? ((a ~/ 1024) + 1) * 1024 : end;
      final n = (ce - a) ~/ 4;
      final words = (await cmd('B ${_hex(a)} $n')).trim().split(' ');
      final bd = ByteData(words.length * 4);
      for (var i = 0; i < words.length; i++) {
        bd.setUint32(i * 4, int.parse(words[i], radix: 16), Endian.little);
      }
      out.add(bd.buffer.asUint8List());
      a = ce;
    }
    return out.takeBytes();
  }

  Future<void> close() async {
    if (closed) return;
    try {
      _socket.write('Q\n');
      await _socket.flush();
    } catch (_) {}
    closed = true;
    await _lines.cancel();
    _socket.destroy();
  }
}
