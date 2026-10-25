import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// Crash reports (Firebase Crashlytics). Collection is disabled natively by
/// default (AndroidManifest meta-data / Info.plist) and switched on together
/// with the usage statistics consent, see AnalyticsConsent. No user id is
/// attached to the reports.
class CrashReporting {
  CrashReporting._();

  static bool get _available =>
      !kIsWeb && !kDebugMode && Firebase.apps.isNotEmpty;

  static Future<void> setEnabled(bool enabled) async {
    if (!_available) return;
    try {
      final crashlytics = FirebaseCrashlytics.instance;
      await crashlytics.setCrashlyticsCollectionEnabled(enabled);
      if (!enabled) {
        await crashlytics.deleteUnsentReports();
      }
    } catch (e) {
      AppLogger.warn('Applying crash reporting consent failed: $e');
    }
  }

  /// Safe to call before Firebase is initialized (then it does nothing).
  static void recordFlutterError(FlutterErrorDetails details) {
    if (!_available) return;
    try {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    } catch (_) {}
  }

  static void recordError(
    Object error,
    StackTrace? stack, {
    bool fatal = false,
  }) {
    if (!_available) return;
    try {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: fatal);
    } catch (_) {}
  }
}
