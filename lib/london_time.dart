DateTime _lastSundayOfMonthUtc(int year, int month, int hourUtc) {
  final firstNextMonth = DateTime.utc(year, month + 1, 1, hourUtc);
  final lastDay = firstNextMonth.subtract(const Duration(days: 1));
  final delta = lastDay.weekday % 7; // weekday: 1=Mon..7=Sun
  return DateTime.utc(
    year,
    month,
    lastDay.day - (delta == 0 ? 0 : delta),
    hourUtc,
  );
}

Duration londonOffsetForUtc(DateTime utc) {
  final u = utc.toUtc();
  // GMT/BST: DST from last Sunday in March 01:00 UTC to last Sunday in Oct 01:00 UTC
  final start = _lastSundayOfMonthUtc(u.year, 3, 1);
  final end = _lastSundayOfMonthUtc(u.year, 10, 1);
  final inDst = !u.isBefore(start) && u.isBefore(end);
  return Duration(hours: inDst ? 1 : 0);
}

DateTime toLondonTime(DateTime utc) {
  final u = utc.toUtc();
  return u.add(londonOffsetForUtc(u));
}

DateTime londonDateOnlyFromUtc(DateTime utc) {
  final l = toLondonTime(utc);
  return DateTime(l.year, l.month, l.day);
}

String londonDateStrFromLondonDay(DateTime londonDay) {
  final y = londonDay.year.toString().padLeft(4, '0');
  final m = londonDay.month.toString().padLeft(2, '0');
  final d = londonDay.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String londonDateStrFromUtc(DateTime utc) {
  return londonDateStrFromLondonDay(londonDateOnlyFromUtc(utc));
}

bool _sameLocalComponents(DateTime a, DateTime b) {
  return a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute &&
      a.second == b.second &&
      a.millisecond == b.millisecond &&
      a.microsecond == b.microsecond;
}

DateTime londonLocalToUtc(DateTime londonLocal) {
  // Interpret the provided DateTime components as London local time.
  // Offset can only be 0 or +1 hour, so we can disambiguate by trying both.
  final naiveUtc = DateTime.utc(
    londonLocal.year,
    londonLocal.month,
    londonLocal.day,
    londonLocal.hour,
    londonLocal.minute,
    londonLocal.second,
    londonLocal.millisecond,
    londonLocal.microsecond,
  );

  final candidate0 = naiveUtc; // offset 0
  if (_sameLocalComponents(toLondonTime(candidate0), londonLocal)) return candidate0;

  final candidate1 = naiveUtc.subtract(const Duration(hours: 1)); // offset +1
  if (_sameLocalComponents(toLondonTime(candidate1), londonLocal)) return candidate1;

  // Fallback: use computed offset for the naive UTC instant.
  final offset = londonOffsetForUtc(naiveUtc);
  return naiveUtc.subtract(offset);
}

/// Days since 2024-01-01 for a London calendar day. Counted in UTC: with
/// local DateTimes a device in a DST zone (e.g. Germany in summer) sees one
/// hour less and `inDays` rounds down to the previous day.
int challengeDayIndexForLondonDay(DateTime londonDay) {
  final dayUtc = DateTime.utc(londonDay.year, londonDay.month, londonDay.day);
  return dayUtc.difference(DateTime.utc(2024, 1, 1)).inDays;
}

/// From this day index on (2026-10-27) the challenge starts at a
/// pseudo-random time between 09:00 and 18:59 London; before it started
/// between 08:00 and 09:59. Keep in sync with
/// `supabase/functions/daily-scheduler/index.ts` and
/// `public.challenge_day_bounds()`.
const int kRandomChallengeStartDayIndex = 1030;

/// Challenge start as minutes after midnight (London) for [londonDay].
int challengeStartMinuteOfDayForLondonDay(DateTime londonDay) {
  final d = challengeDayIndexForLondonDay(londonDay);
  if (d < kRandomChallengeStartDayIndex) {
    return 8 * 60 + (d * 7919) % 120;
  }
  return 9 * 60 + (d * d * 31 + d * 7919 + 101) % 600;
}

DateTime challengeStartLondonForDay(DateTime londonDay) {
  final minuteOfDay = challengeStartMinuteOfDayForLondonDay(londonDay);
  return DateTime(
    londonDay.year,
    londonDay.month,
    londonDay.day,
    minuteOfDay ~/ 60,
    minuteOfDay % 60,
  );
}

DateTime challengeStartUtcForLondonDay(DateTime londonDay) {
  return londonLocalToUtc(challengeStartLondonForDay(londonDay));
}
