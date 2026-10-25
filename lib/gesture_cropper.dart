import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'core/app_logger.dart';
import 'shared.dart';

enum GestureCropShape { circle, rect }

// Runs heavy PNG→JPG encode off the main thread to avoid UI jank.
Uint8List _encodeToJpgIsolate(Map<String, dynamic> args) {
  final pngBytes = args['pngBytes'] as Uint8List;
  final quality = args['quality'] as int;
  final decoded = img.decodeImage(pngBytes);
  if (decoded == null) return Uint8List(0);
  return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
}

class GestureCropperScreen extends StatefulWidget {
  final String sourcePath;
  final String title;
  final String cancelLabel;
  final String confirmLabel;
  final GestureCropShape cropShape;
  final double? aspectRatio;
  final int exportLongSide;
  final int jpegQuality;
  final double cropPadding;
  final Radius rectRadius;

  const GestureCropperScreen({
    super.key,
    required this.sourcePath,
    required this.title,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.cropShape,
    this.aspectRatio,
    this.exportLongSide = 1440,
    this.jpegQuality = 92,
    this.cropPadding = 24,
    this.rectRadius = const Radius.circular(22),
  });

  factory GestureCropperScreen.profile({
    required String sourcePath,
    required String title,
    required String cancelLabel,
    required String confirmLabel,
  }) {
    return GestureCropperScreen(
      sourcePath: sourcePath,
      title: title,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      cropShape: GestureCropShape.circle,
      aspectRatio: 1,
      exportLongSide: 1080,
      jpegQuality: 90,
    );
  }

  factory GestureCropperScreen.combo({
    required String sourcePath,
    required String title,
    required String cancelLabel,
    required String confirmLabel,
  }) {
    return GestureCropperScreen(
      sourcePath: sourcePath,
      title: title,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      cropShape: GestureCropShape.rect,
      exportLongSide: 1600,
      jpegQuality: 92,
    );
  }

  @override
  State<GestureCropperScreen> createState() => _GestureCropperScreenState();
}

class _GestureCropperScreenState extends State<GestureCropperScreen> {
  ui.Image? _sourceImage;
  Matrix4 _matrix = Matrix4.identity();
  Matrix4 _sessionMatrix = Matrix4.identity();
  Offset _initialFocalPoint = Offset.zero;
  Size? _viewSize;
  Size? _clipSize;
  Matrix4? _exportMatrix;
  bool _loading = true;
  bool _exporting = false;

