import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

abstract class AudioRecordSource {
  Future<Stream<Uint8List>> startStream();
  Future<void> stop();
  Future<void> dispose();
}

class RecordAudioSource implements AudioRecordSource {
  RecordAudioSource() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<Stream<Uint8List>> startStream() {
    return _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AudioService.sendSampleRate,
        numChannels: AudioService.numChannels,
      ),
    );
  }

  @override
  Future<void> stop() {
    return _recorder.stop();
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
  }
}

abstract class AudioPlaybackSink {
  Stream<void> get onComplete;

  Future<void> configure();
  Future<void> play(Uint8List audioBytes);
  Future<void> stop();
  Future<void> dispose();
}

class AudioPlayersPlaybackSink implements AudioPlaybackSink {
  AudioPlayersPlaybackSink() : _player = AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> configure() async {
    await _player.setReleaseMode(ReleaseMode.stop);
    try {
      await _player.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {
      await _player.setPlayerMode(PlayerMode.mediaPlayer);
    }
  }

  @override
  Future<void> play(Uint8List audioBytes) {
    return _player.play(BytesSource(audioBytes));
  }

  @override
  Future<void> stop() {
    return _player.stop();
  }

  @override
  Future<void> dispose() {
    return _player.dispose();
  }
}

class AudioService {
  AudioService({
    AudioRecordSource? recordSource,
    AudioPlaybackSink? playbackSink,
  })  : _recordSource = recordSource ?? RecordAudioSource(),
        _playbackSink = playbackSink ?? AudioPlayersPlaybackSink() {
    unawaited(_playbackSink.configure());
    _playerCompleteSub = _playbackSink.onComplete.listen((_) {
      _finishPlayback();
    });
  }

  static const int sendSampleRate = 16000;
  static const int receiveSampleRate = 24000;
  static const int numChannels = 1;
  static const int bitsPerSample = 16;

  static const int _bufferThreshold = 12000;
  static const Duration _flushDelay = Duration(milliseconds: 80);
  static const Duration _playbackSlack = Duration(milliseconds: 40);

  final AudioRecordSource _recordSource;
  final AudioPlaybackSink _playbackSink;

  StreamSubscription? _recordingSub;
  StreamSubscription? _playerCompleteSub;

  final List<int> _pendingPcm = [];
  final Queue<Uint8List> _playQueue = Queue();
  bool _isRecording = false;
  bool _isPlaying = false;
  Timer? _flushTimer;
  Timer? _playbackWatchdog;

  bool get hasPendingPlayback =>
      _isPlaying || _playQueue.isNotEmpty || _pendingPcm.isNotEmpty;

  Future<void> startRecording(void Function(Uint8List data) onData) async {
    if (_isRecording) {
      return;
    }

    final stream = await _recordSource.startStream();

    _isRecording = true;
    _recordingSub = stream.listen(onData);
  }

  Future<void> stopRecording() async {
    if (!_isRecording) {
      return;
    }
    _isRecording = false;
    await _recordingSub?.cancel();
    _recordingSub = null;
    await _recordSource.stop();
  }

  void addAudioChunk(Uint8List chunk) {
    _pendingPcm.addAll(chunk);

    if (_pendingPcm.length >= _bufferThreshold) {
      _flush();
      return;
    }

    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, _flush);
  }

  void onTurnComplete() {
    _flush();
  }

  void clearPlayback() {
    _flushTimer?.cancel();
    _playbackWatchdog?.cancel();
    _pendingPcm.clear();
    _playQueue.clear();
    unawaited(_playbackSink.stop());
    _isPlaying = false;
  }

  void _flush() {
    _flushTimer?.cancel();
    if (_pendingPcm.isEmpty) {
      return;
    }

    final pcm = Uint8List.fromList(_pendingPcm);
    _pendingPcm.clear();

    final wav = _pcmToWav(pcm, receiveSampleRate, numChannels, bitsPerSample);
    _playQueue.add(wav);
    _playNext();
  }

  void _playNext() {
    if (_isPlaying || _playQueue.isEmpty) {
      return;
    }

    _isPlaying = true;
    final wav = _playQueue.removeFirst();
    final duration = _estimatePlaybackDuration(wav);
    _playbackWatchdog?.cancel();
    _playbackWatchdog = Timer(duration + _playbackSlack, _finishPlayback);
    unawaited(_playbackSink.play(wav));
  }

  void _finishPlayback() {
    if (!_isPlaying) {
      return;
    }

    _playbackWatchdog?.cancel();
    _isPlaying = false;
    _playNext();
  }

  Duration _estimatePlaybackDuration(Uint8List wav) {
    final pcmBytes = wav.length > 44 ? wav.length - 44 : wav.length;
    final bytesPerSecond = receiveSampleRate * numChannels * (bitsPerSample ~/ 8);
    final milliseconds = (pcmBytes * 1000 / bytesPerSecond).ceil();
    return Duration(milliseconds: milliseconds);
  }

  static Uint8List _pcmToWav(
    Uint8List pcm,
    int sampleRate,
    int channels,
    int bits,
  ) {
    final bytesPerSample = bits ~/ 8;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;
    final dataSize = pcm.length;

    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big);
    header.setUint32(12, 0x666D7420, Endian.big);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bits, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big);
    header.setUint32(40, dataSize, Endian.little);

    final wav = Uint8List(44 + dataSize);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + dataSize, pcm);
    return wav;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _playbackWatchdog?.cancel();
    await stopRecording();
    await _playerCompleteSub?.cancel();
    await _playbackSink.dispose();
    await _recordSource.dispose();
  }
}
