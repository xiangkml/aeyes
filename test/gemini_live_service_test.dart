import 'dart:convert';
import 'dart:typed_data';

import 'package:aeyes/services/gemini_live_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildSetupPayload uses audio only with output transcription', () {
    final service = GeminiLiveService();
    final payload = service.buildSetupPayload();
    final setup = payload['setup'] as Map<String, dynamic>;
    final generationConfig =
        setup['generationConfig'] as Map<String, dynamic>;

    expect(generationConfig['responseModalities'], ['AUDIO']);
    expect(setup['outputAudioTranscription'], equals(<String, dynamic>{}));
    expect(payloadAsJson(payload), isNot(contains('"TEXT"')));
  });

  test('parses setup complete events', () {
    final event = GeminiServerEvent.tryParse(
      jsonEncode({'setupComplete': {}}),
    );

    expect(event, isNotNull);
    expect(event!.setupComplete, isTrue);
    expect(event.turnComplete, isFalse);
  });

  test('parses output transcription and audio chunks', () {
    final audioChunk = Uint8List.fromList([1, 2, 3, 4]);
    final event = GeminiServerEvent.tryParse(
      jsonEncode({
        'outputTranscription': {'text': 'The door is open.'},
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {
                  'mimeType': 'audio/pcm',
                  'data': base64Encode(audioChunk),
                }
              },
            ],
          },
        },
      }),
    );

    expect(event, isNotNull);
    expect(event!.outputTranscripts, ['The door is open.']);
    expect(event.audioChunks, hasLength(1));
    expect(event.audioChunks.single, audioChunk);
  });

  test('parses input transcription events separately', () {
    final event = GeminiServerEvent.tryParse(
      jsonEncode({
        'inputTranscription': {'text': 'What is in front of me?'},
      }),
    );

    expect(event, isNotNull);
    expect(event!.inputTranscripts, ['What is in front of me?']);
    expect(event.outputTranscripts, isEmpty);
  });

  test('parses turn complete messages', () {
    final event = GeminiServerEvent.tryParse(
      jsonEncode({
        'serverContent': {'turnComplete': true}
      }),
    );

    expect(event, isNotNull);
    expect(event!.turnComplete, isTrue);
  });

  test('setup exception includes close code and reason', () {
    final exception = GeminiSetupException(
      'Gemini setup rejected before setupComplete '
      '(code=1007, reason=Request contains an invalid argument.)',
    );

    expect(
      exception.toString(),
      contains('code=1007'),
    );
    expect(
      exception.toString(),
      contains('invalid argument'),
    );
  });
}

String payloadAsJson(Map<String, dynamic> payload) => jsonEncode(payload);
