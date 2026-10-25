// Idempotent helper that resizes + recompresses the two large brand PNGs
// (`splash_brand.png` and `login_hero.png`) so the asset bundle isn't 3 MB
// of high-res launcher artwork.
//
// Run from project root:
//   dart run tools/compress_brand_assets.dart
//
// First run snapshots the originals to `assets/_originals/<name>.png` so
// re-running doesn't progressively destroy quality.

import 'dart:io';

import 'package:image/image.dart' as img;

const int splashMaxSide = 1024;
const int loginHeroMaxSide = 700;
const int pngLevel = 9; // strongest deflate

Future<void> main() async {
  final assetsDir = Directory('assets');
  if (!assetsDir.existsSync()) {
    stderr.writeln('Run from project root.');
    exit(1);
  }
  final originals = Directory('assets/_originals');
  if (!originals.existsSync()) {
    originals.createSync(recursive: true);
  }

  await _compress(
    File('assets/splash_brand.png'),
    File('assets/_originals/splash_brand.png'),
    splashMaxSide,
  );
  await _compress(
    File('assets/login_hero.png'),
    File('assets/_originals/login_hero.png'),
    loginHeroMaxSide,
  );

  stdout.writeln('Done.');
}

Future<void> _compress(File target, File originalSnapshot, int maxSide) async {
  if (!target.existsSync()) {
    stderr.writeln('Missing: ${target.path}');
    return;
  }

  // Snapshot the original on first run.
  if (!originalSnapshot.existsSync()) {
    await target.copy(originalSnapshot.path);
    stdout.writeln('Snapshot saved: ${originalSnapshot.path}');
  }

  final source = img.decodeImage(await originalSnapshot.readAsBytes());
  if (source == null) {
    stderr.writeln('Failed to decode ${originalSnapshot.path}');
    return;
  }

  final longSide = source.width > source.height ? source.width : source.height;
  img.Image resized = source;
  if (longSide > maxSide) {
    final scale = maxSide / longSide;
    resized = img.copyResize(
      source,
      width: (source.width * scale).round(),
      height: (source.height * scale).round(),
      interpolation: img.Interpolation.cubic,
    );
  }

  final encoded = img.encodePng(resized, level: pngLevel);
  await target.writeAsBytes(encoded, flush: true);

  final origKb = (originalSnapshot.lengthSync() / 1024).toStringAsFixed(0);
  final newKb = (target.lengthSync() / 1024).toStringAsFixed(0);
  stdout.writeln(
    '${target.path}: $origKb KB → $newKb KB '
    '(${resized.width}×${resized.height})',
  );
}
