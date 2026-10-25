// One-off helper: exports the legacy hardcoded quest rotation as SQL seed
// inserts for the `daily_quests` table. Run with:
//   dart run tools/export_quests_sql.dart
// Output: tools/daily_quests_seed.sql (UTF-8)
import 'dart:io';

import 'package:nummwe3/daily_challenges.dart';

String esc(String value) => value.replaceAll("'", "''");

void main() {
  final buffer = StringBuffer();
  buffer.writeln(
    '-- Seed for daily_quests, generated from lib/daily_challenges.dart '
    '(${kDailyChallenges.length} quests).',
  );
  buffer.writeln(
    'insert into public.daily_quests '
    '(rotation_index, title_de, title_en, desc_de, desc_en, emoji) values',
  );

  for (var i = 0; i < kDailyChallenges.length; i++) {
    final q = kDailyChallenges[i];
    final de = esc((q['de'] as String).trim());
    final en = esc((q['en'] as String).trim());
    final descDe = esc((q['desc_de'] as String).trim());
    final descEn = esc((q['desc_en'] as String).trim());
    final emoji = esc(((q['emoji'] ?? '📸') as String).trim());
    final suffix = i == kDailyChallenges.length - 1 ? ';' : ',';
    buffer.writeln(
      "  ($i, '$de', '$en', '$descDe', '$descEn', '$emoji')$suffix",
    );
  }

  File('tools/daily_quests_seed.sql').writeAsStringSync(buffer.toString());
  stdout.writeln('Wrote tools/daily_quests_seed.sql');
}
