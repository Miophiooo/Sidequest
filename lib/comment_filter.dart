import 'text_normalizer.dart';

enum CommentModerationIssue { empty, tooLong, abusiveLanguage }

class CommentModerationResult {
  final bool isAllowed;
  final String sanitized;
  final CommentModerationIssue? issue;
  final String? matchedToken;

  const CommentModerationResult._({
    required this.isAllowed,
    required this.sanitized,
    required this.issue,
    required this.matchedToken,
  });

  const CommentModerationResult.allowed(String sanitized)
    : this._(
        isAllowed: true,
        sanitized: sanitized,
        issue: null,
        matchedToken: null,
      );

  const CommentModerationResult.blocked({
    required String sanitized,
    required CommentModerationIssue issue,
    String? matchedToken,
  }) : this._(
         isAllowed: false,
         sanitized: sanitized,
         issue: issue,
         matchedToken: matchedToken,
       );
}

class CommentFilter {
  static const int maxLength = 280;
  static final RegExp _tokenSplitRegex = RegExp(r'[^a-z0-9]+');
  static final RegExp _collapseRegex = RegExp(r'[^a-z0-9]');

  static const Set<String> _blockedTokens = {
    // German insults
    'arsch',
    'arschloch',
    'arschgesicht',
    'arschkriecher',
    'bastard',
    'bastarde',
    'behindert',
    'drecksau',
    'drecksschwein',
    'dreckskind',
    'dummsau',
    'dummkopf',
    'fick',
    'ficken',
    'ficker',
    'fickdich',
    'fickstueck',
    'fotze',
    'fotzen',
    'hackfresse',
    'hure',
    'hurensohn',
    'hurenkind',
    'idiot',
    'idiotin',
    'kacke',
    'kackbratze',
    'kackspast',
    'kackvogel',
    'kanake',
    'missgeburt',
    'miststueck',
    'mongo',
    'mongole',
    'nutte',
    'opfer',
    'penner',
    'pisser',
    'scheisse',
    'scheiss',
    'schlampe',
    'schwuchtel',
    'spast',
    'spasti',
    'spastiker',
    'volldepp',
    'vollidiot',
    'wichser',
    'wixer',
    // Hate/extremism
    'nazi',
    'nazischwein',
    'hitler',
    'heil',
    'sieg',
    'vergasen',
    'holocaust',
    // English insults
    'ass',
    'asshole',
    'asshat',
    'asswipe',
    'bitch',
    'bullshit',
    'cock',
    'cocksucker',
    'cunt',
    'damn',
    'dick',
    'dickhead',
    'dipshit',
    'dumbass',
    'fag',
    'faggot',
    'fuck',
    'fucked',
    'fucker',
    'fucking',
    'fuckyou',
    'hoe',
    'jackass',
    'kys',
    'loser',
    'mf',
    'moron',
    'motherfucker',
    'motherfucking',
    'nigga',
    'nigger',
    'pieceofshit',
    'prick',
    'pussy',
    'rape',
    'rapist',
    'retard',
    'retarded',
    'shit',
    'shithead',
    'slut',
    'stfu',
    'twat',
    'wanker',
    'whore',
    // Threats / self-harm
    'killyourself',
    'killurself',
    'godie',
    'suicide',
  };

  static CommentModerationResult validate(String raw) {
    final trimmed = normalizeGermanKeyboardInput(raw).trim();
    if (trimmed.isEmpty) {
      return const CommentModerationResult.blocked(
        sanitized: '',
        issue: CommentModerationIssue.empty,
      );
    }

    if (trimmed.length > maxLength) {
      return CommentModerationResult.blocked(
        sanitized: trimmed,
        issue: CommentModerationIssue.tooLong,
      );
    }

    final normalized = _normalizeForMatch(trimmed);
    final tokens = normalized
        .split(_tokenSplitRegex)
        .where((t) => t.length >= 2)
        .toSet();
    final collapsed = normalized.replaceAll(_collapseRegex, '');

    for (final bad in _blockedTokens) {
      if (tokens.contains(bad)) {
        return CommentModerationResult.blocked(
          sanitized: trimmed,
          issue: CommentModerationIssue.abusiveLanguage,
          matchedToken: bad,
        );
      }

      // Catch light obfuscation like "f.u.c.k" or "h_u_r_e".
      if (bad.length >= 4 && collapsed.contains(bad)) {
        return CommentModerationResult.blocked(
          sanitized: trimmed,
          issue: CommentModerationIssue.abusiveLanguage,
          matchedToken: bad,
        );
      }
    }

    return CommentModerationResult.allowed(trimmed);
  }

  static String _normalizeForMatch(String input) {
    return normalizeGermanKeyboardInput(input)
        .toLowerCase()
        .replaceAll('\u00e4', 'ae')
        .replaceAll('\u00f6', 'oe')
        .replaceAll('\u00fc', 'ue')
        .replaceAll('\u00df', 'ss')
        // Common leetspeak substitutions
        .replaceAll('0', 'o')
        .replaceAll('1', 'i')
        .replaceAll('3', 'e')
        .replaceAll('4', 'a')
        .replaceAll('5', 's')
        .replaceAll('7', 't')
        .replaceAll('8', 'b')
        .replaceAll('@', 'a')
        .replaceAll('\$', 's')
        .replaceAll('!', 'i')
        .replaceAll('|', 'i');
  }
}
