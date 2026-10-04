// Lightning Receiver - streaming 16-bit mono PCM playback via Windows waveOut
// (winmm.dll through dart:ffi, no third-party audio dependency).
//
// A ring of [_nbuf] native buffers of [_bufSamples] samples each is kept in
// flight; [push] appends PCM to a staging queue and [pump] hands every full
// chunk to a buffer the driver has finished with (WHDR_DONE).
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class WAVEFORMATEX extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class WAVEHDR extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<WAVEHDR> lpNext;
  @IntPtr()
  external int reserved;
}

typedef _OpenC = Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<WAVEFORMATEX>,
    IntPtr, IntPtr, Uint32);
typedef _OpenD = int Function(
    Pointer<IntPtr>, int, Pointer<WAVEFORMATEX>, int, int, int);
typedef _HdrC = Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32);
typedef _HdrD = int Function(int, Pointer<WAVEHDR>, int);
typedef _HC = Uint32 Function(IntPtr);
typedef _HD = int Function(int);

class WaveOut {
  WaveOut({this.sampleRate = 48000});

  final int sampleRate;
  static const int _nbuf = 8;
  static const int _bufSamples = 2400; // 50 ms per buffer, 400 ms in flight
  static const int _waveMapper = 0xFFFFFFFF;
  static const int _whdrDone = 0x1;

  static final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');
  static final _open = _winmm.lookupFunction<_OpenC, _OpenD>('waveOutOpen');
  static final _prepare =
      _winmm.lookupFunction<_HdrC, _HdrD>('waveOutPrepareHeader');
  static final _unprepare =
      _winmm.lookupFunction<_HdrC, _HdrD>('waveOutUnprepareHeader');
  static final _write = _winmm.lookupFunction<_HdrC, _HdrD>('waveOutWrite');
  static final _reset = _winmm.lookupFunction<_HC, _HD>('waveOutReset');
  static final _close = _winmm.lookupFunction<_HC, _HD>('waveOutClose');

  int _hwo = 0;
  final List<Pointer<WAVEHDR>> _hdrs = [];
  final List<bool> _queued = [];
  final BytesBuilder _staging = BytesBuilder(copy: true);
  bool get isOpen => _hwo != 0;

  /// Opens the default output device; returns false if none is available.
  bool open() {
    if (_hwo != 0) return true;
    final fmt = calloc<WAVEFORMATEX>();
    final ph = calloc<IntPtr>();
    try {
      fmt.ref
        ..wFormatTag = 1 // WAVE_FORMAT_PCM
        ..nChannels = 1
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16
        ..nBlockAlign = 2
        ..nAvgBytesPerSec = sampleRate * 2
        ..cbSize = 0;
      final rc = _open(ph, _waveMapper, fmt, 0, 0, 0); // CALLBACK_NULL
      if (rc != 0) return false;
      _hwo = ph.value;
    } finally {
      calloc.free(fmt);
      calloc.free(ph);
    }
    for (var i = 0; i < _nbuf; i++) {
      final h = calloc<WAVEHDR>();
      h.ref
        ..lpData = calloc<Uint8>(_bufSamples * 2)
        ..dwBufferLength = _bufSamples * 2;
      _prepare(_hwo, h, sizeOf<WAVEHDR>());
      _hdrs.add(h);
      _queued.add(false);
    }
    return true;
  }

  /// Number of PCM bytes waiting in the staging queue.
  int get staged => _staging.length;

  /// Number of driver buffers currently queued (playing or waiting).
  int get inFlight {
    var n = 0;
    for (var i = 0; i < _hdrs.length; i++) {
      if (_queued[i] && (_hdrs[i].ref.dwFlags & _whdrDone) == 0) n++;
    }
    return n;
  }

  void push(Uint8List pcm) {
    if (_hwo == 0) return;
    // Bound the latency: never keep more than ~0.5 s staged.
    if (_staging.length > sampleRate) {
      _staging.clear();
    }
    _staging.add(pcm);
    pump();
  }

  /// Moves complete chunks from the staging queue into free driver buffers.
  void pump() {
    if (_hwo == 0) return;
    const chunk = _bufSamples * 2;
    while (_staging.length >= chunk) {
      final i = _freeIndex();
      if (i < 0) return;
      final all = _staging.takeBytes();
      final h = _hdrs[i];
      h.ref.lpData.asTypedList(chunk).setAll(0, all.sublist(0, chunk));
      if (all.length > chunk) _staging.add(all.sublist(chunk));
      h.ref.dwFlags &= ~_whdrDone;
      _write(_hwo, h, sizeOf<WAVEHDR>());
      _queued[i] = true;
    }
  }

  int _freeIndex() {
    for (var i = 0; i < _hdrs.length; i++) {
      if (!_queued[i] || (_hdrs[i].ref.dwFlags & _whdrDone) != 0) return i;
    }
    return -1;
  }

  void close() {
    if (_hwo == 0) return;
    _reset(_hwo);
    for (final h in _hdrs) {
      _unprepare(_hwo, h, sizeOf<WAVEHDR>());
      calloc.free(h.ref.lpData);
      calloc.free(h);
    }
    _hdrs.clear();
    _queued.clear();
    _close(_hwo);
    _hwo = 0;
    _staging.clear();
  }
}
