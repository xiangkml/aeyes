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

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _setupComplete = false;

  final _audioResponseController = StreamController<Uint8List>.broadcast();
  final _textResponseController = StreamController<String>.broadcast();
  final _turnCompleteController = StreamController<void>.broadcast();
  final _stateController =
      StreamController<GeminiConnectionState>.broadcast();

  Stream<Uint8List> get audioResponseStream => _audioResponseController.stream;
  Stream<String> get textResponseStream => _textResponseController.stream;
  Stream<void> get turnCompleteStream => _turnCompleteController.stream;
  Stream<GeminiConnectionState> get stateStream => _stateController.stream;

  bool get isReady => _isConnected && _setupComplete;

  Future<void> connect(String apiKey) async {
    if (_isConnected) await disconnect();
    _stateController.add(GeminiConnectionState.connecting);

    try {
      final uri = Uri.parse('$_wsBaseUrl?key=$apiKey');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;

      _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          debugPrint('[GeminiLive] stream error: $error');
          _stateController.add(GeminiConnectionState.error);
          _isConnected = false;
          _setupComplete = false;
        },
        onDone: () {
          debugPrint('[GeminiLive] stream closed – '
              'code=${_channel?.closeCode}, reason=${_channel?.closeReason}');
          if (_isConnected) {
            _stateController.add(GeminiConnectionState.disconnected);
          }
          _isConnected = false;
          _setupComplete = false;
        },
      );

      _sendSetup();
    } catch (e) {
      _stateController.add(GeminiConnectionState.error);
      _isConnected = false;
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
        _stateController.add(GeminiConnectionState.ready);
        return;
      }

      final serverContent = data['serverContent'] as Map<String, dynamic>?;
      if (serverContent == null) return;

      if (serverContent['turnComplete'] == true) {
        _turnCompleteController.add(null);
        return;
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn == null) return;

      final parts = modelTurn['parts'] as List<dynamic>?;
      if (parts == null) return;

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
    } catch (_) {
      // Malformed message — skip
    }
  }

  void sendAudio(Uint8List pcmData) {
    if (!isReady) return;
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
    if (!isReady) return;
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
    if (!isReady) return;
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
    _isConnected = false;
    _setupComplete = false;
    await _channel?.sink.close();
    _channel = null;
    _stateController.add(GeminiConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _audioResponseController.close();
    _textResponseController.close();
    _turnCompleteController.close();
    _stateController.close();
  }
}
