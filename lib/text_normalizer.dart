import 'dart:convert';

const Map<int, int> _cp1252ExtensionBytes = <int, int>{
  0x20AC: 0x80,
  0x201A: 0x82,
  0x0192: 0x83,
  0x201E: 0x84,
  0x2026: 0x85,
  0x2020: 0x86,
  0x2021: 0x87,
  0x02C6: 0x88,
  0x2030: 0x89,
  0x0160: 0x8A,
  0x2039: 0x8B,
  0x0152: 0x8C,
  0x017D: 0x8E,
  0x2018: 0x91,
  0x2019: 0x92,
  0x201C: 0x93,
  0x201D: 0x94,
  0x2022: 0x95,
  0x2013: 0x96,
  0x2014: 0x97,
  0x02DC: 0x98,
  0x2122: 0x99,
  0x0161: 0x9A,
  0x203A: 0x9B,
  0x0153: 0x9C,
  0x017E: 0x9E,
  0x0178: 0x9F,
};

bool _looksLikeMojibake(String value) {
  return value.contains('\u00c3') ||
      value.contains('\u00c2') ||
      value.contains('\u00c5') ||
      value.contains('\u00c6') ||
      value.contains('\u0192') ||
      value.contains('\u00e2\u20ac') ||
      value.contains('\u00f0');
}

int? _singleByteByteForRune(int rune) {
  if (rune <= 0xFF) return rune;
  return _cp1252ExtensionBytes[rune];
}

String _decodeSingleByteAsUtf8(String value) {
  final output = StringBuffer();
  final currentBytes = <int>[];
  final currentRunes = <int>[];

  void flush() {
    if (currentBytes.isEmpty) return;
    try {
      output.write(utf8.decode(currentBytes));
    } on FormatException {
      output.write(String.fromCharCodes(currentRunes));
    }
    currentBytes.clear();
    currentRunes.clear();
  }

  for (final rune in value.runes) {
    final mapped = _singleByteByteForRune(rune);
    if (mapped == null) {
      flush();
      output.writeCharCode(rune);
      continue;
    }

    currentBytes.add(mapped);
    currentRunes.add(rune);
  }

  flush();
  return output.toString();
}

String repairMojibake(String value) {
  var current = value;
  for (var i = 0; i < 8; i++) {
    if (!_looksLikeMojibake(current)) break;
    final repaired = _decodeSingleByteAsUtf8(current);
    if (repaired == current) break;
    current = repaired;
  }
  return current;
}

String normalizeGermanKeyboardInput(String value) {
  var normalized = repairMojibake(value);

  const replacements = <String, String>{
    'a\u0308': '\u00e4',
    'o\u0308': '\u00f6',
    'u\u0308': '\u00fc',
    'A\u0308': '\u00c4',
    'O\u0308': '\u00d6',
    'U\u0308': '\u00dc',
    '\u0308a': '\u00e4',
    '\u0308o': '\u00f6',
    '\u0308u': '\u00fc',
    '\u0308A': '\u00c4',
    '\u0308O': '\u00d6',
    '\u0308U': '\u00dc',
    '\u00a8a': '\u00e4',
    '\u00a8o': '\u00f6',
    '\u00a8u': '\u00fc',
    '\u00a8A': '\u00c4',
    '\u00a8O': '\u00d6',
    '\u00a8U': '\u00dc',
    'a\u00a8': '\u00e4',
    'o\u00a8': '\u00f6',
    'u\u00a8': '\u00fc',
    'A\u00a8': '\u00c4',
    'O\u00a8': '\u00d6',
    'U\u00a8': '\u00dc',
  };

  replacements.forEach((from, to) {
    normalized = normalized.replaceAll(from, to);
  });

  return normalized;
}
