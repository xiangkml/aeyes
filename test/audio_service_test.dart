import 'dart:typed_data';

import 'package:aeyes/services/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio service exposes expected sample rates', () {
    expect(AudioService.sendSampleRate, 16000);
    expect(AudioService.receiveSampleRate, 24000);
    expect(AudioService.numChannels, 1);
  });

  group('calculateVolumeDb', () {
    test('returns negative infinity for empty data', () {
      expect(AudioService.calculateVolumeDb(Uint8List(0)),
          double.negativeInfinity);
    });

    test('returns negative infinity for silence (all zeros)', () {
      // 10 silent PCM16 samples = 20 bytes
      final silent = Uint8List(20);
      expect(AudioService.calculateVolumeDb(silent),
          double.negativeInfinity);
    });

    test('returns 0 dB for maximum amplitude signal', () {
      // All samples at Int16 max (32767)
      final samples = Int16List(100);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 32767;
      }
      final bytes = Uint8List.view(samples.buffer);
      final db = AudioService.calculateVolumeDb(bytes);
      expect(db, closeTo(0.0, 0.01));
    });

    test('quiet audio is below minInputVolumeDb', () {
      // Very low amplitude samples
      final samples = Int16List(100);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 10;
      }
      final bytes = Uint8List.view(samples.buffer);
      final db = AudioService.calculateVolumeDb(bytes);
      expect(db, lessThan(AudioService.minInputVolumeDb));
    });

    test('moderate audio is above minInputVolumeDb', () {
      // Moderate amplitude samples (~10% of max)
      final samples = Int16List(100);
      for (int i = 0; i < samples.length; i++) {
        samples[i] = 3000;
      }
      final bytes = Uint8List.view(samples.buffer);
      final db = AudioService.calculateVolumeDb(bytes);
      expect(db, greaterThan(AudioService.minInputVolumeDb));
    });
  });
}