  void _failCrop([String? message]) {
    if (!mounted) return;
    setState(() => _exporting = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          message ??
              t(
                'Zuschneiden fehlgeschlagen. Bitte nochmal probieren.',
                'Cropping failed. Please try again.',
              ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _sourceImage?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final originalWidth = descriptor.width;
      final originalHeight = descriptor.height;
      final maxDecodeLongSide = math.max(widget.exportLongSide * 2, 1800);
      final originalLongSide = math.max(originalWidth, originalHeight);
      final downscale = originalLongSide > maxDecodeLongSide
          ? maxDecodeLongSide / originalLongSide
          : 1.0;
      final targetWidth = math.max(1, (originalWidth * downscale).round());
      final targetHeight = math.max(1, (originalHeight * downscale).round());
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _sourceImage = frame.image;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  double get _cropAspectRatio {
    if (widget.cropShape == GestureCropShape.circle) return 1;
    if (widget.aspectRatio != null && widget.aspectRatio! > 0) {
      return widget.aspectRatio!;
    }
    final image = _sourceImage;
    if (image == null || image.height == 0) return 3 / 4;
    return image.width / image.height;
  }

  Size _calculateCropSize(Size availableSize) {
    final inset = widget.cropPadding * 2;
    final maxWidth = math.max(0.0, availableSize.width - inset);
    final maxHeight = math.max(0.0, availableSize.height - inset);
    final aspectRatio = _cropAspectRatio;

    var width = maxWidth;
    var height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }
    return Size(width, height);
  }

  Matrix4 _layoutImage(Size imageSize, Size clipSize, BoxFit fit) {
    final matrix = Matrix4.identity();
    var scale = 1.0;

    if (fit == BoxFit.contain) {
      if (imageSize.aspectRatio > clipSize.aspectRatio) {
        scale = clipSize.width / imageSize.width;
      } else {
        scale = clipSize.height / imageSize.height;
      }
    } else {
      if (imageSize.aspectRatio > clipSize.aspectRatio) {
        scale = clipSize.height / imageSize.height;
      } else {
        scale = clipSize.width / imageSize.width;
      }
    }

    matrix.scaleByDouble(scale, scale, 1, 1);
    matrix.translateByDouble(-imageSize.width / 2, -imageSize.height / 2, 0, 1);
    return matrix;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _initialFocalPoint = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final viewSize = _viewSize;
    if (viewSize == null) return;

    final center = viewSize.center(Offset.zero);
    final focal = details.localFocalPoint.translate(-center.dx, -center.dy);
    final focalDelta = details.focalPoint - _initialFocalPoint;

    setState(() {
      _sessionMatrix = Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(details.scale, details.scale, 1, 1)
        ..rotateZ(details.rotation)
        ..translateByDouble(focalDelta.dx, focalDelta.dy, 0, 1)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    setState(() {
      _matrix = _sessionMatrix * _matrix;
      _sessionMatrix = Matrix4.identity();
    });
  }

  Size _exportSize() {
    if (widget.cropShape == GestureCropShape.circle) {
      return Size.square(widget.exportLongSide.toDouble());
    }

    final aspectRatio = _cropAspectRatio;
    if (aspectRatio >= 1) {
      final width = widget.exportLongSide.toDouble();
      return Size(width, width / aspectRatio);
    }

    final height = widget.exportLongSide.toDouble();
    return Size(height * aspectRatio, height);
  }

  Future<void> _finishCrop() async {
    final image = _sourceImage;
    final clipSize = _clipSize;
    final exportMatrix = _exportMatrix;
    if (image == null || clipSize == null || exportMatrix == null) {
      _failCrop();
      return;
    }

    setState(() => _exporting = true);
    try {
      final exportSize = _exportSize();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final exportRect = Rect.fromLTWH(
        0,
        0,
        exportSize.width,
        exportSize.height,
      );

      canvas.drawRect(exportRect, Paint()..color = Colors.black);
      final exportScale = exportSize.width / clipSize.width;
      canvas.scale(exportScale);
      canvas.translate(clipSize.width / 2, clipSize.height / 2);
      canvas.transform(exportMatrix.storage);
      canvas.drawImage(image, Offset.zero, Paint());

      final rendered = await recorder.endRecording().toImage(
        exportSize.width.round(),
        exportSize.height.round(),
      );
      try {
        final pngBytes = await rendered.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (pngBytes == null) {
          _failCrop();
          return;
        }

        // Run heavy decode+encode in a separate isolate to keep UI responsive.
        final jpgBytes = await compute(_encodeToJpgIsolate, {
          'pngBytes': Uint8List.view(pngBytes.buffer),
          'quality': widget.jpegQuality,
        });
        if (jpgBytes.isEmpty) {
          _failCrop();
          return;
        }
        final separator = Platform.pathSeparator;
        final output = File(
          '${Directory.systemTemp.path}${separator}crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
        );
        await output.writeAsBytes(jpgBytes, flush: true);
        if (!mounted) return;
        Navigator.of(context).pop(output);
      } finally {
        rendered.dispose();
      }
    } catch (error) {
      AppLogger.debug('Gesture crop failed: $error');
      _failCrop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _sourceImage;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _exporting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(
                      widget.cancelLabel,
                      style: TextStyle(
                        color: _exporting ? Colors.white38 : Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: (_exporting || image == null) ? null : _finishCrop,
                    child: SizedBox(
                      width: 72,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                widget.confirmLabel,
                                style: TextStyle(
                                  color: image == null
                                      ? Colors.white38
                                      : Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewSize = constraints.biggest;
                  _viewSize = viewSize;

                  if (_loading) {
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  if (image == null) {
                    return Center(
                      child: Text(
                        t(
                          'Bild konnte nicht geladen werden',
                          'Could not load image',
                        ),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    );
                  }

                  final clipSize = _calculateCropSize(viewSize);
                  final layoutMatrix = _layoutImage(
                    Size(image.width.toDouble(), image.height.toDouble()),
                    clipSize,
                    BoxFit.cover,
                  );
                  final exportMatrix = _sessionMatrix * _matrix * layoutMatrix;
                  _clipSize = clipSize;
                  _exportMatrix = exportMatrix;

                  final cropRect = Rect.fromCenter(
                    center: viewSize.center(Offset.zero),
                    width: clipSize.width,
                    height: clipSize.height,
                  );

                  return GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          left: viewSize.width / 2,
                          top: viewSize.height / 2,
                          child: Transform(
                            transform: exportMatrix,
                            alignment: Alignment.topLeft,
                            child: RawImage(
                              image: image,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: ClipPath(
                            clipper: _CropOverlayClipper(
                              cropRect: cropRect,
                              shape: widget.cropShape,
                              radius: widget.rectRadius,
                            ),
                            child: Container(color: Colors.black54),
                          ),
                        ),
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _CropFramePainter(
                              cropRect: cropRect,
                              shape: widget.cropShape,
                              radius: widget.rectRadius,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 24,
                          child: Text(
                            widget.cropShape == GestureCropShape.circle
                                ? t(
                                    'Bewegen, skalieren, drehen',
                                    'Move, scale, rotate',
                                  )
                                : t(
                                    'Bewegen, skalieren, drehen',
                                    'Move, scale, rotate',
                                  ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.78),
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropOverlayClipper extends CustomClipper<Path> {
  final Rect cropRect;
  final GestureCropShape shape;
  final Radius radius;

  _CropOverlayClipper({
    required this.cropRect,
    required this.shape,
    required this.radius,
  });

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final hole = Path();
    if (shape == GestureCropShape.circle) {
      hole.addOval(cropRect);
    } else {
      hole.addRRect(RRect.fromRectAndRadius(cropRect, radius));
    }
    return Path.combine(PathOperation.difference, full, hole);
  }

  @override
  bool shouldReclip(covariant _CropOverlayClipper oldClipper) {
    return oldClipper.cropRect != cropRect ||
        oldClipper.shape != shape ||
        oldClipper.radius != radius;
  }
}

class _CropFramePainter extends CustomPainter {
  final Rect cropRect;
  final GestureCropShape shape;
  final Radius radius;

  _CropFramePainter({
    required this.cropRect,
    required this.shape,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    if (shape == GestureCropShape.circle) {
      canvas.drawOval(cropRect, borderPaint);
    } else {
      final rrect = RRect.fromRectAndRadius(cropRect, radius);
      canvas.drawRRect(rrect, borderPaint);
    }

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    final thirdWidth = cropRect.width / 3;
    final thirdHeight = cropRect.height / 3;

    for (var i = 1; i <= 2; i++) {
      final dx = cropRect.left + thirdWidth * i;
      final dy = cropRect.top + thirdHeight * i;
      canvas.drawLine(
        Offset(dx, cropRect.top),
        Offset(dx, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, dy),
        Offset(cropRect.right, dy),
        gridPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropFramePainter oldDelegate) {
    return oldDelegate.cropRect != cropRect ||
        oldDelegate.shape != shape ||
        oldDelegate.radius != radius;
  }
}
