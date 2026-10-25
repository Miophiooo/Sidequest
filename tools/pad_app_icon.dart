// One-shot tool: pads `assets/app_icon.png` with a transparent border so the
// full SQ + SIDEQUEST text fits inside iOS's rounded-square icon mask and
// Android's adaptive-icon safe zone.
//
// Run from project root:
//   dart run tools/pad_app_icon.dart
//
// Writes:
//   assets/app_icon.png             (padded, used as iOS icon + Android legacy)
//   assets/app_icon_foreground.png  (padded slightly less, for Android adaptive)
//
// The original unpadded image is preserved at assets/app_icon_source.png
// the first time this script is run, so re-running is idempotent.

import 'dart:io';

import 'package:image/image.dart' as img;

// Tunables. iOS rounded-square clips ~5% on each side; we add 18% padding to
// keep the wordmark fully visible. Android adaptive needs 33% inset on the
// foreground layer (standard safe zone), but flutter_launcher_icons already
// handles part of that via `adaptive_icon_foreground_inset`, so we add 12%
// here and let the launcher add the rest.
const double iosPaddingFraction = 0.06;
const double androidForegroundPaddingFraction = 0.02;

Future<void> main() async {
  final assetsDir = Directory('assets');
  if (!assetsDir.existsSync()) {
    stderr.writeln('Run me from the project root (where pubspec.yaml lives).');
    exit(1);
  }

  final source = File('assets/app_icon_source.png');
  final iconFile = File('assets/app_icon.png');
  final foregroundFile = File('assets/app_icon_foreground.png');

  // First run: snapshot the original so we can re-pad without quality loss.
  if (!source.existsSync()) {
    if (!iconFile.existsSync()) {
      stderr.writeln('assets/app_icon.png not found.');
      exit(1);
    }
    await iconFile.copy(source.path);
    stdout.writeln('Snapshot saved: ${source.path}');
  }

  final bytes = await source.readAsBytes();
  final original = img.decodeImage(bytes);
  if (original == null) {
    stderr.writeln('Failed to decode ${source.path}');
    exit(1);
  }

  await _writePadded(
    original,
    iconFile,
    iosPaddingFraction,
    label: 'iOS / Android-legacy',
  );
  await _writePadded(
    original,
    foregroundFile,
    androidForegroundPaddingFraction,
    label: 'Android adaptive foreground',
  );

  stdout.writeln('Done. Now run:');
  stdout.writeln('  dart run flutter_launcher_icons');
}

Future<void> _writePadded(
  img.Image source,
  File outFile,
  double paddingFraction, {
  required String label,
}) async {
  final size = source.width > source.height ? source.width : source.height;
  final canvasSize = (size * (1.0 + paddingFraction * 2)).round();

  // Transparent canvas.
  final canvas = img.Image(
    width: canvasSize,
    height: canvasSize,
    numChannels: 4,
  );
  for (final p in canvas) {
    p.setRgba(0, 0, 0, 0);
  }

  // Center the source on the canvas.
  final dx = ((canvasSize - source.width) / 2).round();
  final dy = ((canvasSize - source.height) / 2).round();
  img.compositeImage(canvas, source, dstX: dx, dstY: dy);

  await outFile.writeAsBytes(img.encodePng(canvas), flush: true);
  stdout.writeln('Wrote ${outFile.path} ($canvasSize×$canvasSize) — $label');
}
