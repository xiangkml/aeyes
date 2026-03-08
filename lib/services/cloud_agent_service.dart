import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class CloudAgentService {
  CloudAgentService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  bool get isEnabled => cloudBackendBaseUrl.trim().isNotEmpty;

  Future<String?> createSession({
    required String platform,
    required String mode,
    required Map<String, dynamic> arCapabilities,
  }) async {
    if (!isEnabled) {
      return null;
    }

    final response = await _client.post(
      Uri.parse('${cloudBackendBaseUrl.trim()}/v1/sessions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'platform': platform,
        'mode': mode,
        'arCapabilities': arCapabilities,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Cloud session creation failed: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['sessionId'] as String?;
  }

  Future<void> syncContext({
    required String sessionId,
    required String mode,
    required String sceneSummary,
    required String memoryContext,
    required String transcript,
    String? currentGoal,
    required Map<String, dynamic> arCapabilities,
  }) async {
    if (!isEnabled) {
      return;
    }

    final response = await _client.post(
      Uri.parse('${cloudBackendBaseUrl.trim()}/v1/sessions/$sessionId/context'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'mode': mode,
        'sceneSummary': sceneSummary,
        'memoryContext': memoryContext,
        'transcript': transcript,
        'currentGoal': currentGoal,
        'arCapabilities': arCapabilities,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Cloud context sync failed: ${response.body}');
    }
  }

  Future<void> closeSession(String sessionId, {String reason = 'ended'}) async {
    if (!isEnabled) {
      return;
    }
    await _client.post(
      Uri.parse('${cloudBackendBaseUrl.trim()}/v1/sessions/$sessionId/close'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'reason': reason}),
    );
  }

  void dispose() {
    _client.close();
  }
}
