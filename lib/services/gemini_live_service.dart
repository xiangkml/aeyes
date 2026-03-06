import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';

enum GeminiConnectionState {
  disconnected,
  connecting,
  ready,
  error,
}

enum GeminiTranscriptType {
  outputAudio,
  inputAudio,
}

class GeminiTranscriptEvent {
  const GeminiTranscriptEvent({
    required this.text,
    required this.type,
  });

  final String text;
  final GeminiTranscriptType type;
}

class GeminiSetupException implements Exception {
  GeminiSetupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GeminiServerEvent {
  const GeminiServerEvent({
    this.setupComplete = false,
    this.turnComplete = false,
    this.audioChunks = const [],
    this.outputTranscripts = const [],
    this.inputTranscripts = const [],
  });

  final bool setupComplete;
  final bool turnComplete;
  final List<Uint8List> audioChunks;
  final List<String> outputTranscripts;
  final List<String> inputTranscripts;

  static GeminiServerEvent? tryParse(dynamic message) {
    String jsonStr;
    if (message is String) {
      jsonStr = message;
    } else if (message is List<int>) {
      jsonStr = utf8.decode(message);
    } else {
      return null;
    }

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static GeminiServerEvent fromJson(Map<String, dynamic> data) {
    if (data.containsKey('setupComplete')) {
      return const GeminiServerEvent(setupComplete: true);
    }

    final serverContent = data['serverContent'] as Map<String, dynamic>?;
    final inputTranscription =
        data['inputTranscription'] as Map<String, dynamic>?;
    final outputTranscription =
        data['outputTranscription'] as Map<String, dynamic>?;

    final inputTexts = <String>[
      if (inputTranscription?['text'] is String)
        inputTranscription!['text'] as String,
    ];
    final outputTexts = <String>[
      if (outputTranscription?['text'] is String)
        outputTranscription!['text'] as String,
    ];

    if (serverContent == null) {
      return GeminiServerEvent(
        inputTranscripts: inputTexts,
        outputTranscripts: outputTexts,
      );
    }

    final turnComplete = serverContent['turnComplete'] == true;
    final audioChunks = <Uint8List>[];

    final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
    final parts = modelTurn?['parts'] as List<dynamic>? ?? const [];
    for (final part in parts) {
      if (part is! Map<String, dynamic>) {
        continue;
      }

      final inlineData = part['inlineData'] as Map<String, dynamic>?;
      if (inlineData == null) {
        continue;
      }

      final mimeType = inlineData['mimeType'] as String?;
      final b64Data = inlineData['data'] as String?;
      if (mimeType != null &&
          b64Data != null &&
          mimeType.startsWith('audio/')) {
        audioChunks.add(base64Decode(b64Data));
      }
    }

    return GeminiServerEvent(
      turnComplete: turnComplete,
      audioChunks: audioChunks,
      outputTranscripts: outputTexts,
      inputTranscripts: inputTexts,
    );
  }
}

class GeminiLiveService {
  GeminiLiveService({WebSocketChannel Function(Uri uri)? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  static const String _systemInstruction =
      'You are AEyes, an AI visual assistant for blind and visually impaired people. '
      'You see through the user\'s phone camera in real-time. '
      'Your role is to: describe surroundings clearly and concisely; '
      'help navigate by describing the environment; identify objects, text, products, signs, and people\'s activities; '
      'warn about obstacles or potential dangers; read signs and labels aloud. '
      'Speak naturally and warmly. Be specific and safety-conscious. '
      'Keep responses brief unless asked for more detail.';

  final WebSocketChannel Function(Uri uri) _channelFactory;

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _setupComplete = false;
  Completer<void>? _readyCompleter;
  String? _lastCloseReason;
  int? _lastCloseCode;

  final _audioResponseController = StreamController<Uint8List>.broadcast();
  final _outputTranscriptController =
      StreamController<GeminiTranscriptEvent>.broadcast();
  final _turnCompleteController = StreamController<void>.broadcast();
  final _stateController =
      StreamController<GeminiConnectionState>.broadcast();

  Stream<Uint8List> get audioResponseStream => _audioResponseController.stream;
  Stream<GeminiTranscriptEvent> get outputTranscriptStream =>
      _outputTranscriptController.stream;
  Stream<void> get turnCompleteStream => _turnCompleteController.stream;
  Stream<GeminiConnectionState> get stateStream => _stateController.stream;

  bool get isReady => _isConnected && _setupComplete;

  Future<void> connect(String apiKey) async {
    if (_isConnected) {
      await disconnect();
    }

    _readyCompleter = Completer<void>();
    _lastCloseCode = null;
    _lastCloseReason = null;
    _stateController.add(GeminiConnectionState.connecting);

    try {
      final uri = Uri.parse('$_wsBaseUrl?key=$apiKey');
      _channel = _channelFactory(uri);
      await _channel!.ready;
      _isConnected = true;

      _channel!.stream.listen(
        _handleMessage,
        onError: _handleSocketFailure,
        onDone: _handleSocketDone,
      );

      _sendSetup();
      await _readyCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _handleSocketFailure(e);
      rethrow;
    }
  }

  Map<String, dynamic> buildSetupPayload() {
    return {
      'setup': {
        'model': 'models/$geminiModel',
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Zephyr'}
            }
          }
        },
        'outputAudioTranscription': {},
        'systemInstruction': {
          'parts': [
            {'text': _systemInstruction}
          ]
        },
        'contextWindowCompression': {
          'triggerTokens': 25600,
          'slidingWindow': {'targetTokens': 12800}
        },
      }
    };
  }

  void _sendSetup() {
    final setup = buildSetupPayload();
    debugPrint(
      '[GeminiLive] sending setup: '
      '${jsonEncode(_debugSanitizeSetupPayload(setup))}',
    );
    _channel?.sink.add(jsonEncode(setup));
  }

  void _handleMessage(dynamic message) {
    final event = GeminiServerEvent.tryParse(message);
    if (event == null) {
      return;
    }

    if (event.setupComplete) {
      _setupComplete = true;
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter?.complete();
      }
      _stateController.add(GeminiConnectionState.ready);
      return;
    }

    for (final chunk in event.audioChunks) {
      _audioResponseController.add(chunk);
    }

    for (final text in event.outputTranscripts) {
      if (text.isEmpty) {
        continue;
      }
      _outputTranscriptController.add(
        GeminiTranscriptEvent(
          text: text,
          type: GeminiTranscriptType.outputAudio,
        ),
      );
    }

    for (final text in event.inputTranscripts) {
      if (text.isEmpty) {
        continue;
      }
      _outputTranscriptController.add(
        GeminiTranscriptEvent(
          text: text,
          type: GeminiTranscriptType.inputAudio,
        ),
      );
    }

    if (event.turnComplete) {
      _turnCompleteController.add(null);
    }
  }

