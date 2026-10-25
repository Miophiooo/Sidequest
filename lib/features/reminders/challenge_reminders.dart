import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app_bootstrap.dart';
import '../../core/app_logger.dart';
import '../../daily_challenges.dart';
import '../../london_time.dart';
import '../../shared.dart';

/// Daily challenge reminders scheduled on the device.
///
/// The challenge times are deterministic (see `lib/london_time.dart`), so the
/// next days can be scheduled ahead. Only used when the device has no remote
/// push token: sideloaded iOS builds can't register with APNs, so the
/// server-side pushes (start, streak warning, 10 minutes left) never arrive
/// there. Devices with FCM keep getting the server pushes instead.
class ChallengeReminders {
  ChallengeReminders._();

  static const int _days = 7;
  static const int _startIdBase = 7100;
  static const int _streakWarningIdBase = 7200;
  static const int _endingIdBase = 7300;

  static Future<void> _queue = Future.value();

  /// Re-plans all reminders. [postedActiveDay] skips today's "ending"
  /// reminders once the daily photo is posted. Calls run one after another,
  /// so the latest state always wins.
  static Future<void> reschedule({required bool postedActiveDay}) {
    return _queue = _queue.then((_) => _reschedule(postedActiveDay));
  }

  static Future<void> _reschedule(bool postedActiveDay) async {
    if (kIsWeb) return;
    try {
      // The FCM token is requested during deferred startup; wait for it so
      // Android devices don't get local reminders on top of server pushes.
      await startSideQuestDeferredServices();

      for (var i = 0; i < _days; i++) {
        await NotificationService.instance.cancel(_startIdBase + i);
        await NotificationService.instance.cancel(_streakWarningIdBase + i);
        await NotificationService.instance.cancel(_endingIdBase + i);
      }
      if (sideQuestHasRemotePushToken) return;

      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      final profile = await client
          .from('users_profile')
          .select('flames')
          .eq('id', userId)
          .maybeSingle();
      final flames = (profile?['flames'] as num?)?.toInt() ?? 0;

      final allowStart = await NotificationPrefs.getChallengeStart();
      final allowEnding = await NotificationPrefs.getChallengeEnding();
      final payload = jsonEncode({'target_tab': '0'});

      final nowUtc = DateTime.now().toUtc();
      final activeDay = activeLondonChallengeDayFromUtc(nowUtc);

      for (var i = 0; i < _days; i++) {
        final day = DateTime(activeDay.year, activeDay.month, activeDay.day + i);
        final startUtc = challengeStartUtcForLondonDay(day);
        final endUtc = challengeEndLocal(startUtc.toLocal()).toUtc();
        final hours = dailyChallengeWindowForDifficulty(
          dailyDifficultyForLondonDay(day),
        ).inHours;

        if (allowStart && startUtc.isAfter(nowUtc)) {
          await NotificationService.instance.scheduleAt(
            id: _startIdBase + i,
            when: startUtc,
            title: t('📸 Neue Daily Quest!', '📸 New Daily Quest!'),
            body: t(
              'Du hast $hours Stunden Zeit für dein Foto.',
              'You have $hours hours for your photo.',
            ),
            payload: payload,
          );
        }

        if (!allowEnding || (i == 0 && postedActiveDay)) continue;

        final streakWarningUtc = endUtc.subtract(const Duration(hours: 1));
        if (flames > 0 && streakWarningUtc.isAfter(nowUtc)) {
          await NotificationService.instance.scheduleAt(
            id: _streakWarningIdBase + i,
            when: streakWarningUtc,
            title: t('🔥 Streak in Gefahr!', '🔥 Streak at risk!'),
            body: t(
              'Noch 1 Stunde – poste dein Foto, damit deine Streak nicht reißt.',
              '1 hour left – post your photo to keep your streak.',
            ),
            payload: payload,
          );
        }

        final endingUtc = endUtc.subtract(const Duration(minutes: 10));
        if (endingUtc.isAfter(nowUtc)) {
          await NotificationService.instance.scheduleAt(
            id: _endingIdBase + i,
            when: endingUtc,
            title: t('⏰ Noch 10 Minuten!', '⏰ 10 minutes left!'),
            body: t(
              'Die Daily Quest endet gleich.',
              "Today's quest ends soon.",
            ),
            payload: payload,
          );
        }
      }
    } catch (e) {
      AppLogger.debug('Could not schedule challenge reminders: $e');
    }
  }
}
