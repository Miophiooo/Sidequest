import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared.dart';
import 'app_logger.dart';

class UiErrorText {
  final String de;
  final String en;

  const UiErrorText(this.de, this.en);
}

class ErrorMapper {
  ErrorMapper._();

  static UiErrorText auth(AuthException e) {
    final message = e.message.toLowerCase();

    if (message.contains('invalid login credentials') ||
        message.contains('invalid_credentials')) {
      return const UiErrorText(
        'E-Mail oder Passwort ist falsch.',
        'Email or password is incorrect.',
      );
    }

    if (message.contains('email not confirmed')) {
      return const UiErrorText(
        'Bitte bestätige zuerst deine E-Mail-Adresse.',
        'Please confirm your email address first.',
      );
    }

    if (message.contains('password')) {
      return const UiErrorText(
        'Passwort erfüllt die Anforderungen nicht.',
        'Password does not meet the requirements.',
      );
    }

    if (message.contains('already registered') ||
        message.contains('user already registered')) {
      return const UiErrorText(
        'Diese E-Mail ist bereits registriert.',
        'This email is already registered.',
      );
    }

    if (message.contains('rate limit') || message.contains('too many')) {
      return const UiErrorText(
        'Zu viele Versuche. Warte kurz und versuch es dann nochmal.',
        'Too many attempts. Wait a moment and try again.',
      );
    }

    // No raw server text in the UI; it goes to the log.
    AppLogger.warn('Auth error: ${e.message}');
    return const UiErrorText(
      'Das hat nicht geklappt. Bitte versuch es nochmal.',
      "That didn't work. Please try again.",
    );
  }

  /// Server-side rate limit (internal.hit_rate_limit), e.g. too many messages
  /// or friend requests within an hour.
  static bool isRateLimited(Object e) =>
      e is PostgrestException && e.message.contains('rate_limited');

  static const UiErrorText rateLimited = UiErrorText(
    'Langsam! Du warst gerade sehr aktiv – versuch es später nochmal.',
    'Slow down! You have been very active – please try again later.',
  );

  /// Returns a safe generic message for unknown errors without leaking internals.
  static UiErrorText generic(Object e) {
    if (isRateLimited(e)) return rateLimited;
    if (isOffline(e)) return offline;
    return const UiErrorText(
      'Ein unerwarteter Fehler ist aufgetreten. Bitte versuche es erneut.',
      'An unexpected error occurred. Please try again.',
    );
  }

  static const UiErrorText offline = UiErrorText(
    'Keine Verbindung. Prüfe dein Internet und versuche es erneut.',
    'No connection. Check your internet and try again.',
  );

  /// Network failures (string check, so this also compiles for web where
  /// dart:io's SocketException doesn't exist).
  static bool isOffline(Object e) {
    final text = e.toString();
    return text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Network is unreachable') ||
        text.contains('Connection closed') ||
        text.contains('Connection refused') ||
        text.contains('TimeoutException');
  }

  /// Localized text for a snackbar: what failed (optional) plus a hint, but
  /// never the raw exception. The exception itself goes to the log.
  static String describe(Object e, {String? whatDe, String? whatEn}) {
    AppLogger.warn('UI error: $e');
    final hint = generic(e);
    if (whatDe == null || whatEn == null) return t(hint.de, hint.en);
    if (isRateLimited(e) || isOffline(e)) {
      return t('$whatDe. ${hint.de}', '$whatEn. ${hint.en}');
    }
    return t(
      '$whatDe. Bitte versuche es erneut.',
      '$whatEn. Please try again.',
    );
  }
}
