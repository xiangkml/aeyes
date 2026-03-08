import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Gemini API Key.
///
/// Loaded from .env file at runtime.
String get geminiApiKey {
  try {
    return dotenv.env['GEMINI_API_KEY'] ?? '';
  } catch (_) {
    return '';
  }
}

String get cloudBackendBaseUrl {
  try {
    return dotenv.env['CLOUD_BACKEND_BASE_URL'] ?? '';
  } catch (_) {
    return '';
  }
}

Uri? get cloudLiveWebSocketUri {
  final baseUrl = cloudBackendBaseUrl.trim();
  if (baseUrl.isEmpty) {
    return null;
  }
  final httpUri = Uri.tryParse(baseUrl);
  if (httpUri == null) {
    return null;
  }
  final scheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
  return httpUri.replace(
    scheme: scheme,
    path: '${httpUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/live',
  );
}

/// Gemini model for the Live API.
const String geminiModel = 'gemini-2.5-flash-native-audio-preview-12-2025';
