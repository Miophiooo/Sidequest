import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../daily_challenges.dart';
import '../../london_time.dart';

/// Today's quest, server-driven with a hardcoded fallback.
///
/// Source of truth is the `daily_quests` table (rotation via the
/// `get_daily_quest` RPC, same `2024-01-01` day-index anchor as the legacy
/// client list). When the server can't be reached the legacy
/// [kDailyChallenges] rotation keeps working, so the camera never blocks on
/// the network.
class DailyQuest {
  final String titleDe;
  final String titleEn;
  final String descDe;
  final String descEn;
  final String emoji;

  /// Username of the community member who proposed this quest, if any.
  final String? authorUsername;
  final bool isFromServer;

  const DailyQuest({
    required this.titleDe,
    required this.titleEn,
    required this.descDe,
    required this.descEn,
    required this.emoji,
    this.authorUsername,
    this.isFromServer = false,
  });

  Map<String, dynamic> toJson() => {
    'title_de': titleDe,
    'title_en': titleEn,
    'desc_de': descDe,
    'desc_en': descEn,
    'emoji': emoji,
    'author_username': authorUsername,
  };

  static DailyQuest? fromJson(Map<String, dynamic> json) {
    final titleDe = (json['title_de'] ?? '').toString().trim();
    final titleEn = (json['title_en'] ?? '').toString().trim();
    final descDe = (json['desc_de'] ?? '').toString().trim();
    final descEn = (json['desc_en'] ?? '').toString().trim();
    if (titleDe.isEmpty || titleEn.isEmpty) return null;

    final author = (json['author_username'] ?? '').toString().trim();
    return DailyQuest(
      titleDe: titleDe,
      titleEn: titleEn,
      descDe: descDe,
      descEn: descEn,
      emoji: (json['emoji'] ?? '📸').toString(),
      authorUsername: author.isEmpty ? null : author,
      isFromServer: true,
    );
  }
}

class DailyQuestService {
  DailyQuestService._();

  static const String _prefsKeyPrefix = 'daily_quest_v1_';

  static DailyQuest? _serverQuest;
  static String? _serverQuestDateStr;
  static Future<void>? _inflightLoad;

  /// Notifies listeners (quest cards) when the server quest for the active
  /// day arrives or changes.
  static final ChangeNotifier revision = ChangeNotifier();

  /// London challenge day the app should currently display.
  static DateTime activeLondonDay() {
    return activeLondonChallengeDayFromUtc(DateTime.now().toUtc());
  }

  /// Deterministic legacy rotation — identical to the pre-server behavior.
  static DailyQuest fallbackForLondonDay(DateTime londonDay) {
    final dayIndex = challengeDayIndexForLondonDay(londonDay);
    var idx = dayIndex % kDailyChallenges.length;
    if (idx < 0) idx += kDailyChallenges.length;
    final entry = kDailyChallenges[idx];
    return DailyQuest(
      titleDe: entry['de'] as String,
      titleEn: entry['en'] as String,
      descDe: entry['desc_de'] as String,
      descEn: entry['desc_en'] as String,
      emoji: (entry['emoji'] ?? '📸') as String,
    );
  }

  /// Best quest currently known for the active day, without touching the
  /// network: server quest if already loaded, legacy rotation otherwise.
  static DailyQuest currentForActiveDay() {
    final day = activeLondonDay();
    final dateStr = londonDateStrFromLondonDay(day);
    final server = _serverQuest;
    if (server != null && _serverQuestDateStr == dateStr) return server;
    return fallbackForLondonDay(day);
  }

  /// Loads the active day's quest from cache/server. Safe to call often —
  /// concurrent calls share one request, completed days are cached.
  static Future<void> ensureLoadedForActiveDay() {
    final dateStr = londonDateStrFromLondonDay(activeLondonDay());
    if (_serverQuest != null && _serverQuestDateStr == dateStr) {
      return Future<void>.value();
    }
    return _inflightLoad ??= _loadForDay(dateStr).whenComplete(() {
      _inflightLoad = null;
    });
  }

  static Future<void> _loadForDay(String dateStr) async {
    // 1. Local cache: survives app restarts within the same challenge day.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefsKeyPrefix$dateStr');
      if (raw != null && raw.isNotEmpty) {
        final cached = DailyQuest.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (cached != null) {
          _applyServerQuest(cached, dateStr);
          return;
        }
      }
    } catch (_) {}

    // 2. Server.
    try {
      final rows = await Supabase.instance.client.rpc(
        'get_daily_quest',
        params: {'p_london_date': dateStr},
      );
      final row = rows is List && rows.isNotEmpty ? rows.first : rows;
      if (row is! Map) return;
      final quest = DailyQuest.fromJson(Map<String, dynamic>.from(row));
      if (quest == null) return;

      _applyServerQuest(quest, dateStr);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          '$_prefsKeyPrefix$dateStr',
          jsonEncode(quest.toJson()),
        );
      } catch (_) {}
    } catch (e) {
      AppLogger.debug('Daily quest server load failed (using fallback): $e');
    }
  }

  static void _applyServerQuest(DailyQuest quest, String dateStr) {
    _serverQuest = quest;
    _serverQuestDateStr = dateStr;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    revision.notifyListeners();
  }

  /// Submits a community quest suggestion. Throws [QuestSuggestionException]
  /// with a user-presentable reason on known failures.
  static Future<void> submitSuggestion({
    required String title,
    required String description,
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw const QuestSuggestionException(QuestSuggestionError.notSignedIn);
    }

    final trimmedTitle = title.trim();
    final trimmedDescription = description.trim();
    if (trimmedTitle.length < 3 || trimmedDescription.length < 10) {
      throw const QuestSuggestionException(QuestSuggestionError.tooShort);
    }

    try {
      await client.from('quest_suggestions').insert({
        'user_id': userId,
        'title': trimmedTitle,
        'description': trimmedDescription,
      });
    } on PostgrestException catch (e) {
      final combined = '${e.message} ${e.details ?? ''}'.toLowerCase();
      if (combined.contains('suggestion_rate_limited')) {
        throw const QuestSuggestionException(
          QuestSuggestionError.rateLimited,
        );
      }
      rethrow;
    }
  }
}

enum QuestSuggestionError { notSignedIn, tooShort, rateLimited }

class QuestSuggestionException implements Exception {
  final QuestSuggestionError reason;

  const QuestSuggestionException(this.reason);
}
