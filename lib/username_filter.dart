import 'text_normalizer.dart';

class UsernameValidationResult {
  final bool isValid;
  final String normalized;
  final UsernameValidationError? error;

  const UsernameValidationResult._({
    required this.isValid,
    required this.normalized,
    required this.error,
  });

  const UsernameValidationResult.valid(String normalized)
    : this._(isValid: true, normalized: normalized, error: null);

  const UsernameValidationResult.invalid({
    required String normalized,
    required UsernameValidationError error,
  }) : this._(isValid: false, normalized: normalized, error: error);
}

enum UsernameValidationError {
  empty,
  tooShort,
  tooLong,
  invalidCharacters,
  reservedOrOffensive,
}

class UsernameFilter {
  static const int minLength = 3;
  static const int maxLength = 10;
  static const String allowedCharacterClass =
      'A-Za-z0-9_\\u00c4\\u00d6\\u00dc\\u00df\\u00e4\\u00f6\\u00fc\\u1e9e';

  static final RegExp _allowed = RegExp('^[$allowedCharacterClass]+\$');
  static final RegExp _disallowedChars = RegExp('[^$allowedCharacterClass]');

  static const Set<String> _reservedExact = {
    'admin',
    'administrator',
    'support',
    'help',
    'hilfe',
    'kontakt',
    'contact',
    'mod',
    'moderator',
    'system',
    'root',
    'owner',
    'official',
    'team',
    'staff',
    'api',
    'backend',
    'service',
    'null',
    'undefined',
    'guest',
    'test',
    'sidequest',
    'info',
    'abuse',
    'security',
    'noreply',
    'postmaster',
    'webmaster',
    'bot',
    'automod',
    'delete',
    'deleted',
    'anonymous',
  };

  static const Set<String> _blockedSubstrings = {
    'fick',
    'ficken',
    'scheisse',
    'hurensohn',
    'arschloch',
    'nazi',
    'hitler',
    'heil',
    'vergasen',
    'fuck',
    'shit',
    'bitch',
    'asshole',
    'nigger',
    'nigga',
    'whore',
    'slut',
    'cunt',
    'faggot',
    'retard',
    'rape',
    'kys',
    'missgeburt',
    'schwuchtel',
    'kanake',
    'spast',
    'fotze',
    'wichser',
    'nutte',
    'mongo',
  };

  static String normalize(String raw) =>
      normalizeGermanKeyboardInput(raw).trim();

  static String comparisonKey(String raw) => normalize(raw).toLowerCase();

  static String sanitizeLiveInput(String raw) {
    final normalized = normalize(raw);
    final sanitized = normalized.replaceAll(_disallowedChars, '');
    if (sanitized.length <= maxLength) return sanitized;
    return sanitized.substring(0, maxLength);
  }

  static UsernameValidationResult validate(String raw) {
    final normalized = normalize(raw);
    final comparisonKey = UsernameFilter.comparisonKey(normalized);

    if (normalized.isEmpty) {
      return const UsernameValidationResult.invalid(
        normalized: '',
        error: UsernameValidationError.empty,
      );
    }

    if (normalized.length < minLength) {
      return UsernameValidationResult.invalid(
        normalized: normalized,
        error: UsernameValidationError.tooShort,
      );
    }

    if (normalized.length > maxLength) {
      return UsernameValidationResult.invalid(
        normalized: normalized,
        error: UsernameValidationError.tooLong,
      );
    }

    if (!_allowed.hasMatch(normalized)) {
      return UsernameValidationResult.invalid(
        normalized: normalized,
        error: UsernameValidationError.invalidCharacters,
      );
    }

    final compact = comparisonKey.replaceAll('_', '');
    if (_reservedExact.contains(comparisonKey) ||
        _reservedExact.contains(compact)) {
      return UsernameValidationResult.invalid(
        normalized: normalized,
        error: UsernameValidationError.reservedOrOffensive,
      );
    }

    for (final blocked in _blockedSubstrings) {
      if (compact.contains(blocked)) {
        return UsernameValidationResult.invalid(
          normalized: normalized,
          error: UsernameValidationError.reservedOrOffensive,
        );
      }
    }

    return UsernameValidationResult.valid(normalized);
  }

  static String makeSafeFallback({required String userId, String? seed}) {
    var base = normalize(seed ?? 'User');
    base = base.replaceAll(_disallowedChars, '');
    if (base.length > maxLength) {
      base = base.substring(0, maxLength);
    }

    final valid = validate(base);
    if (valid.isValid) return valid.normalized;

    final rawId = userId.replaceAll('-', '');
    final suffix = rawId.length >= 6 ? rawId.substring(0, 6) : rawId;
    final fallback = 'User$suffix';
    if (fallback.length <= maxLength) return fallback;
    return fallback.substring(0, maxLength);
  }
}
