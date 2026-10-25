import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../core/error_mapper.dart';
import '../../shared.dart';
import '../media/post_media.dart';

/// Report review for moderators (rows in `public.app_admins`). Every action
/// is checked again on the server; see the `moderation_*` RPCs.
class ModerationService {
  ModerationService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<bool> isAdmin() async {
    if (_client.auth.currentUser == null) return false;
    try {
      return await _client.rpc('is_app_admin') == true;
    } catch (e) {
      AppLogger.warn('is_app_admin failed: $e');
      return false;
    }
  }

  static Future<List<ModerationReport>> queue({
    bool includeReviewed = false,
  }) async {
    final rows = await _client.rpc(
      'moderation_queue',
      params: {'p_include_reviewed': includeReviewed},
    );
    return (rows as List? ?? const [])
        .whereType<Map>()
        .map((row) => ModerationReport.fromJson(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  static Future<void> dismiss(ModerationReport report) => _client.rpc(
    'moderation_dismiss_report',
    params: {'p_kind': report.kind, 'p_report_id': report.reportId},
  );

  static Future<void> deleteContent(ModerationReport report) async {
    if (report.kind == 'message') {
      await _client.rpc(
        'moderation_delete_message',
        params: {'p_message_id': report.messageId},
      );
    } else if (report.targetType == 'comment') {
      await _client.rpc(
        'moderation_delete_comment',
        params: {'p_comment_id': report.commentId},
      );
    } else {
      final result = await _client.rpc(
        'moderation_delete_photo',
        params: {'p_photo_id': report.photoId},
      );
      final paths = (result is Map ? result['storage_paths'] : null) as List?;
      final storagePaths = (paths ?? const [])
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          // List thumbnails sit next to the image (see post_media.dart).
          .expand(
            (path) =>
                path.endsWith('.mp4') ? [path] : [path, thumbnailPathFor(path)],
          )
          .toList(growable: false);
      if (storagePaths.isNotEmpty) {
        try {
          await _client.storage.from('photos').remove(storagePaths);
        } catch (e) {
          AppLogger.warn('Removing moderated photo files failed: $e');
        }
      }
    }
  }

  /// [days] null bans permanently.
  static Future<void> ban(String userId, {int? days}) => _client.rpc(
    'moderation_ban_user',
    params: {'p_user_id': userId, 'p_days': days},
  );

  static Future<void> unban(String userId) =>
      _client.rpc('moderation_unban_user', params: {'p_user_id': userId});
}

class ModerationReport {
  const ModerationReport({
    required this.kind,
    required this.reportId,
    required this.createdAt,
    required this.targetType,
    this.reporterName,
    this.reportedUserId,
    this.reportedName,
    this.reportedBannedUntil,
    this.reviewedAt,
    this.resolution,
    this.photoId,
    this.commentId,
    this.messageId,
    this.photoUrl,
    this.photoText,
    this.commentText,
    this.messageText,
    this.recentMessages = const [],
    this.openReportsOnTarget = 1,
  });

  /// 'content' or 'message'.
  final String kind;
  final String reportId;
  final DateTime? createdAt;

  /// 'photo', 'comment' or 'message'.
  final String targetType;
  final String? reporterName;
  final String? reportedUserId;
  final String? reportedName;
  final DateTime? reportedBannedUntil;
  final DateTime? reviewedAt;
  final String? resolution;
  final String? photoId;
  final String? commentId;
  final String? messageId;
  final String? photoUrl;
  final String? photoText;
  final String? commentText;
  final String? messageText;
  final List<Map<String, dynamic>> recentMessages;
  final int openReportsOnTarget;

  bool get isOpen => reviewedAt == null;

  bool get isBanned =>
      reportedBannedUntil != null &&
      reportedBannedUntil!.isAfter(DateTime.now());

  /// The reported content still exists and can be removed.
  bool get canDeleteContent => switch (targetType) {
    'photo' => photoId != null,
    'comment' => commentId != null,
    _ => messageId != null && messageText != null,
  };

  static DateTime? _date(dynamic value) =>
      value is String ? parseUtcTimestamp(value)?.toLocal() : null;

  static String? _str(dynamic value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  factory ModerationReport.fromJson(Map<String, dynamic> json) {
    return ModerationReport(
      kind: _str(json['kind']) ?? 'content',
      reportId: json['report_id'] as String,
      createdAt: _date(json['created_at']),
      targetType: _str(json['target_type']) ?? 'photo',
      reporterName: _str(json['reporter_name']),
      reportedUserId: _str(json['reported_user_id']),
      reportedName: _str(json['reported_name']),
      reportedBannedUntil: _date(json['reported_banned_until']),
      reviewedAt: _date(json['reviewed_at']),
      resolution: _str(json['resolution']),
      photoId: _str(json['photo_id']),
      commentId: _str(json['comment_id']),
      messageId: _str(json['message_id']),
      photoUrl: _str(json['photo_url']),
      photoText: _str(json['photo_text']),
      commentText: _str(json['comment_text']),
      messageText: _str(json['message_text']),
      recentMessages: (json['recent_messages'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(growable: false),
      openReportsOnTarget:
          (json['open_reports_on_target'] as num?)?.toInt() ?? 1,
    );
  }
}

class ModerationScreen extends StatefulWidget {
  const ModerationScreen({super.key});

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  static const _cardColor = Color(0xFF1A1A1A);
  static const _borderColor = Color(0xFF2D2D2D);
  static const _textSecondary = Color(0xFFAAAAAA);
  static const _danger = Color(0xFFE5484D);

  bool _includeReviewed = false;
  bool _loading = true;
  String? _error;
  List<ModerationReport> _reports = const [];
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final reports = await ModerationService.queue(
        includeReviewed: _includeReviewed,
      );
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _run(
    ModerationReport report,
    Future<void> Function() action,
    String doneMessage,
  ) async {
    setState(() => _busy.add(report.reportId));
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(doneMessage)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.describe(e))),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(report.reportId));
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(title, style: GoogleFonts.inter(color: Colors.white)),
        content: Text(body, style: GoogleFonts.inter(color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('Abbrechen', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action, style: const TextStyle(color: _danger)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteContent(ModerationReport report) async {
    final ok = await _confirm(
      t('Inhalt löschen?', 'Delete content?'),
      t(
        'Der Inhalt wird für alle entfernt. Das kann nicht rückgängig gemacht werden.',
        'The content is removed for everyone. This cannot be undone.',
      ),
      t('Löschen', 'Delete'),
    );
    if (!ok) return;
    await _run(
      report,
      () => ModerationService.deleteContent(report),
      t('Inhalt gelöscht', 'Content deleted'),
    );
  }

  Future<void> _ban(ModerationReport report) async {
    final userId = report.reportedUserId;
    if (userId == null) return;
    final days = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                t(
                  '${report.reportedName ?? 'Nutzer'} sperren',
                  'Ban ${report.reportedName ?? 'user'}',
                ),
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final option in const [1, 7, 30])
              ListTile(
                title: Text(
                  t(
                    option == 1 ? '1 Tag' : '$option Tage',
                    option == 1 ? '1 day' : '$option days',
                  ),
                  style: GoogleFonts.inter(color: Colors.white),
                ),
                onTap: () => Navigator.of(ctx).pop(option),
              ),
            ListTile(
              title: Text(
                t('Dauerhaft', 'Permanently'),
                style: GoogleFonts.inter(color: _danger),
              ),
              onTap: () => Navigator.of(ctx).pop(0),
            ),
          ],
        ),
      ),
    );
    if (days == null) return;
    await _run(
      report,
      () => ModerationService.ban(userId, days: days == 0 ? null : days),
      t('Nutzer gesperrt', 'User banned'),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.day)}.${two(date.month)}.${date.year} ${two(date.hour)}:${two(date.minute)}';
  }

  String _typeLabel(ModerationReport report) => switch (report.targetType) {
    'photo' => t('Post', 'Post'),
    'comment' => t('Kommentar', 'Comment'),
    _ => t('Nachricht', 'Message'),
  };

  String _resolutionLabel(String? resolution) => switch (resolution) {
    'dismissed' => t('Verworfen', 'Dismissed'),
    'content_removed' => t('Inhalt gelöscht', 'Content removed'),
    'user_banned' => t('Nutzer gesperrt', 'User banned'),
    _ => t('Erledigt', 'Done'),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        foregroundColor: Colors.white,
        title: Text(
          t('Moderation', 'Moderation'),
          style: GoogleFonts.inter(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: t('Aktualisieren', 'Refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            value: _includeReviewed,
            onChanged: (value) {
              setState(() => _includeReviewed = value);
              _load();
            },
            activeThumbColor: appGreen,
            title: Text(
              t('Erledigte anzeigen', 'Show reviewed'),
              style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _reports.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: appGreen));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('Laden fehlgeschlagen: $_error', 'Loading failed: $_error'),
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: _textSecondary),
          ),
        ),
      );
    }
    if (_reports.isEmpty) {
      return Center(
        child: Text(
          t('Keine offenen Meldungen 🎉', 'No open reports 🎉'),
          style: GoogleFonts.inter(color: _textSecondary, fontSize: 15),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: appGreen,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _reports.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _buildCard(_reports[index]),
      ),
    );
  }

  Widget _buildCard(ModerationReport report) {
    final busy = _busy.contains(report.reportId);
    final labelStyle = GoogleFonts.inter(
      color: _textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chip(_typeLabel(report), const Color(0xFF8DBEFF)),
              if (report.openReportsOnTarget > 1) ...[
                const SizedBox(width: 6),
                _chip(
                  t(
                    '${report.openReportsOnTarget}× gemeldet',
                    'Reported ${report.openReportsOnTarget}×',
                  ),
                  _danger,
                ),
              ],
              if (!report.isOpen) ...[
                const SizedBox(width: 6),
                _chip(_resolutionLabel(report.resolution), appGreen),
              ],
              const Spacer(),
              Text(_formatDate(report.createdAt), style: labelStyle),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            t(
              'Gemeldet: ${report.reportedName ?? 'unbekannt'}'
                  '${report.isBanned ? ' (gesperrt)' : ''}',
              'Reported: ${report.reportedName ?? 'unknown'}'
                  '${report.isBanned ? ' (banned)' : ''}',
            ),
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            t(
              'von ${report.reporterName ?? 'unbekannt'}',
              'by ${report.reporterName ?? 'unknown'}',
            ),
            style: labelStyle,
          ),
          const SizedBox(height: 10),
          _buildContentPreview(report),
          const SizedBox(height: 12),
          if (busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(6),
                child: CircularProgressIndicator(color: appGreen),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (report.isOpen)
                  _actionButton(
                    t('Verwerfen', 'Dismiss'),
                    Icons.check_rounded,
                    Colors.white,
                    () => _run(
                      report,
                      () => ModerationService.dismiss(report),
                      t('Meldung verworfen', 'Report dismissed'),
                    ),
                  ),
                if (report.canDeleteContent)
                  _actionButton(
                    t('Inhalt löschen', 'Delete content'),
                    Icons.delete_outline_rounded,
                    _danger,
                    () => _deleteContent(report),
                  ),
                if (report.reportedUserId != null && !report.isBanned)
                  _actionButton(
                    t('Sperren', 'Ban'),
                    Icons.block_rounded,
                    _danger,
                    () => _ban(report),
                  ),
                if (report.reportedUserId != null && report.isBanned)
                  _actionButton(
                    t('Entsperren', 'Unban'),
                    Icons.lock_open_rounded,
                    appGreen,
                    () => _run(
                      report,
                      () => ModerationService.unban(report.reportedUserId!),
                      t('Sperre aufgehoben', 'Ban lifted'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildContentPreview(ModerationReport report) {
    final textStyle = GoogleFonts.inter(
      color: Colors.white,
      fontSize: 14,
      height: 1.35,
    );
    final mutedStyle = GoogleFonts.inter(
      color: _textSecondary,
      fontSize: 13,
      fontStyle: FontStyle.italic,
    );

    if (report.kind == 'message') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            report.messageText ??
                t('Nachricht bereits gelöscht', 'Message already deleted'),
            style: report.messageText == null ? mutedStyle : textStyle,
          ),
          if (report.recentMessages.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              t(
                'Verlauf (vom Meldenden mitgeschickt):',
                'History (sent by the reporter):',
              ),
              style: mutedStyle,
            ),
            const SizedBox(height: 4),
            for (final message in report.recentMessages)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${message['sender_id'] == report.reportedUserId ? (report.reportedName ?? '?') : (report.reporterName ?? '?')}: ${message['message'] ?? ''}',
                  style: GoogleFonts.inter(color: _textSecondary, fontSize: 13),
                ),
              ),
          ],
        ],
      );
    }

    final hasPhoto = report.photoUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (report.targetType == 'comment')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              report.commentText != null
                  ? '„${report.commentText}“'
                  : t('Kommentar bereits gelöscht', 'Comment already deleted'),
              style: report.commentText == null ? mutedStyle : textStyle,
            ),
          ),
        if (hasPhoto)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: sideQuestNetworkImage(
                imageUrl: report.photoUrl,
                cacheWidth: sideQuestCacheWidth(context, 360),
                errorWidget: Container(
                  color: const Color(0xFF222222),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    color: _textSecondary,
                  ),
                ),
              ),
            ),
          )
        else if (report.targetType == 'photo')
          Text(
            t('Post bereits gelöscht', 'Post already deleted'),
            style: mutedStyle,
          ),
        if (report.photoText != null && report.targetType == 'photo') ...[
          const SizedBox(height: 8),
          Text(report.photoText!, style: textStyle),
        ],
      ],
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _actionButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback onPressed,
  ) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    );
  }
}
