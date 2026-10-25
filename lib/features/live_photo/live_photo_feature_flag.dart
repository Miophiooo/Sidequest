import 'package:flutter/foundation.dart';

bool get sideQuestLivePhotoCaptureEnabled {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
