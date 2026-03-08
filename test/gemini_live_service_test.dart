import 'package:aeyes/services/gemini_live_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service exposes startup prompt', () {
    final service = GeminiLiveService();

    expect(service.startupPrompt, contains('help them find objects'));
  });

  test('service starts disconnected', () {
    final service = GeminiLiveService();

    expect(service.isReady, isFalse);
    expect(service.lastCloseCode, isNull);
    expect(service.lastCloseReason, isNull);
  });
}
