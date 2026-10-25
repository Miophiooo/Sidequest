import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/notifications/notification_text.dart';
import 'package:nummwe3/widgets/crowd_favorite_badge.dart';

void main() {
  group('notificationText', () {
    test('uses the actor name', () {
      expect(
        notificationText({'type': 'like'}, actorName: 'max'),
        '@max gefällt dein Foto',
      );
      expect(
        notificationText({'type': 'friend_request'}),
        'Jemand möchte mit dir befreundet sein',
      );
    });

    test('shows the comment text', () {
      expect(
        notificationText({
          'type': 'comment',
          'data': {'message': 'Wow'},
        }, actorName: 'lea'),
        '@lea hat kommentiert: „Wow“',
      );
    });

    test('duel result depends on the winner', () {
      final row = {
        'type': 'duel_result',
        'data': {'winner_id': 'me', 'had_photos': true},
      };
      expect(
        notificationText(row, actorName: 'max', me: 'me'),
        'Du hast das Duell gegen @max gewonnen',
      );
      expect(
        notificationText(row, actorName: 'max', me: 'other'),
        '@max hat das Duell gewonnen',
      );
      expect(
        notificationText({
          'type': 'duel_result',
          'data': {'winner_id': '', 'had_photos': true},
        }, actorName: 'max'),
        'Dein Duell gegen @max endet unentschieden',
      );
    });

    test('mentions use the entity and preview', () {
      expect(
        notificationText({
          'type': 'mention',
          'data': {'entity': 'comment', 'preview': 'Schau mal'},
        }, actorName: 'max'),
        '@max hat dich in einem Kommentar erwähnt: „Schau mal“',
      );
    });

    test('unknown types keep the stored message', () {
      expect(
        notificationText({
          'type': 'mention',
          'message': '@max hat dich erwähnt',
        }),
        '@max hat dich erwähnt',
      );
    });
  });

  group('relativeTimeLabel', () {
    final now = DateTime(2026, 10, 25, 12, 0);

    test('minutes, hours, yesterday, days, date', () {
      expect(relativeTimeLabel(now, now: now), 'gerade eben');
      expect(
        relativeTimeLabel(now.subtract(const Duration(minutes: 5)), now: now),
        'vor 5 Min.',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(hours: 3)), now: now),
        'vor 3 Std.',
      );
      expect(
        relativeTimeLabel(DateTime(2026, 10, 24, 9, 0), now: now),
        'gestern',
      );
      expect(
        relativeTimeLabel(DateTime(2026, 10, 21, 9, 0), now: now),
        'vor 4 Tagen',
      );
      expect(
        relativeTimeLabel(DateTime(2026, 10, 2, 9, 0), now: now),
        '02.10.',
      );
    });

    test('a clock running ahead reads as just now', () {
      expect(
        relativeTimeLabel(now.add(const Duration(minutes: 2)), now: now),
        'gerade eben',
      );
    });
  });

  test('crowd favorite is active until the stored time', () {
    final now = DateTime.utc(2026, 10, 25, 12);
    expect(crowdFavoriteActive('2026-10-25T13:00:00+00:00', now), isTrue);
    expect(crowdFavoriteActive('2026-10-25T11:00:00+00:00', now), isFalse);
    expect(crowdFavoriteActive(null, now), isFalse);
  });
}
