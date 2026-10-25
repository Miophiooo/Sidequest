import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared.dart';
import 'app_logger.dart';
import 'crash_reporting.dart';

/// Usage analytics (Firebase Analytics) and crash reports (Crashlytics) only
/// run after the user opted in.
///
/// Collection is disabled natively by default (AndroidManifest meta-data and
/// Info.plist), so nothing is sent before a decision. Ad-related storage is
/// never granted: the app shows no ads.
class AnalyticsConsent {
  AnalyticsConsent._();

  static const _prefsKey = 'analytics_consent_v1';

  /// null = not decided yet.
  static final ValueNotifier<bool?> granted = ValueNotifier<bool?>(null);
  static bool _loaded = false;

  static Future<bool?> load() async {
    if (_loaded) return granted.value;
    try {
      final prefs = await SharedPreferences.getInstance();
      granted.value = prefs.getBool(_prefsKey);
    } catch (_) {}
    _loaded = true;
    return granted.value;
  }

  /// Applies the stored decision to Firebase. Call after Firebase is
  /// initialized.
  static Future<void> apply() async {
    final value = await load();
    await _applyToFirebase(value == true);
  }

  static Future<void> set(bool value) async {
    granted.value = value;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {}
    await _applyToFirebase(value);
  }

  static Future<void> _applyToFirebase(bool enabled) async {
    if (kIsWeb) return;
    await CrashReporting.setEnabled(enabled);
    try {
      final analytics = FirebaseAnalytics.instance;
      await analytics.setConsent(
        analyticsStorageConsentGranted: enabled,
        adStorageConsentGranted: false,
        adUserDataConsentGranted: false,
        adPersonalizationSignalsConsentGranted: false,
      );
      await analytics.setAnalyticsCollectionEnabled(enabled);
      if (!enabled) {
        await analytics.resetAnalyticsData();
      }
    } catch (e) {
      AppLogger.warn('Applying analytics consent failed: $e');
    }
  }

  /// Asks once, with equally weighted options. Does nothing when the user
  /// already decided.
  static Future<void> maybeAsk(BuildContext context) async {
    if (kIsWeb) return;
    final decided = await load();
    if (decided != null || !context.mounted) return;

    final choice = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('Hilf uns, SideQuest besser zu machen', 'Help us improve SideQuest'),
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                t(
                  'Dürfen wir Nutzungsstatistiken und Absturzberichte (Google Firebase Analytics und Crashlytics) erheben? Damit sehen wir, welche Funktionen genutzt werden und wo die App abstürzt. Keine Werbung, kein Verkauf von Daten. Du kannst das jederzeit in den Einstellungen ändern.',
                  'May we collect usage statistics and crash reports (Google Firebase Analytics and Crashlytics)? They show us which features are used and where the app crashes. No ads, no selling of data. You can change this any time in the settings.',
                ),
                style: GoogleFonts.inter(
                  color: const Color(0xFFB8B8B8),
                  fontSize: 14,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF4A4A4A)),
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: Text(t('Ablehnen', 'Decline')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFF4A4A4A)),
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: Text(t('Erlauben', 'Allow')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null) await set(choice);
  }
}
