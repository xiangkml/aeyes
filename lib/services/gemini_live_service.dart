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

class GeminiLiveService {
  GeminiLiveService({WebSocketChannel Function(Uri uri)? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  static const String _systemInstruction =
      'You are AEyes, an AI visual assistant speaking to a blind user. '
      'You see through the user\'s phone camera in real-time and should behave like a calm, practical guide. '
      'Prioritize spoken guidance over visual assumptions. '
      'Describe what matters in plain language, give short step-by-step spatial directions such as left, right, ahead, near, and far, '
      'and warn clearly about obstacles, edges, stairs, curbs, drops, slippery areas, traffic, hot items, sharp objects, low-hanging hazards, '
      'objects on the floor, clutter, open doors, and anything unsafe. '
      'If there is any possible danger, say it early and directly before giving other details. '
      'Continuously help the user avoid collisions, trips, and falls by calling out hazards in the walking path and nearby reach area. '
      'When helping the user find something, actively guide the search using the live camera view and say what they should do next. '
      'If the user is moving, prioritize navigation safety over object search. '
      'Read text aloud when useful. '
      'Speak naturally, warmly, and confidently. '
      'Keep responses brief, concrete, and action-oriented unless the user asks for more detail. '
      'Do not rely on the user reading the screen.';

  static const String _startupScanPrompt =
      'Start by greeting the user briefly in voice. '
      'Tell them you will first scan the space for safety. '
      'Ask them to stand still if possible and slowly move the phone in a full sweep from left to right, then slightly down toward the floor, '
      'then up again, and if safe continue around to complete a slow 360-degree scan. '
      'Keep the instructions short and clear because the user is blind.';

  static const String _sceneSummaryPrompt =
      'Based on the live scan you just observed, give a short spoken scene summary focused on safety first. '
      'Mention immediate hazards such as stairs, drops, floor clutter, sharp or hot objects, low obstacles, blocked paths, and safe open space. '
      'Then mention the main landmarks or likely search areas in the room. '
      'Keep it under six sentences and say when you are uncertain.';

  final WebSocketChannel Function(Uri uri) _channelFactory;

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _setupComplete = false;
  Completer<void>? _readyCompleter;
  int? _lastCloseCode;
  String? _lastCloseReason;

  final _audioResponseController = StreamController<Uint8List>.broadcast();
  final _textResponseController = StreamController<String>.broadcast();
  final _turnCompleteController = StreamController<void>.broadcast();
  final _stateController =
      StreamController<GeminiConnectionState>.broadcast();

  Stream<Uint8List> get audioResponseStream => _audioResponseController.stream;
  Stream<String> get textResponseStream => _textResponseController.stream;
  Stream<void> get turnCompleteStream => _turnCompleteController.stream;
  Stream<GeminiConnectionState> get stateStream => _stateController.stream;
  String get startupScanPrompt => _startupScanPrompt;
  String get sceneSummaryPrompt => _sceneSummaryPrompt;

  bool get isReady => _isConnected && _setupComplete;
  int? get lastCloseCode => _lastCloseCode;
  String? get lastCloseReason => _lastCloseReason;

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
        onError: (error) {
          debugPrint('[GeminiLive] stream error: $error');
          if (!(_readyCompleter?.isCompleted ?? true)) {
            _readyCompleter?.completeError(error);
          }
          _stateController.add(GeminiConnectionState.error);
          _isConnected = false;
          _setupComplete = false;
        },
        onDone: () {
          _lastCloseCode = _channel?.closeCode;
          _lastCloseReason = _channel?.closeReason;
          debugPrint('[GeminiLive] stream closed - '
              'code=$_lastCloseCode, reason=$_lastCloseReason');
          if (!(_readyCompleter?.isCompleted ?? true)) {
            _readyCompleter?.completeError(
              StateError(
                'Gemini connection closed before setup completed '
                '(code=$_lastCloseCode, reason=$_lastCloseReason)',
              ),
            );
          }
          if (_isConnected) {
            _stateController.add(GeminiConnectionState.disconnected);
          }
          _isConnected = false;
          _setupComplete = false;
        },
      );

      _sendSetup();
      await _readyCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _stateController.add(GeminiConnectionState.error);
      _isConnected = false;
      _setupComplete = false;
      rethrow;
    }
  }

  void _sendSetup() {
    final setup = {
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
    debugPrint('[GeminiLive] sending setup for model $geminiModel');
    _channel?.sink.add(jsonEncode(setup));
  }

  void _handleMessage(dynamic message) {
    String jsonStr;
    if (message is String) {
      jsonStr = message;
    } else if (message is List<int>) {
      jsonStr = utf8.decode(message);
    } else {
      return;
    }

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      if (data.containsKey('setupComplete')) {
        _setupComplete = true;
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter?.complete();
        }
        _stateController.add(GeminiConnectionState.ready);
        return;
      }

      final serverContent = data['serverContent'] as Map<String, dynamic>?;
      if (serverContent == null) {
        return;
      }

      if (serverContent['turnComplete'] == true) {
        _turnCompleteController.add(null);
        return;
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn == null) {
        return;
      }

      final parts = modelTurn['parts'] as List<dynamic>?;
      if (parts == null) {
        return;
      }

      for (final part in parts) {
        final inlineData = part['inlineData'] as Map<String, dynamic>?;
        if (inlineData != null) {
          final mimeType = inlineData['mimeType'] as String?;
          final b64Data = inlineData['data'] as String?;
          if (mimeType != null &&
              b64Data != null &&
              mimeType.startsWith('audio/')) {
            _audioResponseController.add(base64Decode(b64Data));
          }
        }

        final text = part['text'] as String?;
        if (text != null) {
          _textResponseController.add(text);
        }
      }
    } catch (error) {
      debugPrint('[GeminiLive] malformed message: $error');
    }
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
    if (!isReady || text.trim().isEmpty) {
      return;
    }
    _channel?.sink.add(jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ],
          }
        ],
        'turnComplete': true,
      }
    }));
  }

  Future<void> disconnect() async {
    _isConnected = false;
    _setupComplete = false;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
    if (!_stateController.isClosed) {
      _stateController.add(GeminiConnectionState.disconnected);
    }
  }

  void dispose() {
    disconnect();
    _audioResponseController.close();
    _textResponseController.close();
    _turnCompleteController.close();
    _stateController.close();
  }
}
