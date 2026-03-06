import 'dart:async';
import 'dart:io';

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
  static const _frameCadence = Duration(milliseconds: 400);

  final GeminiLiveService _gemini = GeminiLiveService();
  final AudioService _audio = AudioService();
  final FrameSendScheduler<CameraImage> _frameScheduler =
      FrameSendScheduler(minInterval: _frameCadence);

  CameraController? _camCtrl;
  Timer? _frameTickTimer;
  Timer? _fallbackFrameTimer;

  bool _isActive = false;
  bool _isStreamingFrames = false;
  String _status = 'Tap to start';
  String _partialTranscript = '';
  final List<String> _transcriptHistory = [];

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
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.android
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _camCtrl!.initialize();
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Camera not available');
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
      setState(() => _status = 'Permissions denied');
      return;
    }

    setState(() {
      _status = 'Connecting...';
      _isActive = true;
      _partialTranscript = '';
      _transcriptHistory.clear();
    });

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
            break;
          case GeminiConnectionState.disconnected:
            _status = 'Disconnected';
            _isActive = false;
            break;
        }
      });
    });

    _audioSub = _gemini.audioResponseStream.listen(_audio.addAudioChunk);

    _turnSub = _gemini.turnCompleteStream.listen((_) {
      _audio.onTurnComplete();
      if (_partialTranscript.trim().isEmpty || !mounted) {
        return;
      }
      setState(() {
        _transcriptHistory.insert(0, _partialTranscript.trim());
        if (_transcriptHistory.length > 4) {
          _transcriptHistory.removeLast();
        }
        _partialTranscript = '';
      });
    });

    _textSub = _gemini.outputTranscriptStream.listen((event) {
      if (event.type != GeminiTranscriptType.outputAudio || !mounted) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _partialTranscript = event.text;
      });
    });

    try {
      await _gemini.connect(geminiApiKey);
      await _audio.startRecording((data) {
        if (_audio.hasPendingPlayback && _looksLikeUserSpeech(data)) {
          _audio.clearPlayback();
        }
        _gemini.sendAudio(data);
      });
      await _startVisualFeed();
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'Failed to connect';
          _isActive = false;
        });
      }
    }
  }

  Future<void> _startVisualFeed() async {
    final controller = _camCtrl;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await controller.startImageStream((image) {
          _frameScheduler.push(image);
        });
        _isStreamingFrames = true;
        _frameTickTimer?.cancel();
        _frameTickTimer = Timer.periodic(_frameCadence, (_) {
          unawaited(_frameScheduler.dispatchLatest((image) async {
            if (!_isActive) {
              return;
            }
            final jpegBytes = await encodeCameraImageToJpeg(image);
            if (jpegBytes != null && _isActive) {
              _gemini.sendImage(jpegBytes);
            }
          }));
        });
        return;
      } catch (_) {
        _isStreamingFrames = false;
      }
    }

    _startFallbackFrameCapture();
  }

  void _startFallbackFrameCapture() {
    _fallbackFrameTimer?.cancel();
    _fallbackFrameTimer = Timer.periodic(_frameCadence, (_) async {
      if (!_isActive) {
        return;
      }
      final controller = _camCtrl;
      if (controller == null || !controller.value.isInitialized) {
        return;
      }

      try {
        final file = await controller.takePicture();
        final bytes = await File(file.path).readAsBytes();
        _gemini.sendImage(bytes);
        try {
          await File(file.path).delete();
        } catch (_) {}
      } catch (_) {
        // Ignore frame capture failures and keep the session alive.
      }
    });
  }

  bool _looksLikeUserSpeech(Uint8List pcmData) {
    if (pcmData.length < 2) {
      return false;
    }

    var peak = 0;
    final data = ByteData.sublistView(pcmData);
    for (var i = 0; i <= pcmData.length - 2; i += 2) {
      final sample = data.getInt16(i, Endian.little).abs();
      if (sample > peak) {
        peak = sample;
      }
    }

    return peak > 5000;
  }

  void _stopSession({bool updateUi = true}) {
    _frameTickTimer?.cancel();
    _frameTickTimer = null;
    _fallbackFrameTimer?.cancel();
    _fallbackFrameTimer = null;
    _frameScheduler.clear();
    _audio.stopRecording();
    _audio.clearPlayback();
    _gemini.disconnect();
    _cancelSubscriptions();

    final controller = _camCtrl;
    if (_isStreamingFrames && controller != null) {
      _isStreamingFrames = false;
      unawaited(controller.stopImageStream());
    }

    if (updateUi && mounted) {
      setState(() {
        _isActive = false;
        _status = 'Tap to start';
        _partialTranscript = '';
      });
    } else {
      _isActive = false;
      _partialTranscript = '';
    }
  }

  void _cancelSubscriptions() {
    _audioSub?.cancel();
    _textSub?.cancel();
    _turnSub?.cancel();
    _stateSub?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final cameraReady = _camCtrl != null && _camCtrl!.value.isInitialized;
    final transcriptLines = [
      if (_partialTranscript.trim().isNotEmpty) _partialTranscript.trim(),
      ..._transcriptHistory,
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (cameraReady)
            CameraPreview(_camCtrl!)
          else
            const Center(child: CircularProgressIndicator()),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'AEyes',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
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
                    Colors.black.withAlpha(200),
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(24, 60, 24, 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (transcriptLines.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 20),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(170),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: transcriptLines
                            .map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  line,
                                  style: TextStyle(
                                    color: line == _partialTranscript.trim()
                                        ? Colors.white
                                        : Colors.white70,
                                    fontSize: 14,
                                    fontWeight: line == _partialTranscript.trim()
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    label: _isActive
                        ? 'Stop AEyes assistant'
                        : 'Start AEyes assistant',
                    button: true,
                    child: GestureDetector(
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
                          boxShadow: _isActive
                              ? [
                                  BoxShadow(
                                    color: Colors.red.withAlpha(100),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  )
                                ]
                              : null,
                        ),
                        child: Icon(
                          _isActive
                              ? Icons.stop_rounded
                              : Icons.visibility,
                          color: Colors.white,
                          size: 40,
                        ),
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
