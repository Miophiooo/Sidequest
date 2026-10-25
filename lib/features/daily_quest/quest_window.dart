import '../../daily_challenges.dart';
import '../../london_time.dart';
import '../../shared.dart';

/// How long the quest of [londonDay] runs (2 or 5 hours, cut at 23:59
/// London). Computed locally from the shared rotation, no request.
Duration questWindowForLondonDay(DateTime londonDay) {
  final start = challengeStartUtcForLondonDay(londonDay).toLocal();
  return challengeEndLocal(start).difference(start);
}

/// "2 Std. Zeit" / "2 h to post"; minutes only when it isn't whole hours.
String questDurationLabel(Duration window) {
  final hours = window.inHours;
  final minutes = window.inMinutes % 60;
  if (hours == 0) return t('$minutes Min. Zeit', '$minutes min to post');
  if (minutes == 0) return t('$hours Std. Zeit', '$hours h to post');
  return t('$hours Std. $minutes Min. Zeit', '$hours h $minutes min to post');
}

String _hhmm(DateTime local) =>
    '${local.hour.toString().padLeft(2, '0')}:'
    '${local.minute.toString().padLeft(2, '0')}';

/// "09:52–14:52 · 5 Std. Zeit" in the device's time.
String questWindowLabel(DateTime startLocal, DateTime endLocal) {
  return '${_hhmm(startLocal)}–${_hhmm(endLocal)} · '
      '${questDurationLabel(endLocal.difference(startLocal))}';
}
