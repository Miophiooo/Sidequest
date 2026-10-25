import 'package:flutter/foundation.dart';

import 'app_environment.dart';

/// Regex matching long base64-ish tokens (JWT, FCM tokens, etc.) so they
/// are never printed in release logs.
final RegExp _tokenPattern = RegExp(r'[A-Za-z0-9_\-]{40,}');

/// Replace long token-like strings with a redacted placeholder.
String _redactTokens(String message) {
  if (!kReleaseMode) return message;
  return message.replaceAll(_tokenPattern, '[REDACTED]');
}

class AppLogger {
  AppLogger._();

  static bool get _allowDebugLogs =>
      !kReleaseMode || AppEnvironment.verboseLogs;

  static void debug(String message) {
    if (_allowDebugLogs) {
      debugPrint('[DEBUG] ${_redactTokens(message)}');
    }
  }

  static void info(String message) {
    if (_allowDebugLogs) {
      debugPrint('[INFO] ${_redactTokens(message)}');
    }
  }

  static void warn(String message) {
    if (_allowDebugLogs) {
      debugPrint('[WARN] ${_redactTokens(message)}');
    }
  }

  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('[ERROR] ${_redactTokens(message)}');
    if (error != null && _allowDebugLogs) {
      debugPrint('[ERROR] cause: ${_redactTokens(error.toString())}');
    }
    if (stackTrace != null && _allowDebugLogs) {
      debugPrint(stackTrace.toString());
    }
  }
}
