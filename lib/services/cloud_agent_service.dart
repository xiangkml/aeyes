import 'dart:convert';
import 'dart:typed_data';

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

  Future<Map<String, dynamic>> uploadScreenshot({
    required String sessionId,
    required Uint8List imageBytes,
    String userLabel = '',
    String aiLabel = '',
    String triggerReason = 'unknown',
    double? confidence,
    int repeatCount = 0,
    bool intentTrigger = false,
    bool confidenceTrigger = false,
    bool repeatTrigger = false,
    bool manualTrigger = false,
    int width = 0,
    int height = 0,
    String? frameTimestamp,
    List<double>? embedding,
  }) async {
    if (!isEnabled) {
      return const {'ok': false, 'reason': 'cloud-disabled'};
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${cloudBackendBaseUrl.trim()}/v1/sessions/$sessionId/screenshots'),
    );

    final metadata = {
      'userLabel': userLabel,
      'aiLabel': aiLabel,
      'triggerReason': triggerReason,
      'confidence': confidence,
      'repeatCount': repeatCount,
      'intentTrigger': intentTrigger,
      'confidenceTrigger': confidenceTrigger,
      'repeatTrigger': repeatTrigger,
      'manualTrigger': manualTrigger,
      'width': width,
      'height': height,
      'frameTimestamp': frameTimestamp,
      'embedding': embedding,
    };

    request.fields['metadata'] = jsonEncode(metadata);
    request.files.add(
      http.MultipartFile.fromBytes(
        'image',
        imageBytes,
        filename: 'snapshot.jpg',
      ),
    );

    final response = await _client.send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404) {
        throw StateError(
          'Cloud screenshot upload failed: endpoint not deployed on backend. '
          'Deploy cloud_backend/main.py with /v1/sessions/{sessionId}/screenshots.',
        );
      }
      throw StateError('Cloud screenshot upload failed: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listScreenshots({
    required String sessionId,
    int limit = 20,
  }) async {
    if (!isEnabled) {
      return const [];
    }

    final response = await _client.get(
      Uri.parse(
        '${cloudBackendBaseUrl.trim()}/v1/sessions/$sessionId/screenshots?limit=$limit',
      ),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Cloud screenshot list failed: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rawItems = body['items'];
    if (rawItems is! List) {
      return const [];
    }

    return rawItems
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> matchScreenshots({
    required String sessionId,
    String userLabel = '',
    String aiLabel = '',
    List<double>? embedding,
    int topK = 5,
    double minScore = 0.2,
  }) async {
    if (!isEnabled) {
      return const [];
    }

    final response = await _client.post(
      Uri.parse('${cloudBackendBaseUrl.trim()}/v1/sessions/$sessionId/screenshots/match'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userLabel': userLabel,
        'aiLabel': aiLabel,
        'embedding': embedding,
        'topK': topK,
        'minScore': minScore,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Cloud screenshot matching failed: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final rawItems = body['items'];
    if (rawItems is! List) {
      return const [];
    }

    return rawItems
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  void dispose() {
    _client.close();
  }
}
