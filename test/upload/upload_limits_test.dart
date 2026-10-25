import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/live_photo/live_photo_models.dart';
import 'package:nummwe3/features/live_photo/live_photo_upload_service.dart';
import 'package:nummwe3/image_validation.dart';

Future<File> _jpegOfSize(Directory dir, String name, int bytes) async {
  final file = File('${dir.path}/$name');
  final raf = await file.open(mode: FileMode.write);
  await raf.writeFrom([0xFF, 0xD8, 0xFF, 0xE0]);
  await raf.setPosition(bytes - 1);
  await raf.writeByte(0);
  await raf.close();
  return file;
}

LivePhotoCaptureResult _capture({
  required int taken,
  required int clipStart,
  int duration = 3000,
}) {
  return LivePhotoCaptureResult(
    sessionId: 's',
    photoPath: 'p.jpg',
    clipPath: 'c.mp4',
    photoTakenAtEpochMs: taken,
    clipStartEpochMs: clipStart,
    clipDurationMs: duration,
    videoWidth: 1080,
    videoHeight: 1920,
    videoFps: 30,
    didFallbackToLatencyMode: false,
  );
}

void main() {
  group('validateImageFile', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('sq_img'));
    tearDown(() => dir.delete(recursive: true));

    test('accepts a 15 MB camera photo (compressed before upload)', () async {
      final file = await _jpegOfSize(dir, 'big.jpg', 15 * 1024 * 1024);
      expect((await validateImageFile(file.path)).isValid, isTrue);
    });

    test('rejects files above the bucket limit', () async {
      final file = await _jpegOfSize(dir, 'huge.jpg', maxImageBytes + 1);
      final result = await validateImageFile(file.path);
      expect(result.isValid, isFalse);
      expect(result.error, ImageValidationError.tooLarge);
    });
  });

  group('LivePhotoUploadService.preCaptureMsFor', () {
    test('uses the offset of the still inside the clip', () {
      expect(
        LivePhotoUploadService.preCaptureMsFor(
          _capture(taken: 12000, clipStart: 10500),
        ),
        1500,
      );
    });

    test('falls back to the clip length for unusable timestamps', () {
      expect(
        LivePhotoUploadService.preCaptureMsFor(
          _capture(taken: 12000, clipStart: 0),
        ),
        3000,
      );
      expect(
        LivePhotoUploadService.preCaptureMsFor(
          _capture(taken: 9000, clipStart: 10000),
        ),
        3000,
      );
      expect(
        LivePhotoUploadService.preCaptureMsFor(
          _capture(taken: 20000, clipStart: 10000),
        ),
        3000,
      );
    });
  });
}
