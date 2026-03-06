import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Gemini API Key.
///
/// Loaded from .env file at runtime.
String get geminiApiKey => dotenv.env['GEMINI_API_KEY'] ?? '';

/// Gemini model for the Live API.
const String geminiModel = 'gemini-2.5-flash-native-audio-preview-12-2025';
