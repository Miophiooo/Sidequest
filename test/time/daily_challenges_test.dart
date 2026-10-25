import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/daily_challenges.dart';
import 'package:nummwe3/london_time.dart';

void main() {
  test('active challenge day switches at london challenge start', () {
    final beforeStartUtc = londonLocalToUtc(DateTime(2026, 3, 5, 7, 59));
    final afterStartUtc = londonLocalToUtc(DateTime(2026, 3, 5, 9, 0));

    final beforeStart = activeLondonChallengeDayFromUtc(beforeStartUtc);
    final afterStart = activeLondonChallengeDayFromUtc(afterStartUtc);

    expect(londonDateStrFromLondonDay(beforeStart), '2026-03-04');
    expect(londonDateStrFromLondonDay(afterStart), '2026-03-05');
  });

  test('challenge start is deterministic and bounded', () {
    final day = DateTime(2026, 7, 9);
    final start1 = challengeStartMinuteOfDayForLondonDay(day);
    final start2 = challengeStartMinuteOfDayForLondonDay(day);

    expect(start1, start2);
    // Before the random-start cutover: 08:00-09:59 London.
    expect(start1, inInclusiveRange(8 * 60, 9 * 60 + 59));
  });

  test('day index does not depend on the device time zone', () {
    // A local-time difference from 2024-01-01 is one hour short in summer
    // on DST devices; the UTC-based index must still count full days.
    expect(challengeDayIndexForLondonDay(DateTime(2024, 1, 2)), 1);
    expect(challengeDayIndexForLondonDay(DateTime(2026, 7, 9)), 920);
    expect(challengeDayIndexForLondonDay(DateTime(2026, 10, 27)), 1030);
  });

  test('random start from the cutover day: 09:00-18:59 London', () {
    expect(
      challengeDayIndexForLondonDay(DateTime(2026, 10, 27)),
      kRandomChallengeStartDayIndex,
    );
    final hours = <int>{};
    for (var offset = 0; offset < 120; offset++) {
      final day = DateTime(2026, 10, 27 + offset);
      final start = challengeStartMinuteOfDayForLondonDay(day);
      expect(start, inInclusiveRange(9 * 60, 18 * 60 + 59));
      hours.add(start ~/ 60);
    }
    // Spread over the whole range, not stuck in one part of the day.
    expect(hours.length, 10);
  });

  test('difficulty rotation matches the daily-scheduler edge function', () {
    // Anchor day 2024-01-01 has index 0 -> 'medium', then cycles every 3 days.
    expect(dailyDifficultyForLondonDay(DateTime(2024, 1, 1)), 'medium');
    expect(dailyDifficultyForLondonDay(DateTime(2024, 1, 2)), 'easy');
    expect(dailyDifficultyForLondonDay(DateTime(2024, 1, 3)), 'medium');
    expect(dailyDifficultyForLondonDay(DateTime(2024, 1, 4)), 'medium');
  });

  test('challenge window length depends on difficulty (2h/5h/9h)', () {
    expect(
      dailyChallengeWindowForDifficulty('easy'),
      const Duration(hours: 2),
    );
    expect(
      dailyChallengeWindowForDifficulty('medium'),
      const Duration(hours: 5),
    );
    expect(
      dailyChallengeWindowForDifficulty('hard'),
      const Duration(hours: 9),
    );
  });

  test('challenge end = start + difficulty window (scheduler parity)', () {
    // 2024-01-02 is an 'easy' day -> end is exactly 2h after start.
    final day = DateTime(2024, 1, 2);
    final startLondon = challengeStartLondonForDay(day);
    final reference = londonLocalToUtc(startLondon).toLocal();

    final start = challengeStartLocal(reference);
    final end = challengeEndLocal(reference);

    expect(end.difference(start), const Duration(hours: 2));
  });

  test('challenge end never crosses the london day boundary', () {
    // Worst case: latest possible start (18:59) + 5h window = 23:59 London.
    // The 23:59 clamp must keep any window inside the same day.
    for (var offset = 0; offset < 200; offset++) {
      final day = DateTime(2026, 8, 3 + offset);
      final reference = londonLocalToUtc(
        challengeStartLondonForDay(day),
      ).toLocal();
      final endLondon = toLondonTime(challengeEndLocal(reference).toUtc());
      expect(endLondon.day, day.day, reason: 'window crossed midnight');
    }
  });

  test('start/end match the server around the London clock changes', () {
    // Values from public.challenge_day_bounds() on the live database
    // (2026-10-24). 25 Oct 2026 and 28 Mar 2027 are the clock-change days,
    // 27 Oct 2026 is the random-start cutover.
    const expected = <String, (String, String)>{
      '2026-10-24': ('2026-10-24T07:53:00Z', '2026-10-24T09:53:00Z'),
      '2026-10-25': ('2026-10-25T08:52:00Z', '2026-10-25T13:52:00Z'),
      '2026-10-26': ('2026-10-26T08:51:00Z', '2026-10-26T13:51:00Z'),
      '2026-10-27': ('2026-10-27T15:11:00Z', '2026-10-27T17:11:00Z'),
      '2026-10-28': ('2026-10-28T12:01:00Z', '2026-10-28T17:01:00Z'),
      '2027-03-27': ('2027-03-27T09:31:00Z', '2027-03-27T14:31:00Z'),
      '2027-03-28': ('2027-03-28T11:23:00Z', '2027-03-28T16:23:00Z'),
      '2027-03-29': ('2027-03-29T15:17:00Z', '2027-03-29T17:17:00Z'),
    };

    expected.forEach((dayStr, bounds) {
      final parts = dayStr.split('-').map(int.parse).toList();
      final day = DateTime(parts[0], parts[1], parts[2]);
      final startUtc = challengeStartUtcForLondonDay(day);
      expect(startUtc, DateTime.parse(bounds.$1), reason: 'start $dayStr');

      final endUtc = challengeEndLocal(startUtc.toLocal()).toUtc();
      expect(endUtc, DateTime.parse(bounds.$2), reason: 'end $dayStr');

      // Right after the start the active day is this London day.
      final active = activeLondonChallengeDayFromUtc(
        startUtc.add(const Duration(minutes: 1)),
      );
      expect(londonDateStrFromLondonDay(active), dayStr);
    });
  });
}
