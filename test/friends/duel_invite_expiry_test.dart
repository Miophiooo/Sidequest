import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/friends.dart';

void main() {
  final created = DateTime.utc(2026, 10, 24, 10, 0);
  final invite = {'server_created_at': created.toIso8601String()};

  test('an invite can be accepted for 2 hours', () {
    expect(
      isDuelInviteExpired(invite, created.add(const Duration(minutes: 119))),
      isFalse,
    );
    expect(
      isDuelInviteExpired(invite, created.add(const Duration(hours: 2))),
      isTrue,
    );
  });

  test('the last minute reads "< 1 min" instead of "0 min"', () {
    final almostExpired = {
      'server_created_at': DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1, minutes: 59, seconds: 30))
          .toIso8601String(),
    };
    expect(duelInviteTimeLeftLabel(almostExpired), contains('< 1 min'));
  });
}
