import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/duels/duel_results.dart';

void main() {
  test('winner decides won or lost', () {
    expect(
      duelOutcomeFor(me: 'a', winnerId: 'a', anyPhoto: true),
      DuelOutcome.won,
    );
    expect(
      duelOutcomeFor(me: 'a', winnerId: 'b', anyPhoto: true),
      DuelOutcome.lost,
    );
  });

  test('no winner is a draw with photos, else expired', () {
    expect(
      duelOutcomeFor(me: 'a', winnerId: null, anyPhoto: true),
      DuelOutcome.draw,
    );
    expect(
      duelOutcomeFor(me: 'a', winnerId: '', anyPhoto: false),
      DuelOutcome.expired,
    );
  });
}
