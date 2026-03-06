import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

class AudioService {
  static const int sendSampleRate = 16000;
  static const int receiveSampleRate = 24000;
  static const int numChannels = 1;
  static const int bitsPerSample = 16;

  // ~1 second of 24 kHz 16-bit mono audio = 48 000 bytes
  static const int _bufferThreshold = 48000;

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription? _recordingSub;
  StreamSubscription? _playerCompleteSub;

  final List<int> _pendingPcm = [];
  final Queue<Uint8List> _playQueue = Queue();
  bool _isRecording = false;
  bool _isPlaying = false;
  Timer? _flushTimer;

  AudioService() {
    _playerCompleteSub = _player.onPlayerComplete.listen((_) {
      _isPlaying = false;
      _playNext();
    });
  }

  // ── Recording ──────────────────────────────────────────────────────

  Future<void> startRecording(void Function(Uint8List data) onData) async {
    if (_isRecording) return;

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sendSampleRate,
        numChannels: numChannels,
      ),
    );

    _isRecording = true;
    _recordingSub = stream.listen(onData);
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    await _recordingSub?.cancel();
    _recordingSub = null;
    await _recorder.stop();
  }

  // ── Playback ───────────────────────────────────────────────────────

  /// Buffer an incoming PCM audio chunk from the AI response.
  void addAudioChunk(Uint8List chunk) {
    _pendingPcm.addAll(chunk);

    if (_pendingPcm.length >= _bufferThreshold) {
      _flush();
    } else {
      // Flush after a short delay in case no more data arrives.
      _flushTimer?.cancel();
      _flushTimer = Timer(const Duration(milliseconds: 300), _flush);
    }
  }

  /// Called when the AI finishes a response turn — flush remaining audio.
  void onTurnComplete() {
    _flush();
  }

  /// Stop playback and discard pending audio (e.g. on interruption).
  void clearPlayback() {
    _flushTimer?.cancel();
    _pendingPcm.clear();
    _playQueue.clear();
    _player.stop();
    _isPlaying = false;
  }

  void _flush() {
    _flushTimer?.cancel();
    if (_pendingPcm.isEmpty) return;

    final pcm = Uint8List.fromList(_pendingPcm);
    _pendingPcm.clear();

    final wav = _pcmToWav(pcm, receiveSampleRate, numChannels, bitsPerSample);
    _playQueue.add(wav);
    _playNext();
  }

  void _playNext() {
    if (_isPlaying || _playQueue.isEmpty) return;
    _isPlaying = true;
    final wav = _playQueue.removeFirst();
    _player.play(BytesSource(wav));
  }

  // ── WAV helper ─────────────────────────────────────────────────────

  static Uint8List _pcmToWav(
      Uint8List pcm, int sampleRate, int channels, int bits) {
    final bytesPerSample = bits ~/ 8;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;
    final dataSize = pcm.length;

    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big); // 'RIFF'
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big); // 'WAVE'
    header.setUint32(12, 0x666D7420, Endian.big); // 'fmt '
    header.setUint32(16, 16, Endian.little); // sub-chunk size
    header.setUint16(20, 1, Endian.little); // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bits, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big); // 'data'
    header.setUint32(40, dataSize, Endian.little);

    final wav = Uint8List(44 + dataSize);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + dataSize, pcm);
    return wav;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await stopRecording();
    await _playerCompleteSub?.cancel();
    await _player.dispose();
    _recorder.dispose();
  }
}
