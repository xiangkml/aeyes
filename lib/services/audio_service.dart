import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:record/record.dart';

class AudioService {
  static const int sendSampleRate = 16000;
  static const int receiveSampleRate = 24000;
  static const int numChannels = 1;
  static const double userSpeechThresholdDb = -12.0;
  static const double minInputVolumeDb = -35.0;

  /// Computes the RMS volume of a PCM16 audio chunk in decibels.
  /// Returns negative infinity for silent/empty data.
  static double calculateVolumeDb(Uint8List pcmData) {
    if (pcmData.length < 2) return double.negativeInfinity;
    final samples = pcmData.buffer.asInt16List(
      pcmData.offsetInBytes,
      pcmData.lengthInBytes ~/ 2,
    );
    double sumSquares = 0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    if (rms < 1) return double.negativeInfinity;
    // Normalize against Int16 max (32767) and convert to dB.
    return 20 * math.log(rms / 32767) / math.ln10;
  }

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
  DateTime? _lastFeedTime;

  String? get lastPlaybackError => _lastPlaybackError;

  /// True when there are audio chunks queued or being fed to the player.
  bool get hasPendingPlayback => _pendingPlayback.isNotEmpty || _isFeeding;

  /// The time the last audio chunk was written to the player sink.
  DateTime? get lastFeedTime => _lastFeedTime;

  Future<double?> getCurrentAmplitudeDb() async {
    if (!_isRecording) {
      return null;
    }
    try {
      final amplitude = await _recorder.getAmplitude();
      return amplitude.current;
    } catch (error) {
      _lastPlaybackError = 'Amplitude read failed: $error';
      return null;
    }
  }

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
    _lastFeedTime = null;
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
        _lastFeedTime = DateTime.now();
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
