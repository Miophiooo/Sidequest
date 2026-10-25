import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/daily_challenges.dart';
import 'package:nummwe3/features/daily_quest/quest_window.dart';

void main() {
  test('quest window follows the difficulty rotation', () {
    // Server values: 2026-10-24 ran 07:53–09:53 UTC ("easy", 2 h), the
    // 25th 08:52–13:52 UTC ("medium", 5 h).
    expect(questWindowForLondonDay(DateTime(2026, 10, 24)).inHours, 2);
    expect(questWindowForLondonDay(DateTime(2026, 10, 25)).inHours, 5);
  });

  test('duration labels', () {
    expect(questDurationLabel(const Duration(hours: 5)), '5 Std. Zeit');
    expect(questDurationLabel(const Duration(minutes: 45)), '45 Min. Zeit');
    expect(
      questDurationLabel(const Duration(hours: 2, minutes: 30)),
      '2 Std. 30 Min. Zeit',
    );
    expect(
      questWindowLabel(
        DateTime(2026, 10, 25, 9, 52),
        DateTime(2026, 10, 25, 14, 52),
      ),
      '09:52–14:52 · 5 Std. Zeit',
    );
  });

  test('offline quest list carries the fixed quests', () {
    expect(kDailyChallenges, hasLength(51));
    final titles = kDailyChallenges.map((q) => q['de']).toSet();
    expect(titles, isNot(contains('Gelbes Auto')));
    expect(titles, contains('Etwas Gelbes'));
    for (final quest in kDailyChallenges) {
      expect(
        (quest['desc_de'] as String).trim().endsWith('.'),
        isTrue,
        reason: quest['de'] as String,
      );
    }
  });
}
