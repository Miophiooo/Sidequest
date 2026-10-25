import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/daily_challenges.dart';
import 'package:nummwe3/london_time.dart';
import 'package:nummwe3/shared.dart';

void main() {
  group('parseUtcTimestamp', () {
    test('value without offset is UTC, not device time', () {
      expect(
        parseUtcTimestamp('2026-10-24T13:05:00'),
        DateTime.utc(2026, 10, 24, 13, 5),
      );
      expect(
        parseUtcTimestamp('2026-10-24T13:05:00.123456'),
        DateTime.utc(2026, 10, 24, 13, 5, 0, 123, 456),
      );
    });

    test('values with Z or offset keep their instant', () {
      expect(
        parseUtcTimestamp('2026-10-24T13:05:00Z'),
        DateTime.utc(2026, 10, 24, 13, 5),
      );
      expect(
        parseUtcTimestamp('2026-10-24T15:05:00+02:00'),
        DateTime.utc(2026, 10, 24, 13, 5),
      );
      expect(parseUtcTimestamp('2026-10-24T15:05:00+02:00')!.isUtc, isTrue);
    });

    test('DateTime input and invalid input', () {
      final instant = DateTime.utc(2026, 1, 2, 3);
      expect(parseUtcTimestamp(instant.toLocal()), instant);
      expect(parseUtcTimestamp(null), isNull);
      expect(parseUtcTimestamp(''), isNull);
      expect(parseUtcTimestamp('not a date'), isNull);
    });
  });

  group('hoursAfterQuestEnd', () {
    final day = DateTime(2026, 10, 20);
    final start = challengeStartUtcForLondonDay(day);
    final end = challengeEndLocal(start).toUtc();

    test('posted during the quest is 0', () {
      expect(hoursAfterQuestEnd(start.add(const Duration(minutes: 5))), 0);
    });

    test('counts whole hours after the end of the same quest', () {
      expect(
        hoursAfterQuestEnd(end.add(const Duration(hours: 3, minutes: 10))),
        3,
      );
    });

    test('a late post after London midnight still belongs to its quest', () {
      final londonMidnight = londonLocalToUtc(DateTime(2026, 10, 21));
      final next = challengeStartUtcForLondonDay(DateTime(2026, 10, 21));
      final posted = londonMidnight.add(const Duration(minutes: 30));
      if (!posted.isBefore(next)) return; // next quest already started
      expect(hoursAfterQuestEnd(posted), posted.difference(end).inHours);
    });
  });
}
