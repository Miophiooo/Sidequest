import 'dart:io';

/// Maximum size of a picked or captured image *before* compression (25 MB,
/// the limit of the photos bucket). Uploads are compressed to a few hundred
/// KB first; a 10 MB limit here rejected normal 48 MP camera photos.
const int maxImageBytes = 25 * 1024 * 1024;

/// MIME magic bytes for accepted image formats.
const List<List<int>> _jpegMagic = [
  [0xFF, 0xD8, 0xFF],
];
const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47];

enum ImageValidationError { tooLarge, unsupportedFormat }

class ImageValidationResult {
  final bool isValid;
  final ImageValidationError? error;
  const ImageValidationResult._(this.isValid, this.error);
  const ImageValidationResult.ok() : this._(true, null);
  const ImageValidationResult.fail(ImageValidationError e) : this._(false, e);
}

/// Validates that [path] points to an acceptable image file.
///
/// Checks file size (≤ [maxImageBytes]) and magic-byte header to ensure the
/// file is actually a JPEG or PNG.
Future<ImageValidationResult> validateImageFile(String path) async {
  final file = File(path);
  final length = await file.length();
  if (length > maxImageBytes) {
    return const ImageValidationResult.fail(ImageValidationError.tooLarge);
  }

  final raf = await file.open(mode: FileMode.read);
  try {
    final header = await raf.read(4);
    if (header.length < 3) {
      return const ImageValidationResult.fail(
        ImageValidationError.unsupportedFormat,
      );
    }

    final isJpeg = _jpegMagic.any(
      (m) => header.length >= m.length &&
          List.generate(m.length, (i) => header[i] == m[i]).every((v) => v),
    );
    final isPng = header.length >= _pngMagic.length &&
        List.generate(_pngMagic.length, (i) => header[i] == _pngMagic[i])
            .every((v) => v);

    if (!isJpeg && !isPng) {
      return const ImageValidationResult.fail(
        ImageValidationError.unsupportedFormat,
      );
    }
  } finally {
    await raf.close();
  }

  return const ImageValidationResult.ok();
}
