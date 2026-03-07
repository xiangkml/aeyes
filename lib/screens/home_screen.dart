import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import '../services/audio_service.dart';
import '../services/camera_frame_service.dart';
import '../services/gemini_live_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _frameCadence = Duration(milliseconds: 450);
  static const _scanDuration = Duration(seconds: 8);

  final GeminiLiveService _gemini = GeminiLiveService();
  final AudioService _audio = AudioService();
  final FrameSendScheduler<CameraImage> _frameScheduler =
      FrameSendScheduler(minInterval: _frameCadence);

  CameraController? _camCtrl;
  Timer? _frameTickTimer;
  Timer? _scanTimer;

  bool _isActive = false;
  bool _isStreamingFrames = false;
  String _status = 'Tap to start';
  String _lastTranscript = '';
  String _lastError = '';
  String _sceneSummary = '';
  int _audioChunksSent = 0;
  int _framesSent = 0;
  int _audioChunksReceived = 0;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _zoomLevel = 1;
  double _baseScale = 1;
  bool _scanStarted = false;
  bool _awaitingSceneSummary = false;
  final StringBuffer _summaryBuffer = StringBuffer();

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
        _scanStarted = false;
        _awaitingSceneSummary = false;
      });
    }

    _cancelSubscriptions();
    _frameScheduler.clear();

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
      _audio.addAudioChunk(chunk);
      if (mounted) {
        setState(() {
          _audioChunksReceived++;
        });
      }
    });

    _turnSub = _gemini.turnCompleteStream.listen((_) {
      _audio.onTurnComplete();
      _handleTurnComplete();
    });

    _textSub = _gemini.textResponseStream.listen((text) {
      if (!mounted || text.isEmpty) {
        return;
      }
      setState(() {
        _lastTranscript = text;
      });
      if (_awaitingSceneSummary) {
        _summaryBuffer.write(text);
      }
      debugPrint('Gemini: $text');
    });

    try {
      await _gemini.connect(geminiApiKey);
      await _audio.startRecording((data) {
        _gemini.sendAudio(data);
        if (mounted) {
          setState(() {
            _audioChunksSent++;
          });
        }
      });
      await _startFrameStream();
      _startSceneScan();
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

  void _startSceneScan() {
    if (_scanStarted || !_isActive || !_gemini.isReady) {
      return;
    }
    _scanStarted = true;
    _gemini.sendText(_gemini.startupScanPrompt);
    if (mounted) {
      setState(() {
        _status = 'Scan surroundings slowly...';
      });
    }
    _scanTimer?.cancel();
    _scanTimer = Timer(_scanDuration, _requestSceneSummary);
  }

  void _requestSceneSummary() {
    if (!_isActive || !_gemini.isReady) {
      return;
    }
    _summaryBuffer.clear();
    _awaitingSceneSummary = true;
    _gemini.sendText(_gemini.sceneSummaryPrompt);
    if (mounted) {
      setState(() {
        _status = 'Building scene summary...';
      });
    }
  }

  void _handleTurnComplete() {
    if (!_awaitingSceneSummary) {
      return;
    }
    _awaitingSceneSummary = false;
    final summary = _summaryBuffer.toString().trim();
    _summaryBuffer.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      if (summary.isNotEmpty) {
        _sceneSummary = summary;
      }
      _status = 'Listening...';
    });
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

  void _stopSession({bool updateUi = true}) {
    _scanTimer?.cancel();
    _scanTimer = null;
    _awaitingSceneSummary = false;
    _summaryBuffer.clear();
    unawaited(_stopFrameStream());
    _audio.stopRecording();
    _audio.clearPlayback();
    _gemini.disconnect();
    _cancelSubscriptions();

    if (updateUi && mounted) {
      setState(() {
        _isActive = false;
        _status = 'Tap to start';
      });
    } else {
      _isActive = false;
    }
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
            Text('apiKeyPresent=${geminiApiKey.trim().isNotEmpty}'),
            Text('audioSent=$_audioChunksSent audioReceived=$_audioChunksReceived'),
            Text('framesSent=$_framesSent stream=$_isStreamingFrames'),
            Text('zoom=${_zoomLevel.toStringAsFixed(2)}x'),
            if (_sceneSummary.isNotEmpty) Text('scene=$_sceneSummary'),
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
