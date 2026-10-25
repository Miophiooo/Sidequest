import 'package:firebase_analytics/firebase_analytics.dart';

class AnalyticsService {
  AnalyticsService._();

  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  static Future<void> setUserId(String? userId) async {
    try {
      await _analytics.setUserId(id: userId);
    } catch (_) {}
  }

  static Future<void> logOnboardingStarted() async {
    try {
      await _analytics.logEvent(name: 'onboarding_started');
    } catch (_) {}
  }

  static Future<void> logOnboardingCompleted({required bool emailConfirmedSession}) async {
    try {
      await _analytics.logEvent(
        name: 'onboarding_completed',
        parameters: {
          'email_confirmed_session': emailConfirmedSession ? 1 : 0,
        },
      );
    } catch (_) {}
  }

  static Future<void> logLoginSuccess() async {
    try {
      await _analytics.logLogin(loginMethod: 'email');
      await _analytics.logEvent(name: 'login_success');
    } catch (_) {}
  }

  static Future<void> logInviteSent({required String type}) async {
    try {
      await _analytics.logEvent(
        name: 'invite_sent',
        parameters: {'invite_type': type},
      );
    } catch (_) {}
  }

  static Future<void> logSettingsGrowthAction({
    required String action,
    required String surface,
    String? platform,
  }) async {
    try {
      final params = <String, Object>{
        'action': action,
        'surface': surface,
      };
      if (platform != null && platform.isNotEmpty) {
        params['platform'] = platform;
      }
      await _analytics.logEvent(
        name: 'settings_growth_action',
        parameters: params,
      );
    } catch (_) {}
  }

  static Future<void> logPostCreated({required bool isPublic, required bool isLate}) async {
    try {
      await _analytics.logEvent(
        name: 'post_created',
        parameters: {
          'is_public': isPublic ? 1 : 0,
          'is_late': isLate ? 1 : 0,
        },
      );
    } catch (_) {}
  }

  static Future<void> logChallengeCompleted({required bool isLate}) async {
    try {
      await _analytics.logEvent(
        name: 'challenge_completed',
        parameters: {'is_late': isLate ? 1 : 0},
      );
    } catch (_) {}
  }

  static Future<void> logLogout() async {
    try {
      await _analytics.logEvent(name: 'logout');
      await _analytics.setUserId(id: null);
    } catch (_) {}
  }
}
