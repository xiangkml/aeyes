import 'package:aeyes/services/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio service exposes expected sample rates', () {
    expect(AudioService.sendSampleRate, 16000);
    expect(AudioService.receiveSampleRate, 24000);
    expect(AudioService.numChannels, 1);
  });
}
