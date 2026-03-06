import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import '../services/audio_service.dart';
import '../services/gemini_live_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final GeminiLiveService _gemini = GeminiLiveService();
  final AudioService _audio = AudioService();

  CameraController? _camCtrl;
  Timer? _frameTimer;

  bool _isActive = false;
  bool _isCapturing = false;
  String _status = 'Tap to start';

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
    _stopSession();
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

  // ── Camera ─────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _camCtrl = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await _camCtrl!.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      setState(() => _status = 'Camera not available');
    }
  }

  // ── Permissions ────────────────────────────────────────────────────

  Future<bool> _requestPermissions() async {
    final camera = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    return camera.isGranted && mic.isGranted;
  }

  // ── Session control ────────────────────────────────────────────────

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
    });

    _cancelSubscriptions();

    _stateSub = _gemini.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        switch (s) {
          case GeminiConnectionState.connecting:
            _status = 'Connecting...';
          case GeminiConnectionState.ready:
            _status = 'Listening...';
          case GeminiConnectionState.error:
            _status = 'Connection error';
            _isActive = false;
          case GeminiConnectionState.disconnected:
            _status = 'Disconnected';
            _isActive = false;
        }
      });
    });

    _audioSub = _gemini.audioResponseStream.listen(_audio.addAudioChunk);

    _turnSub = _gemini.turnCompleteStream.listen((_) {
      _audio.onTurnComplete();
    });

    _textSub = _gemini.textResponseStream.listen((t) {
      debugPrint('Gemini: $t');
    });

    try {
      await _gemini.connect(geminiApiKey);

      await _audio.startRecording((data) {
        _gemini.sendAudio(data);
      });

      _startFrameCapture();
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Failed to connect';
          _isActive = false;
        });
      }
    }
  }

  void _startFrameCapture() {
    _frameTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_isActive || _isCapturing) return;
      if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;

      _isCapturing = true;
      try {
        final xFile = await _camCtrl!.takePicture();
        final bytes = await File(xFile.path).readAsBytes();
        _gemini.sendImage(bytes);
        try {
          await File(xFile.path).delete();
        } catch (_) {}
      } catch (_) {
        // skip frame
      } finally {
        _isCapturing = false;
      }
    });
  }

  void _stopSession() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _audio.stopRecording();
    _audio.clearPlayback();
    _gemini.disconnect();
    _cancelSubscriptions();

    if (mounted) {
      setState(() {
        _isActive = false;
        _status = 'Tap to start';
      });
    }
  }

  void _cancelSubscriptions() {
    _audioSub?.cancel();
    _textSub?.cancel();
    _turnSub?.cancel();
    _stateSub?.cancel();
  }

  // ── UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cameraReady =
        _camCtrl != null && _camCtrl!.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          if (cameraReady)
            CameraPreview(_camCtrl!)
          else
            const Center(child: CircularProgressIndicator()),

          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
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

          // Bottom controls
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
                  // Status
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

                  // Start / Stop button
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
