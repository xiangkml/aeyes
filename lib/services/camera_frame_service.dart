import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class FrameSendScheduler<T> {
  FrameSendScheduler({
    required this.minInterval,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration minInterval;
  final DateTime Function() _now;

  T? _latest;
  bool _isBusy = false;
  DateTime? _lastDispatchAt;

  bool get hasPendingFrame => _latest != null;
  bool get isBusy => _isBusy;

  void push(T value) {
    _latest = value;
  }

  void clear() {
    _latest = null;
  }

  Future<bool> dispatchLatest(Future<void> Function(T value) send) async {
    if (_isBusy || _latest == null) {
      return false;
    }

    final now = _now();
    if (_lastDispatchAt != null &&
        now.difference(_lastDispatchAt!) < minInterval) {
      return false;
    }

    final value = _latest as T;
    _latest = null;
    _isBusy = true;
    _lastDispatchAt = now;

    try {
      await send(value);
      return true;
    } finally {
      _isBusy = false;
    }
  }
}

class RawCameraFrame {
  RawCameraFrame({
    required this.width,
    required this.height,
    required this.formatGroup,
    required this.planeBytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  factory RawCameraFrame.fromCameraImage(CameraImage image) {
    return RawCameraFrame(
      width: image.width,
      height: image.height,
      formatGroup: image.format.group.name,
      planeBytes: image.planes.map((plane) => Uint8List.fromList(plane.bytes)).toList(),
      bytesPerRow: image.planes.map((plane) => plane.bytesPerRow).toList(),
      bytesPerPixel: image.planes.map((plane) => plane.bytesPerPixel).toList(),
    );
  }

  final int width;
  final int height;
  final String formatGroup;
  final List<Uint8List> planeBytes;
  final List<int> bytesPerRow;
  final List<int?> bytesPerPixel;
}

class EncodeFrameRequest {
  EncodeFrameRequest({
    required this.frame,
    required this.maxWidth,
    required this.quality,
  });

  final RawCameraFrame frame;
  final int maxWidth;
  final int quality;
}

Future<Uint8List?> encodeCameraImageToJpeg(
  CameraImage image, {
  int maxWidth = 640,
  int quality = 70,
}) {
  final request = EncodeFrameRequest(
    frame: RawCameraFrame.fromCameraImage(image),
    maxWidth: maxWidth,
    quality: quality,
  );
  return compute(_encodeFrameToJpeg, request);
}

Uint8List? _encodeFrameToJpeg(EncodeFrameRequest request) {
  final frame = request.frame;
  if (frame.planeBytes.isEmpty) {
    return null;
  }

  final scale = frame.width > request.maxWidth
      ? request.maxWidth / frame.width
      : 1.0;
  final targetWidth = (frame.width * scale).round().clamp(1, frame.width);
  final targetHeight = (frame.height * scale).round().clamp(1, frame.height);
  final image = img.Image(width: targetWidth, height: targetHeight);

  for (var y = 0; y < targetHeight; y++) {
    final sourceY = (y * frame.height / targetHeight).floor();
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = (x * frame.width / targetWidth).floor();
      final rgb = _readPixel(frame, sourceX, sourceY);
      image.setPixelRgb(x, y, rgb.$1, rgb.$2, rgb.$3);
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: request.quality));
}

(int, int, int) _readPixel(RawCameraFrame frame, int x, int y) {
  switch (frame.formatGroup) {
    case 'nv21':
      return _readNv21(frame, x, y);
    case 'yuv420':
      return _readYuv420(frame, x, y);
    case 'bgra8888':
      return _readBgra8888(frame, x, y);
    default:
      return (0, 0, 0);
  }
}

(int, int, int) _readNv21(RawCameraFrame frame, int x, int y) {
  if (frame.planeBytes.length == 1) {
    final bytes = frame.planeBytes.first;
    final frameSize = frame.width * frame.height;
    final yValue = bytes[y * frame.width + x];
    final chromaIndex =
        frameSize + (y ~/ 2) * frame.width + (x & ~1);
    final v = bytes[chromaIndex];
    final u = bytes[chromaIndex + 1];
    return _yuvToRgb(yValue, u, v);
  }

  return _readYuv420(frame, x, y);
}

(int, int, int) _readYuv420(RawCameraFrame frame, int x, int y) {
  if (frame.planeBytes.length < 3) {
    return (0, 0, 0);
  }

  final yPlane = frame.planeBytes[0];
  final uPlane = frame.planeBytes[1];
  final vPlane = frame.planeBytes[2];

  final yRowStride = frame.bytesPerRow[0];
  final uRowStride = frame.bytesPerRow[1];
  final vRowStride = frame.bytesPerRow[2];
  final uPixelStride = frame.bytesPerPixel[1] ?? 1;
  final vPixelStride = frame.bytesPerPixel[2] ?? 1;

  final yValue = yPlane[y * yRowStride + x];
  final uvX = x ~/ 2;
  final uvY = y ~/ 2;
  final uValue = uPlane[uvY * uRowStride + uvX * uPixelStride];
  final vValue = vPlane[uvY * vRowStride + uvX * vPixelStride];

  return _yuvToRgb(yValue, uValue, vValue);
}

(int, int, int) _readBgra8888(RawCameraFrame frame, int x, int y) {
  final bytes = frame.planeBytes.first;
  final rowStride = frame.bytesPerRow.first;
  final index = y * rowStride + x * 4;
  final b = bytes[index];
  final g = bytes[index + 1];
  final r = bytes[index + 2];
  return (r, g, b);
}

(int, int, int) _yuvToRgb(int y, int u, int v) {
  final yValue = (y - 16).clamp(0, 255);
  final uValue = u - 128;
  final vValue = v - 128;

  final r = ((298 * yValue + 409 * vValue + 128) >> 8).clamp(0, 255);
  final g = ((298 * yValue - 100 * uValue - 208 * vValue + 128) >> 8)
      .clamp(0, 255);
  final b = ((298 * yValue + 516 * uValue + 128) >> 8).clamp(0, 255);
  return (r, g, b);
}
