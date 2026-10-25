import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_logger.dart';
import 'profile.dart';
import 'shared.dart';
import 'username_filter.dart';

enum MentionEntityKind { comment, description }

class MentionSuggestion {
  final String id;
  final String username;
  final String? profilePicture;

  const MentionSuggestion({
    required this.id,
    required this.username,
    required this.profilePicture,
  });
}

class MentionText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final TextStyle? mentionStyle;
  final int? maxLines;
  final TextOverflow overflow;
  final bool enableProfileNavigation;

  const MentionText({
    super.key,
    required this.text,
    required this.style,
    this.mentionStyle,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.enableProfileNavigation = false,
  });

  @override
  State<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends State<MentionText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _buildRecognizer(String username) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        MentionService.openProfileForUsername(context, username);
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();

    return RichText(
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      text: TextSpan(
        children: MentionService.buildTextSpans(
          widget.text,
          style: widget.style,
          mentionStyle:
              widget.mentionStyle ??
              widget.style.copyWith(
                color: const Color(0xFFAAD68F),
                fontWeight: FontWeight.w700,
              ),
          recognizerBuilder: widget.enableProfileNavigation
              ? _buildRecognizer
              : null,
        ),
      ),
    );
  }
}

class MentionAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final bool readOnly;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final int? maxLength;
  final int? minLines;
  final int? maxLines;
  final EdgeInsets scrollPadding;

  const MentionAutocompleteField({
    super.key,
    required this.controller,
    required this.decoration,
    this.style,
    this.focusNode,
    this.readOnly = false,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.onSubmitted,
    this.maxLength,
    this.minLines,
    this.maxLines = 1,
    this.scrollPadding = EdgeInsets.zero,
  });

  @override
  State<MentionAutocompleteField> createState() =>
      _MentionAutocompleteFieldState();
}

class _MentionAutocompleteFieldState extends State<MentionAutocompleteField> {
  final FocusNode _internalFocusNode = FocusNode();
  final List<MentionSuggestion> _suggestions = [];
  Timer? _debounce;
  bool _loading = false;
  int _requestId = 0;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onTextChanged);
    _debounce?.cancel();
    _internalFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _refreshSuggestions);
  }

  Future<void> _refreshSuggestions() async {
    final activeMention = MentionService.findActiveMention(
      widget.controller.text,
      widget.controller.selection.baseOffset,
    );

    if (!_focusNode.hasFocus ||
        widget.readOnly ||
        activeMention == null ||
        activeMention.query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _suggestions.clear();
      });
      return;
    }

    final requestId = ++_requestId;
    setState(() => _loading = true);

    final results = await MentionService.searchSuggestions(activeMention.query);
    if (!mounted || requestId != _requestId) return;

    setState(() {
      _loading = false;
      _suggestions
        ..clear()
        ..addAll(results);
    });
  }

  void _applySuggestion(MentionSuggestion suggestion) {
    MentionService.replaceActiveMention(widget.controller, suggestion.username);
    setState(() => _suggestions.clear());
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final suggestionBox =
        _focusNode.hasFocus && (_loading || _suggestions.isNotEmpty)
        ? Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: const Color(0xFF191919),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                    itemBuilder: (context, index) {
                      final suggestion = _suggestions[index];
                      return ListTile(
                        dense: true,
                        onTap: () => _applySuggestion(suggestion),
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: const Color(0xFF262626),
                          backgroundImage: suggestion.profilePicture != null
                              ? sideQuestCachedImageProvider(
                                  suggestion.profilePicture!,
                                  cacheWidth: sideQuestCacheWidth(context, 32),
                                  cacheHeight: sideQuestCacheWidth(context, 32),
                                )
                              : null,
                          child: suggestion.profilePicture == null
                              ? Text(
                                  suggestion.username.isNotEmpty
                                      ? suggestion.username[0].toUpperCase()
                                      : 'U',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          '@${suggestion.username}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    },
                  ),
          )
        : const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          readOnly: widget.readOnly,
          keyboardType: widget.keyboardType,
          textCapitalization: widget.textCapitalization,
          textInputAction: widget.textInputAction,
          onSubmitted: widget.onSubmitted,
          maxLength: widget.maxLength,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          scrollPadding: widget.scrollPadding,
          style: widget.style,
          decoration: widget.decoration,
        ),
        suggestionBox,
      ],
    );
  }
}

