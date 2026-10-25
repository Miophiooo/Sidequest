import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/core/error_mapper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('maps invalid credentials to user-friendly message', () {
    final exception = AuthException('Invalid login credentials');
    final mapped = ErrorMapper.auth(exception);

    expect(mapped.de, contains('E-Mail'));
    expect(mapped.en, contains('incorrect'));
  });

  test('unknown auth errors hide the server text', () {
    final mapped = ErrorMapper.auth(
      AuthException('Database error saving new user'),
    );
    expect(mapped.de, isNot(contains('Database')));
    expect(mapped.en, isNot(contains('Database')));
    expect(
      ErrorMapper.auth(AuthException('Email rate limit exceeded')).de,
      contains('Zu viele Versuche'),
    );
  });

  test('maps generic errors', () {
    final mapped = ErrorMapper.generic(Exception('boom'));
    expect(mapped.de, contains('Fehler'));
    expect(mapped.en, contains('error'));
  });

  test('describe never shows the raw exception', () {
    final text = ErrorMapper.describe(
      const PostgrestException(message: 'permission denied for table x'),
      whatDe: 'Löschen fehlgeschlagen',
      whatEn: 'Delete failed',
    );
    expect(text, isNot(contains('permission denied')));
    expect(text, anyOf(contains('Löschen'), contains('Delete')));
  });

  test('rate limits and offline errors get a specific hint', () {
    expect(
      ErrorMapper.isRateLimited(
        const PostgrestException(message: 'rate_limited'),
      ),
      isTrue,
    );
    expect(
      ErrorMapper.generic(Exception('SocketException: Failed host lookup')),
      same(ErrorMapper.offline),
    );
  });
}
