import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'core/app_logger.dart';

/// Compresses an image on disk in-place by reading the source file, resizing
/// it so that its longest side is at most [maxDimension] pixels, and re-
/// encoding it as JPEG with the given [quality]. Returns a [File] pointing
/// at a temp file containing the compressed bytes.
///
/// Why: Supabase Free plan has a tight 5 GB/month egress budget. Uploading
/// an unmodified 4032×3024 phone photo (~3-6 MB) blows that budget after
/// only a few hundred views. A 1080-px JPEG at quality 80 looks
/// indistinguishable on a phone screen and is typically 10-20× smaller.
///
/// Falls back to the original file if anything goes wrong (decode error,
/// unsupported format) — never throws, never blocks the upload.
Future<File> compressImageForUpload(
  String inputPath, {
  int maxDimension = 1080,
  int quality = 80,
}) async {
  final source = File(inputPath);
  try {
    if (!await source.exists()) return source;

    final bytes = await source.readAsBytes();
    // Decode runs on the main isolate; image package is fast enough for
    // single-photo flows (<150ms on a typical phone for a 4K image). If we
    // ever need to compress in batch, move this to compute().
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return source;

    final longestSide = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;

    img.Image processed = decoded;
    if (longestSide > maxDimension) {
      // Use linear interpolation: crisp enough at this scale, ~3× faster
      // than cubic.
      processed = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? maxDimension : null,
        height: decoded.height > decoded.width ? maxDimension : null,
        interpolation: img.Interpolation.linear,
      );
    }

    final encoded = img.encodeJpg(processed, quality: quality);

    // Only swap if we actually saved bytes — avoids the case where a tiny
    // already-compressed image gets recompressed and grows.
    if (encoded.length >= bytes.length && longestSide <= maxDimension) {
      return source;
    }

    final outPath =
        '${Directory.systemTemp.path}/sq_upload_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final outFile = File(outPath);
    await outFile.writeAsBytes(encoded, flush: true);

    if (kDebugMode) {
      final ratio = (encoded.length * 100 / bytes.length).round();
      AppLogger.info(
        'Image compressed: ${bytes.length ~/ 1024} KB → '
        '${encoded.length ~/ 1024} KB ($ratio%)',
      );
    }

    return outFile;
  } catch (e) {
    AppLogger.warn('compressImageForUpload failed, using original: $e');
    return source;
  }
}

/// Compression preset for profile avatars. Tiny output (~20-40 KB).
Future<File> compressAvatarForUpload(String inputPath) {
  return compressImageForUpload(
    inputPath,
    maxDimension: 512,
    quality: 80,
  );
}

/// Compression preset for feed/chat photos. Phone-screen quality (~150-300 KB).
Future<File> compressPhotoForUpload(String inputPath) {
  return compressImageForUpload(
    inputPath,
    maxDimension: 1080,
    quality: 80,
  );
}
