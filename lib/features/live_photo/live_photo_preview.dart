import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LivePhotoPreview extends StatelessWidget {
  final String sessionId;
  final BoxFit fit;

  const LivePhotoPreview({
    super.key,
    required this.sessionId,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object?>{
      'sessionId': sessionId,
      'fit': fit.name,
    };

    if (Platform.isIOS) {
      return UiKitView(
        viewType: 'sidequest/live_photo/preview',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    if (Platform.isAndroid) {
      return AndroidView(
        viewType: 'sidequest/live_photo/preview',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return const ColoredBox(
      color: Color(0xFF111111),
      child: Center(
        child: Text(
          'Live camera preview unavailable on this platform.',
          style: TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