class ActiveMentionQuery {
  final int start;
  final int end;
  final String query;

  const ActiveMentionQuery({
    required this.start,
    required this.end,
    required this.query,
  });
}

class MentionService {
  static final RegExp _mentionRegex = RegExp(
    '(^|[^${UsernameFilter.allowedCharacterClass}])'
    '@([${UsernameFilter.allowedCharacterClass}]{${UsernameFilter.minLength},${UsernameFilter.maxLength}})',
  );

  static final RegExp _activeMentionRegex = RegExp(
    '(^|[\\s\\n\\(\\[\\{])'
    '@([${UsernameFilter.allowedCharacterClass}]{1,${UsernameFilter.maxLength}})\$',
  );

  static Set<String> extractMentionUsernames(String text) {
    final usernames = <String>{};
    for (final match in _mentionRegex.allMatches(text)) {
      final raw = match.group(2);
      if (raw == null || raw.isEmpty) continue;
      final validation = UsernameFilter.validate(raw);
      if (validation.isValid) {
        usernames.add(UsernameFilter.comparisonKey(validation.normalized));
      }
    }
    return usernames;
  }

  static List<InlineSpan> buildTextSpans(
    String text, {
    required TextStyle style,
    required TextStyle mentionStyle,
    GestureRecognizer Function(String username)? recognizerBuilder,
  }) {
    if (text.isEmpty) {
      return [TextSpan(text: '', style: style)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _mentionRegex.allMatches(text)) {
      final prefix = match.group(1) ?? '';
      final username = match.group(2) ?? '';
      final mentionStart = match.start + prefix.length;
      final mentionEnd = match.end;

      if (mentionStart < cursor || mentionEnd <= mentionStart) continue;

      if (mentionStart > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, mentionStart), style: style),
        );
      }

