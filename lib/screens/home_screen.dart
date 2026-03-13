import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import '../services/audio_service.dart';
import '../services/camera_frame_service.dart';
import '../services/cloud_agent_service.dart';
import '../services/gemini_live_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _frameCadence = Duration(milliseconds: 450);
  static const _assistantSpeechHold = Duration(milliseconds: 1200);
  static const _assistantSpeechTimeout = Duration(seconds: 4);
  static const _playbackCooldown = Duration(milliseconds: 600);
  static const _amplitudePollInterval = Duration(milliseconds: 150);
  static const _bargeInConfirmationsRequired = 5;
  static const _memoryUploadCooldown = Duration(seconds: 12);
  static const _repeatLabelThreshold = 3;

  final GeminiLiveService _gemini = GeminiLiveService();
  final AudioService _audio = AudioService();
  final CloudAgentService _cloud = CloudAgentService();
  final FrameSendScheduler<CameraImage> _frameScheduler =
      FrameSendScheduler(minInterval: _frameCadence);

  CameraController? _camCtrl;
  Timer? _frameTickTimer;
  Timer? _amplitudeTimer;

  bool _isActive = false;
  bool _isStreamingFrames = false;
  String _status = 'Tap to start';
  String _lastTranscript = '';
  String _lastError = '';
  String _sceneSummary = '';
  String _cloudStatus = cloudBackendBaseUrl.trim().isEmpty ? 'disabled' : 'idle';
  int _audioChunksSent = 0;
  int _framesSent = 0;
  int _audioChunksReceived = 0;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _zoomLevel = 1;
  double _baseScale = 1;
  bool _introSent = false;
  bool _assistantSpeaking = false;
  bool _turnCompleteReceived = false;
  int _bargeInConfirmations = 0;
  String? _cloudSessionId;
  DateTime? _lastAssistantAudioAt;
  DateTime? _playbackEndedAt;
  final StringBuffer _turnBuffer = StringBuffer();
  Uint8List? _latestFrameJpeg;
  int _latestFrameWidth = 0;
  int _latestFrameHeight = 0;
  DateTime? _latestFrameAt;
  DateTime? _lastMemoryUploadAt;
  DateTime? _lastMemoryHintAt;
  String _lastUploadedLabel = '';
  String _lastHintLabel = '';
  String _memoryStatus = 'idle';
  int _savedMemories = 0;
  final Map<String, int> _labelSeenCount = <String, int>{};

  StreamSubscription? _audioSub;
  StreamSubscription? _textSub;
  StreamSubscription? _turnSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSession(updateUi: false);
    _camCtrl?.dispose();
    _gemini.dispose();
    _cloud.dispose();
    _audio.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopSession();
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      return;
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _camCtrl = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );

    try {
      await _camCtrl!.initialize();
      _minZoom = await _camCtrl!.getMinZoomLevel();
      _maxZoom = await _camCtrl!.getMaxZoomLevel();
      _zoomLevel = _minZoom;
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Camera not available';
          _lastError = '$error';
        });
      }
    }
  }

  Future<bool> _requestPermissions() async {
    final camera = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    return camera.isGranted && mic.isGranted;
  }

  Future<void> _toggle() async {
    if (_isActive) {
      _stopSession();
    } else {
      await _startSession();
    }
  }

  Future<void> _startSession() async {
    if (!await _requestPermissions()) {
      if (mounted) {
        setState(() {
          _status = 'Permissions denied';
          _lastError = 'Camera or microphone permission denied';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _status = 'Connecting...';
        _isActive = true;
        _lastError = '';
        _lastTranscript = '';
        _sceneSummary = '';
        _audioChunksSent = 0;
        _framesSent = 0;
        _audioChunksReceived = 0;
        _introSent = false;
        _cloudStatus = _cloud.isEnabled ? 'connecting' : 'disabled';
      });
    }

    _cancelSubscriptions();
    _frameScheduler.clear();
    _turnBuffer.clear();
    _cloudSessionId = null;

    _stateSub = _gemini.stateStream.listen((state) {
      if (!mounted) {
        return;
      }
      setState(() {
        switch (state) {
          case GeminiConnectionState.connecting:
            _status = 'Connecting...';
            break;
          case GeminiConnectionState.ready:
            _status = 'Listening...';
            break;
          case GeminiConnectionState.error:
            _status = 'Connection error';
            _isActive = false;
            _lastError = _gemini.lastCloseReason ?? 'Gemini stream error';
            break;
          case GeminiConnectionState.disconnected:
            _status = 'Disconnected';
            _isActive = false;
            break;
        }
      });
    });

    _audioSub = _gemini.audioResponseStream.listen((chunk) {
      _markAssistantSpeaking();
      _audio.addAudioChunk(chunk);
      if (mounted) {
        setState(() {
          _audioChunksReceived++;
        });
      }
    });

    _turnSub = _gemini.turnCompleteStream.listen((_) {
      _turnCompleteReceived = true;
      _audio.onTurnComplete();
      unawaited(_syncCloudContext());
    });

    _textSub = _gemini.textResponseStream.listen((text) {
      if (!mounted || text.isEmpty) {
        return;
      }
      setState(() {
        _lastTranscript = text;
      });
      _turnBuffer.write(text);
      unawaited(_evaluateScreenshotTrigger(text));
      debugPrint('Gemini: $text');
    });

    try {
      try {
        _cloudSessionId = await _cloud.createSession(
          platform: defaultTargetPlatform.name,
          mode: 'live_assistance',
          arCapabilities: const {
            'enabled': false,
            'provider': 'camera_only',
          },
        );
        if (mounted) {
          setState(() {
            _cloudStatus = _cloudSessionId == null ? 'disabled' : 'connected';
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _cloudStatus = 'offline';
            _lastError = 'Cloud session unavailable: $error';
          });
        }
      }

      await _gemini.connect(
        geminiApiKey,
        cloudSessionId: _cloudSessionId,
      );
      await _audio.startRecording((data) {
        if (_assistantSpeaking) {
          return;
        }
        // Suppress mic input briefly after playback ends to avoid echo.
        final playbackEndedAt = _playbackEndedAt;
        if (playbackEndedAt != null &&
            DateTime.now().difference(playbackEndedAt) < _playbackCooldown) {
          return;
        }
        _gemini.sendAudio(data);
        if (mounted) {
          setState(() {
            _audioChunksSent++;
          });
        }
      });
      _startAmplitudeMonitor();
      await _startFrameStream();
      _sendIntroPrompt();
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Failed to connect';
          _isActive = false;
          _lastError = '$error';
        });
      }
      await _stopFrameStream();
    }
  }

  void _sendIntroPrompt() {
    if (_introSent || !_isActive || !_gemini.isReady) {
      return;
    }
    _introSent = true;
    _gemini.sendText(_gemini.startupPrompt);
    if (mounted) {
      setState(() {
        _status = 'Assistant is greeting you...';
      });
    }
  }

  Future<void> _startFrameStream() async {
    final controller = _camCtrl;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    await _stopFrameStream();
    await controller.startImageStream((image) {
      _frameScheduler.push(image);
    });
    _isStreamingFrames = true;

    _frameTickTimer = Timer.periodic(_frameCadence, (_) {
      unawaited(
        _frameScheduler.dispatchLatest((image) async {
          if (!_isActive || !_gemini.isReady) {
            return;
          }
          final jpegBytes = await encodeCameraImageToJpeg(image);
          if (jpegBytes != null && _isActive) {
            _latestFrameJpeg = jpegBytes;
            _latestFrameWidth = image.width;
            _latestFrameHeight = image.height;
            _latestFrameAt = DateTime.now();
            _gemini.sendImage(jpegBytes);
            if (mounted) {
              setState(() {
                _framesSent++;
              });
            }
          }
        }),
      );
    });
  }

  Future<void> _stopFrameStream() async {
    _frameTickTimer?.cancel();
    _frameTickTimer = null;
    _frameScheduler.clear();

    final controller = _camCtrl;
    if (_isStreamingFrames && controller != null) {
      _isStreamingFrames = false;
      try {
        await controller.stopImageStream();
      } catch (_) {}
    }
  }

  void _startAmplitudeMonitor() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = Timer.periodic(_amplitudePollInterval, (_) {
      unawaited(_pollForBargeIn());
    });
  }

  Future<void> _pollForBargeIn() async {
    if (!_isActive) {
      return;
    }

    final lastAssistantAudioAt = _lastAssistantAudioAt;
    if (_assistantSpeaking &&
        lastAssistantAudioAt != null) {
      final elapsed = DateTime.now().difference(lastAssistantAudioAt);
      // Only transition out of speaking when turnComplete has been received
      // and enough time has passed, OR as a safety fallback after a longer timeout.
      final canTransition = _turnCompleteReceived
          ? elapsed > _assistantSpeechHold
          : elapsed > _assistantSpeechTimeout;
      if (!canTransition) {
        return;
      }
      // Don't exit speaking state while the player still has buffered audio.
      if (_audio.hasPendingPlayback) {
        return;
      }
      // Also wait for the player's internal buffer to finish playing.
      final lastFeed = _audio.lastFeedTime;
      if (lastFeed != null &&
          DateTime.now().difference(lastFeed) < _assistantSpeechHold) {
        return;
      }
      _assistantSpeaking = false;
      _turnCompleteReceived = false;
      _bargeInConfirmations = 0;
      _playbackEndedAt = DateTime.now();
      if (mounted && _gemini.isReady) {
        setState(() {
          _status = 'Listening...';
        });
      }
    }

    if (!_assistantSpeaking) {
      _bargeInConfirmations = 0;
      return;
    }

    final amplitudeDb = await _audio.getCurrentAmplitudeDb();
    if (amplitudeDb == null) {
      return;
    }

    if (amplitudeDb >= AudioService.userSpeechThresholdDb) {
      _bargeInConfirmations++;
    } else {
      _bargeInConfirmations = 0;
    }

    if (_bargeInConfirmations < _bargeInConfirmationsRequired) {
      return;
    }

    _bargeInConfirmations = 0;
    _assistantSpeaking = false;
    _turnCompleteReceived = false;
    _playbackEndedAt = DateTime.now();
    _audio.clearPlayback();
    if (mounted) {
      setState(() {
        _status = 'Listening...';
      });
    }
  }

  void _markAssistantSpeaking() {
    _lastAssistantAudioAt = DateTime.now();
    _bargeInConfirmations = 0;
    _turnCompleteReceived = false;
    if (_assistantSpeaking) {
      return;
    }
    _assistantSpeaking = true;
    if (mounted) {
      setState(() {
        _status = 'AEyes is speaking...';
      });
    }
  }

  void _stopSession({bool updateUi = true}) {
    final cloudSessionId = _cloudSessionId;
    _cloudSessionId = null;
    _turnBuffer.clear();
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    _assistantSpeaking = false;
    _turnCompleteReceived = false;
    _bargeInConfirmations = 0;
    _lastAssistantAudioAt = null;
    _playbackEndedAt = null;
    _latestFrameJpeg = null;
    _latestFrameAt = null;
    _latestFrameWidth = 0;
    _latestFrameHeight = 0;
    _labelSeenCount.clear();
    _lastUploadedLabel = '';
    _lastMemoryUploadAt = null;
    _lastMemoryHintAt = null;
    _lastHintLabel = '';
    _memoryStatus = _cloud.isEnabled ? 'idle' : 'disabled';
    unawaited(_stopFrameStream());
    _audio.stopRecording();
    _audio.clearPlayback();
    _gemini.disconnect();
    _cancelSubscriptions();
    if (cloudSessionId != null) {
      unawaited(_cloud.closeSession(cloudSessionId));
    }

    if (updateUi && mounted) {
      setState(() {
        _isActive = false;
        _status = 'Tap to start';
        _cloudStatus = _cloud.isEnabled ? 'idle' : 'disabled';
      });
    } else {
      _isActive = false;
    }
  }

  Future<void> _syncCloudContext() async {
    final sessionId = _cloudSessionId;
    if (sessionId == null) {
      _turnBuffer.clear();
      return;
    }

    final transcript = _turnBuffer.toString().trim();
    _turnBuffer.clear();
    if (transcript.isEmpty) {
      return;
    }

    if (_sceneSummary.isEmpty) {
      _sceneSummary = transcript;
    }

    try {
      await _cloud.syncContext(
        sessionId: sessionId,
        mode: 'live_assistance',
        sceneSummary: _sceneSummary,
        memoryContext: _savedMemories == 0
            ? _lastTranscript
            : '${_lastTranscript.trim()} | visualMemoryCount=$_savedMemories',
        transcript: transcript,
        currentGoal: null,
        arCapabilities: const {
          'enabled': false,
          'provider': 'camera_only',
        },
      );
      if (mounted) {
        setState(() {
          _cloudStatus = 'synced';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _cloudStatus = 'error';
          _lastError = 'Cloud sync failed: $error';
        });
      }
    }
  }

  Future<void> _evaluateScreenshotTrigger(String text) async {
    final sessionId = _cloudSessionId;
    final latestFrame = _latestFrameJpeg;
    if (!_isActive || sessionId == null || latestFrame == null || !_cloud.isEnabled) {
      return;
    }

    final now = DateTime.now();
    final lower = text.toLowerCase();
    final labels = _extractLabels(text);
    final primaryLabel = labels.isNotEmpty ? labels.first : _inferLabelFromText(lower);

    bool intentTrigger = _containsAny(
      lower,
      const [
        'find',
        'look for',
        'recognize',
        'identify',
        'searching for',
      ],
    );
    bool confidenceTrigger = _containsAny(
      lower,
      const [
        'i found',
        'i can see your',
        'that is your',
        'this is your',
        'looks like your',
      ],
    );
    bool manualTrigger = _containsAny(
      lower,
      const [
        'save this object',
        'save this item',
        'remember this object',
        'i will save this',
      ],
    );

    int repeatCount = 0;
    bool repeatTrigger = false;
    if (primaryLabel.isNotEmpty) {
      repeatCount = (_labelSeenCount[primaryLabel] ?? 0) + 1;
      _labelSeenCount[primaryLabel] = repeatCount;
      repeatTrigger = repeatCount >= _repeatLabelThreshold;
    }

    if (!intentTrigger && !confidenceTrigger && !repeatTrigger && !manualTrigger) {
      return;
    }

    final lastUploadAt = _lastMemoryUploadAt;
    if (lastUploadAt != null && now.difference(lastUploadAt) < _memoryUploadCooldown) {
      return;
    }

    if (primaryLabel.isNotEmpty && primaryLabel == _lastUploadedLabel) {
      return;
    }

    final confidence = confidenceTrigger ? 0.88 : (repeatTrigger ? 0.72 : 0.61);
    final embedText = ([primaryLabel, ...labels].where((item) => item.isNotEmpty).join(' ')).trim();
    final embedding = _buildLabelEmbedding(embedText);

    if (intentTrigger && primaryLabel.isNotEmpty) {
      unawaited(
        _maybeInjectMemoryHint(
          sessionId: sessionId,
          label: primaryLabel,
          embedding: embedding,
        ),
      );
    }

    await _uploadObjectMemorySnapshot(
      sessionId: sessionId,
      frame: latestFrame,
      userLabel: primaryLabel,
      aiLabel: labels.join(', '),
      triggerReason: manualTrigger
          ? 'manual'
          : confidenceTrigger
              ? 'confidence'
              : repeatTrigger
                  ? 'repeat'
                  : 'intent',
      confidence: confidence,
      repeatCount: repeatCount,
      intentTrigger: intentTrigger,
      confidenceTrigger: confidenceTrigger,
      repeatTrigger: repeatTrigger,
      manualTrigger: manualTrigger,
      embedding: embedding,
    );
  }

  Future<void> _uploadObjectMemorySnapshot({
    required String sessionId,
    required Uint8List frame,
    required String userLabel,
    required String aiLabel,
    required String triggerReason,
    required double confidence,
    required int repeatCount,
    required bool intentTrigger,
    required bool confidenceTrigger,
    required bool repeatTrigger,
    required bool manualTrigger,
    required List<double> embedding,
  }) async {
    try {
      if (mounted) {
        setState(() {
          _memoryStatus = 'saving';
        });
      }
      await _cloud.uploadScreenshot(
        sessionId: sessionId,
        imageBytes: frame,
        userLabel: userLabel,
        aiLabel: aiLabel,
        triggerReason: triggerReason,
        confidence: confidence,
        repeatCount: repeatCount,
        intentTrigger: intentTrigger,
        confidenceTrigger: confidenceTrigger,
        repeatTrigger: repeatTrigger,
        manualTrigger: manualTrigger,
        width: _latestFrameWidth,
        height: _latestFrameHeight,
        frameTimestamp: _latestFrameAt?.toUtc().toIso8601String(),
        embedding: embedding,
      );
      _lastMemoryUploadAt = DateTime.now();
      if (userLabel.isNotEmpty) {
        _lastUploadedLabel = userLabel;
      }
      if (mounted) {
        setState(() {
          _savedMemories++;
          _memoryStatus = 'saved';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _memoryStatus = 'error';
          _lastError = 'Memory save failed: $error';
        });
      }
    }
  }

  Future<void> _maybeInjectMemoryHint({
    required String sessionId,
    required String label,
    required List<double> embedding,
  }) async {
    final now = DateTime.now();
    if (_lastHintLabel == label &&
        _lastMemoryHintAt != null &&
        now.difference(_lastMemoryHintAt!) < const Duration(seconds: 25)) {
      return;
    }

    try {
      final matches = await _cloud.matchScreenshots(
        sessionId: sessionId,
        userLabel: label,
        aiLabel: label,
        embedding: embedding,
        topK: 1,
        minScore: 0.55,
      );
      if (matches.isEmpty || !_gemini.isReady || !_isActive) {
        return;
      }

      final top = matches.first;
      final topLabel = _normalizeLabel(
        (top['userLabel'] as String?) ?? (top['aiLabel'] as String?) ?? label,
      );
      final matchScore = (top['matchScore'] as num?)?.toDouble() ?? 0;
      final hint =
          'Memory hint: previously seen "$topLabel" with similarity score ${matchScore.toStringAsFixed(2)}. '
          'Use this memory while guiding the user to find the object now.';

      _gemini.sendText(hint);
      _lastHintLabel = label;
      _lastMemoryHintAt = now;
    } catch (_) {
      // Ignore memory lookup failures to avoid interrupting real-time assistance.
    }
  }

  List<String> _extractLabels(String text) {
    final labels = <String>[];
    final bracketPattern = RegExp(r'\[([^\]]+)\]');
    for (final match in bracketPattern.allMatches(text)) {
      final content = (match.group(1) ?? '').trim();
      if (content.isEmpty) {
        continue;
      }
      final parts = content.split(',');
      for (final raw in parts) {
        final normalized = _normalizeLabel(raw);
        if (normalized.isNotEmpty && !labels.contains(normalized)) {
          labels.add(normalized);
        }
      }
    }
    return labels;
  }

  String _inferLabelFromText(String text) {
    final patterns = [
      RegExp(r'your\s+([a-z ]{2,40})'),
      RegExp(r'found\s+(?:a|an|the)?\s*([a-z ]{2,40})'),
      RegExp(r'identified\s+(?:a|an|the)?\s*([a-z ]{2,40})'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) {
        continue;
      }
      final label = _normalizeLabel(match.group(1) ?? '');
      if (label.isNotEmpty) {
        return label;
      }
    }
    return '';
  }

  String _normalizeLabel(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _containsAny(String text, List<String> terms) {
    for (final term in terms) {
      if (text.contains(term)) {
        return true;
      }
    }
    return false;
  }

  List<double> _buildLabelEmbedding(String text) {
    if (text.isEmpty) {
      return const <double>[];
    }
    const dims = 24;
    final vector = List<double>.filled(dims, 0);
    final codeUnits = text.toLowerCase().codeUnits;
    for (var i = 0; i < codeUnits.length; i++) {
      final bucket = i % dims;
      vector[bucket] += (codeUnits[i] % 97) / 97.0;
    }
    return vector;
  }

  void _cancelSubscriptions() {
    _audioSub?.cancel();
    _textSub?.cancel();
    _turnSub?.cancel();
    _stateSub?.cancel();
  }

  Future<void> _setZoomLevel(double value) async {
    final controller = _camCtrl;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final clamped = value.clamp(_minZoom, _maxZoom);
    await controller.setZoomLevel(clamped);
    if (mounted) {
      setState(() {
        _zoomLevel = clamped;
      });
    }
  }

  Widget _buildCameraPreview() {
    final controller = _camCtrl;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return CameraPreview(controller);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onScaleStart: (_) => _baseScale = _zoomLevel,
          onScaleUpdate: (details) {
            _setZoomLevel(_baseScale * details.scale);
          },
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: previewSize.height,
                height: previewSize.width,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDebugPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(170),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white70, fontSize: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ready=${_gemini.isReady} active=$_isActive'),
            Text(
              'apiKeyPresent=${geminiApiKey.trim().isNotEmpty || cloudLiveWebSocketUri != null}',
            ),
            Text('cloud=$_cloudStatus session=${_cloudSessionId ?? '-'}'),
            Text('audioSent=$_audioChunksSent audioReceived=$_audioChunksReceived'),
            Text('framesSent=$_framesSent stream=$_isStreamingFrames'),
            Text('assistantSpeaking=$_assistantSpeaking'),
            Text('memory=$_memoryStatus saved=$_savedMemories'),
            Text('zoom=${_zoomLevel.toStringAsFixed(2)}x'),
            if (_audio.lastPlaybackError != null)
              Text('playback=${_audio.lastPlaybackError}'),
            if (_gemini.lastCloseCode != null || _gemini.lastCloseReason != null)
              Text(
                'socket=${_gemini.lastCloseCode ?? '-'} '
                '${_gemini.lastCloseReason ?? ''}',
              ),
            if (_lastTranscript.isNotEmpty) Text('text=$_lastTranscript'),
            if (_lastError.isNotEmpty) Text('error=$_lastError'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: const Text(
                  'AEyes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withAlpha(220),
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDebugPanel(),
                  const SizedBox(height: 16),
                  Text(
                    _status,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (_maxZoom > _minZoom)
                    Column(
                      children: [
                        Slider(
                          value: _zoomLevel.clamp(_minZoom, _maxZoom),
                          min: _minZoom,
                          max: _maxZoom,
                          divisions: ((_maxZoom - _minZoom) * 10)
                              .clamp(1, 100)
                              .round(),
                          onChanged: (value) => _setZoomLevel(value),
                        ),
                        Text(
                          'Zoom ${_zoomLevel.toStringAsFixed(1)}x',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  GestureDetector(
                    onTap: _toggle,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isActive
                            ? Colors.red.shade600
                            : Colors.green.shade600,
                      ),
                      child: Icon(
                        _isActive ? Icons.stop_rounded : Icons.visibility,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
