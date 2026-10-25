import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';

/// Streak after a quest post. The server updates flames when the photo row
/// is inserted (apply_streak_on_daily_post); clients can't write it.
Future<int> readStreakAfterQuestPost(
  SupabaseClient client,
  String userId,
) async {
  try {
    final row = await client
        .from('users_profile')
        .select('flames')
        .eq('id', userId)
        .maybeSingle();
    return (row?['flames'] as num?)?.toInt() ?? 0;
  } catch (e) {
    AppLogger.debug('Reading streak after post failed: $e');
    return 0;
  }
}
