import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

User _user(Map<String, dynamic> metadata) => User(
  id: 'user-1',
  appMetadata: const {},
  userMetadata: metadata,
  aud: 'authenticated',
  createdAt: '2026-10-24T00:00:00Z',
);

void main() {
  test('google/apple users without consent must pass the consent gate', () {
    expect(userNeedsLaunchCompliance(_user(const {})), isTrue);
  });

  test('an older legal version asks again', () {
    expect(
      userNeedsLaunchCompliance(
        _user(const {
          'accepted_terms_version': '2026-02-22',
          'accepted_privacy_version': '2026-02-22',
          'accepted_legal_at': '2026-03-01T10:00:00Z',
        }),
      ),
      isTrue,
    );
  });

  test('current consent passes without any age confirmation', () {
    final metadata = requiredLegalMetadataPayload();
    expect(metadata.containsKey('minimum_age_confirmed'), isFalse);
    expect(userNeedsLaunchCompliance(_user(metadata)), isFalse);
  });

  test('signed-out state needs no gate', () {
    expect(userNeedsLaunchCompliance(null), isFalse);
  });
}