      final normalized = UsernameFilter.normalize(username);
      spans.add(
        TextSpan(
          text: text.substring(mentionStart, mentionEnd),
          style: mentionStyle,
          recognizer: recognizerBuilder?.call(normalized),
        ),
      );
      cursor = mentionEnd;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: style));
    }

    return spans;
  }

  static ActiveMentionQuery? findActiveMention(String text, int cursorOffset) {
    final safeCursor = cursorOffset < 0 ? text.length : cursorOffset;
    if (safeCursor > text.length) return null;
    final beforeCursor = text.substring(0, safeCursor);
    final match = _activeMentionRegex.firstMatch(beforeCursor);
    if (match == null) return null;

    final rawQuery = match.group(2) ?? '';
    final normalizedQuery = UsernameFilter.normalize(rawQuery);
    if (normalizedQuery.isEmpty) return null;

    final start = safeCursor - rawQuery.length - 1;
    return ActiveMentionQuery(
      start: start,
      end: safeCursor,
      query: normalizedQuery,
    );
  }

  static void replaceActiveMention(
    TextEditingController controller,
    String username,
  ) {
    final activeMention = findActiveMention(
      controller.text,
      controller.selection.baseOffset,
    );
    if (activeMention == null) return;

    final replacement = '@${UsernameFilter.normalize(username)} ';
    final newText =
        controller.text.substring(0, activeMention.start) +
        replacement +
        controller.text.substring(activeMention.end);
    final newCursor = activeMention.start + replacement.length;

    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  static Future<List<MentionSuggestion>> searchSuggestions(String query) async {
    final normalized = UsernameFilter.normalize(query);
    final comparisonKey = UsernameFilter.comparisonKey(query);
    if (normalized.isEmpty || comparisonKey.isEmpty) return const [];

    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id;

    try {
      final rows = await client
          .from('users_profile')
          .select('id, username, profile_picture')
          .ilike('username', '$normalized%')
          .limit(8);

      return List<Map<String, dynamic>>.from(
            (rows as List).map((row) => Map<String, dynamic>.from(row)),
          )
          .where((row) {
            final id = (row['id'] ?? '').toString();
            final usernameKey = UsernameFilter.comparisonKey(
              (row['username'] ?? '').toString(),
            );
            return id.isNotEmpty &&
                id != currentUserId &&
                usernameKey.startsWith(comparisonKey);
          })
          .map(
            (row) => MentionSuggestion(
              id: (row['id'] ?? '').toString(),
              username: (row['username'] ?? '').toString(),
              profilePicture:
                  (row['profile_picture'] ?? '').toString().trim().isEmpty
                  ? null
                  : (row['profile_picture'] ?? '').toString(),
            ),
          )
          .take(6)
          .toList(growable: false);
    } catch (e) {
      AppLogger.debug('Mention suggestion lookup failed: $e');
      return const [];
    }
  }

  static Future<Map<String, dynamic>?> loadProfileByUsername(
    String username,
  ) async {
    final normalized = UsernameFilter.normalize(username.replaceFirst('@', ''));
    if (normalized.isEmpty) return null;

    try {
      final client = Supabase.instance.client;
      final row = await client
          .from('users_profile')
          .select('id, username, profile_picture')
          .ilike('username', normalized)
          .limit(1)
          .maybeSingle();

      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (e) {
      AppLogger.debug('Mention profile lookup failed: $e');
      return null;
    }
  }

  static Future<void> openProfileForUsername(
    BuildContext context,
    String username,
  ) async {
    final profile = await loadProfileByUsername(username);
    final userId = (profile?['id'] ?? '').toString();
    if (!context.mounted || userId.isEmpty) return;

    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
    if (userId == currentUserId) {
      requestMainTabNavigation(3);
      Navigator.of(
        context,
        rootNavigator: true,
      ).popUntil((route) => route.isFirst);
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
    );
  }

  static Future<void> createMentionNotifications({
    required String text,
    required MentionEntityKind entityKind,
    String? photoId,
    String? commentId,
  }) async {
    final mentionedUsernames = extractMentionUsernames(text);
    if (mentionedUsernames.isEmpty) return;

    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) return;

    try {
      final filters = mentionedUsernames
          .map((username) => 'username.ilike.$username')
          .join(',');
      if (filters.isEmpty) return;

      final rows = await client
          .from('users_profile')
          .select('id, username')
          .or(filters);

      final recipientIds = <String>{
        for (final raw in rows as List)
          if ((raw['id'] ?? '').toString().isNotEmpty &&
              (raw['id'] ?? '').toString() != currentUserId &&
              mentionedUsernames.contains(
                UsernameFilter.comparisonKey(
                  (raw['username'] ?? '').toString(),
                ),
              ))
            (raw['id'] ?? '').toString(),
      }.toList();

      if (recipientIds.isEmpty) return;

      final normalizedPhotoId = (photoId ?? '').trim().isEmpty ? null : photoId;
      final normalizedCommentId = (commentId ?? '').trim().isEmpty
          ? null
          : commentId;

      try {
        await client.rpc(
          'create_mention_notifications_v2',
          params: {
            'p_recipient_ids': recipientIds,
            'p_source_text': text,
            'p_entity_kind': entityKind.name,
            'p_photo_id': normalizedPhotoId,
            'p_comment_id': normalizedCommentId,
          },
        );
      } catch (_) {
        try {
          await client.rpc(
            'create_mention_notifications_v2',
            params: {
              'p_recipient_ids': recipientIds,
              'p_source_text': text,
              'p_entity_kind': entityKind.name,
              'p_photo_id': normalizedPhotoId,
            },
          );
        } catch (_) {
          await client.rpc(
            'create_mention_notifications',
            params: {
              'p_recipient_ids': recipientIds,
              'p_source_text': text,
              'p_entity_kind': entityKind.name,
            },
          );
        }
      }
    } catch (e) {
      AppLogger.debug('Mention notification dispatch failed: $e');
    }
  }
}
