import 'dart:async';
import 'dart:typed_data';

import 'package:aeyes/services/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlaybackSink implements AudioPlaybackSink {
  final controller = StreamController<void>.broadcast();
  final played = <Uint8List>[];
  int stopCalls = 0;

  @override
  Stream<void> get onComplete => controller.stream;

  @override
  Future<void> configure() async {}

  @override
  Future<void> dispose() async {
    await controller.close();
  }

  @override
  Future<void> play(Uint8List audioBytes) async {
    played.add(audioBytes);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _FakeRecordSource implements AudioRecordSource {
  @override
  Future<void> dispose() async {}

  @override
  Future<Stream<Uint8List>> startStream() async {
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('flushes early when the buffer threshold is reached', () async {
    final sink = _FakePlaybackSink();
    final service = AudioService(
      playbackSink: sink,
      recordSource: _FakeRecordSource(),
    );

    service.addAudioChunk(Uint8List(12000));
    await Future<void>.delayed(Duration.zero);

    expect(sink.played, hasLength(1));
    await service.dispose();
  });

  test('flushes remaining audio on turn complete', () async {
    final sink = _FakePlaybackSink();
    final service = AudioService(
      playbackSink: sink,
      recordSource: _FakeRecordSource(),
    );

    service.addAudioChunk(Uint8List(2048));
    await Future<void>.delayed(Duration.zero);
    expect(sink.played, isEmpty);

    service.onTurnComplete();
    await Future<void>.delayed(Duration.zero);

    expect(sink.played, hasLength(1));
    await service.dispose();
  });

  test('delayed flush plays partial audio quickly', () async {
    final sink = _FakePlaybackSink();
    final service = AudioService(
      playbackSink: sink,
      recordSource: _FakeRecordSource(),
    );

    service.addAudioChunk(Uint8List(2048));
    expect(sink.played, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(sink.played, hasLength(1));
    await service.dispose();
  });

  test('clearPlayback stops output and discards pending audio', () async {
    final sink = _FakePlaybackSink();
    final service = AudioService(
      playbackSink: sink,
      recordSource: _FakeRecordSource(),
    );

    service.addAudioChunk(Uint8List(12000));
    await Future<void>.delayed(Duration.zero);
    expect(service.hasPendingPlayback, isTrue);

    service.clearPlayback();
    await Future<void>.delayed(Duration.zero);

    expect(sink.stopCalls, 1);
    expect(service.hasPendingPlayback, isFalse);
    await service.dispose();
  });
}
