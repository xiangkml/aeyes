import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:record/record.dart';

class AudioService {
  static const int sendSampleRate = 16000;
  static const int receiveSampleRate = 24000;
  static const int numChannels = 1;

  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamSubscription? _recordingSub;
  StreamSubscription? _playerProgressSub;

  final Queue<Uint8List> _pendingPlayback = Queue();
  bool _isRecording = false;
  bool _playerReady = false;
  bool _streamStarted = false;
  bool _isFeeding = false;
  String? _lastPlaybackError;

  String? get lastPlaybackError => _lastPlaybackError;

  AudioService() {
    unawaited(_initPlayer());
  }

  Future<void> _initPlayer() async {
    try {
      await _player.openPlayer();
      await _startPlaybackStream();
      _playerProgressSub = _player.onProgress?.listen((_) {});
      _playerReady = true;
      await _drainPendingPlayback();
    } catch (error) {
      _lastPlaybackError = 'Streaming player init failed: $error';
    }
  }

  Future<void> _startPlaybackStream() async {
    if (_streamStarted) {
      return;
    }

    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: numChannels,
      sampleRate: receiveSampleRate,
      bufferSize: 4096,
    );
    _streamStarted = true;
  }

  Future<void> startRecording(void Function(Uint8List data) onData) async {
    if (_isRecording) {
      return;
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sendSampleRate,
        numChannels: numChannels,
      ),
    );

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
    await _recorder.stop();
  }

  void addAudioChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    _pendingPlayback.add(chunk);
    unawaited(_drainPendingPlayback());
  }

  void onTurnComplete() {
    unawaited(_drainPendingPlayback());
  }

  void clearPlayback() {
    _pendingPlayback.clear();
    unawaited(_resetPlaybackStream());
  }

  Future<void> _resetPlaybackStream() async {
    try {
      if (_streamStarted) {
        await _player.stopPlayer();
        _streamStarted = false;
      }
      if (_playerReady) {
        await _startPlaybackStream();
      }
    } catch (error) {
      _lastPlaybackError = 'Playback reset failed: $error';
    }
  }

  Future<void> _drainPendingPlayback() async {
    if (!_playerReady || !_streamStarted || _isFeeding) {
      return;
    }

    _isFeeding = true;
    try {
      while (_pendingPlayback.isNotEmpty && _streamStarted) {
        final chunk = _pendingPlayback.removeFirst();
        final sink = _player.uint8ListSink;
        if (sink == null) {
          _lastPlaybackError = 'Playback stream sink is unavailable';
          break;
        }
        sink.add(chunk);
      }
      _lastPlaybackError = null;
    } catch (error) {
      _lastPlaybackError = 'Streaming playback failed: $error';
    } finally {
      _isFeeding = false;
    }
  }

  Future<void> dispose() async {
    await stopRecording();
    await _playerProgressSub?.cancel();
    if (_streamStarted) {
      await _player.stopPlayer();
    }
    await _player.closePlayer();
    _recorder.dispose();
  }
}