  void _handleSocketFailure(Object error) {
    debugPrint('[GeminiLive] stream error: $error');
    if (!(_readyCompleter?.isCompleted ?? true)) {
      _readyCompleter?.completeError(
        _setupComplete
            ? error
            : GeminiSetupException(_buildSetupFailureMessage(error)),
      );
    }
    _stateController.add(GeminiConnectionState.error);
    _isConnected = false;
    _setupComplete = false;
  }

  void _handleSocketDone() {
    _lastCloseCode = _channel?.closeCode;
    _lastCloseReason = _channel?.closeReason;
    debugPrint(
      '[GeminiLive] stream closed - code=$_lastCloseCode, '
      'reason=$_lastCloseReason',
    );

    if (!(_readyCompleter?.isCompleted ?? true)) {
      _readyCompleter?.completeError(
        GeminiSetupException(_buildSetupFailureMessage()),
      );
    }
    if (_isConnected) {
      _stateController.add(GeminiConnectionState.disconnected);
    }
    _isConnected = false;
    _setupComplete = false;
  }

  String _buildSetupFailureMessage([Object? error]) {
    final buffer = StringBuffer(
      'Gemini setup rejected before setupComplete',
    );
    if (_lastCloseCode != null) {
      buffer.write(' (code=$_lastCloseCode');
      if (_lastCloseReason != null && _lastCloseReason!.isNotEmpty) {
        buffer.write(', reason=$_lastCloseReason');
      }
      buffer.write(')');
    } else if (_lastCloseReason != null && _lastCloseReason!.isNotEmpty) {
      buffer.write(' (reason=$_lastCloseReason)');
    }

    if (error != null) {
      buffer.write(': $error');
    }
    return buffer.toString();
  }

  Map<String, dynamic> _debugSanitizeSetupPayload(Map<String, dynamic> setup) {
    return Map<String, dynamic>.from(setup);
  }

  void sendAudio(Uint8List pcmData) {
    if (!isReady) {
      return;
    }
    _channel?.sink.add(jsonEncode({
      'realtimeInput': {
        'mediaChunks': [
          {
            'data': base64Encode(pcmData),
            'mimeType': 'audio/pcm',
          }
        ]
      }
    }));
  }

  void sendImage(Uint8List jpegData) {
    if (!isReady) {
      return;
    }
    _channel?.sink.add(jsonEncode({
      'realtimeInput': {
        'mediaChunks': [
          {
            'data': base64Encode(jpegData),
            'mimeType': 'image/jpeg',
          }
        ]
      }
    }));
  }

  void sendText(String text) {
    if (!isReady) {
      return;
    }
    _channel?.sink.add(jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'turnComplete': true,
      }
    }));
  }

  Future<void> disconnect() async {
    final channel = _channel;
    _channel = null;
    _isConnected = false;
    _setupComplete = false;
    if (!(_readyCompleter?.isCompleted ?? true)) {
      _readyCompleter?.completeError(
        GeminiSetupException('Gemini session disconnected before setup completed.'),
      );
    }
    if (!_stateController.isClosed) {
      _stateController.add(GeminiConnectionState.disconnected);
    }
    await channel?.sink.close();
  }

  void dispose() {
    disconnect();
    _audioResponseController.close();
    _outputTranscriptController.close();
    _turnCompleteController.close();
    _stateController.close();
  }
}
