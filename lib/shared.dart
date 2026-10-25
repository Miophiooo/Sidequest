import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/app_environment.dart';
import 'core/app_logger.dart';
import 'core/signed_storage_media.dart';
import 'text_normalizer.dart';

const appGreen = Color(0xFFAAD68F);

// Slightly darker accent variant used for smaller highlights/buttons.
const appGreenAccentDark = appGreen;

// ── Motion System ──────────────────────────────────────────────────────
// Centralised timing & easing constants for a consistent, premium feel.

/// Ultra-fast: hover/press states, micro-feedback.
const kDurationUltraFast = Duration(milliseconds: 120);

/// Fast: switches, small state changes, icon swaps.
const kDurationFast = Duration(milliseconds: 200);

/// Medium: content transitions, list entry animations.
const kDurationMedium = Duration(milliseconds: 300);

/// Slow: page/modal reveals, overlay introductions.
const kDurationSlow = Duration(milliseconds: 450);

/// Network photo appearing over its placeholder once loaded.
const kDurationImageFadeIn = Duration(milliseconds: 150);

/// Placeholder fading out underneath a loaded photo.
const kDurationImageFadeOut = Duration(milliseconds: 100);

/// Default easing for outgoing / appearing motion.
const kCurveStandard = Curves.easeOutCubic;

/// Elements appearing (fade-in, slide-in).
const kCurveEnter = Curves.easeOut;

/// Elements disappearing.
const kCurveExit = Curves.easeIn;

/// Subtle emphasis pop (reactions, selection confirms). Use sparingly.
const kCurveEmphasis = Curves.easeOutBack;

/// Symmetrical curve for programmatic scroll-to / two-way animations.
const kCurveSymmetric = Curves.easeInOutCubic;

/// Standard slide distance for list-item entry animations (px).
const kSlideEntryOffset = 16.0;

/// Tiny slide for AnimatedSwitcher content swaps (fractional Offset.dy).
const kSwitcherSlideOffset = Offset(0, 0.02);

/// Fades [child] in and slides it up by [offsetY] px once, when first built.
///
/// Looks the same as a `TweenAnimationBuilder` driving `Opacity` +
/// `Transform.translate`, but cheaper per frame: the fade is applied on the
/// compositing layer (`FadeTransition`) and the child sits behind a
/// `RepaintBoundary`, so the child isn't repainted on every animation tick.
/// Like `TweenAnimationBuilder`, a new [key] restarts the animation.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.duration = kDurationMedium,
    this.curve = kCurveStandard,
    this.opacityCurve,
    this.offsetY = kSlideEntryOffset,
  });

  final Widget child;
  final Duration duration;

  /// Curve of the animation progress (drives the slide and the fade).
  final Curve curve;

  /// Optional extra curve applied on top of [curve] for the opacity only.
  final Curve? opacityCurve;

  /// Start offset in logical pixels below the final position.
  final double offsetY;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );
  late final Animation<double> _opacity = widget.opacityCurve == null
      ? _progress
      : CurvedAnimation(parent: _progress, curve: widget.opacityCurve!);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _progress,
        // Don't stack a second boundary when the caller already set one.
        child: widget.child is RepaintBoundary
            ? widget.child
            : RepaintBoundary(child: widget.child),
        builder: (context, child) => Transform.translate(
          offset: Offset(0, widget.offsetY * (1 - _progress.value)),
          child: child,
        ),
      ),
    );
  }
}

// Global signal for cross-tab refreshes after posts/streak/joker updates.
final ValueNotifier<int> postDataRefreshNotifier = ValueNotifier<int>(0);
final ValueNotifier<int?> mainTabNavigationRequestNotifier =
    ValueNotifier<int?>(null);
final ValueNotifier<PostFocusRequest?> postFocusRequestNotifier =
    ValueNotifier<PostFocusRequest?>(null);
final ValueNotifier<ChatOpenRequest?> chatOpenRequestNotifier =
    ValueNotifier<ChatOpenRequest?>(null);
final ValueNotifier<bool> comboComposeFlowActiveNotifier = ValueNotifier<bool>(
  false,
);
final ValueNotifier<bool> passwordRecoveryModeNotifier = ValueNotifier<bool>(
  false,
);

class PostFocusRequest {
  final int tabIndex;
  final String photoId;
  final String? commentId;
  final String? todayFeedFilter;

  const PostFocusRequest({
    required this.tabIndex,
    required this.photoId,
    this.commentId,
    this.todayFeedFilter,
  });
}

class ChatOpenRequest {
  final String friendId;
  final String? messageId;

  const ChatOpenRequest({required this.friendId, this.messageId});
}

void notifyPostDataChanged() {
  postDataRefreshNotifier.value = postDataRefreshNotifier.value + 1;
}

void requestMainTabNavigation(int tabIndex) {
  mainTabNavigationRequestNotifier.value = tabIndex;
}

void requestPostFocus(PostFocusRequest request) {
  postFocusRequestNotifier.value = request;
}

void clearPostFocusRequest() {
  postFocusRequestNotifier.value = null;
}

void requestChatOpen(ChatOpenRequest request) {
  chatOpenRequestNotifier.value = request;
}

void clearChatOpenRequest() {
  chatOpenRequestNotifier.value = null;
}

void setComboComposeFlowActive(bool active) {
  comboComposeFlowActiveNotifier.value = active;
}

void setPasswordRecoveryMode(bool active) {
  passwordRecoveryModeNotifier.value = active;
}

void _handleNotificationPayload(String? payload) {
  final trimmedPayload = payload?.trim() ?? '';
  if (trimmedPayload.isEmpty) return;

  try {
    final decoded = jsonDecode(trimmedPayload);
    if (decoded is! Map) return;

    final data = <String, String>{};
    decoded.forEach((key, value) {
      if (key == null || value == null) return;
      data[key.toString()] = value.toString();
    });

    final targetTab = int.tryParse((data['target_tab'] ?? '').trim());
    if (targetTab != null) {
      requestMainTabNavigation(targetTab);
    }

    final kind = (data['kind'] ?? '').trim();
    final senderId = (data['sender_id'] ?? '').trim();
    final messageId = (data['message_id'] ?? '').trim();
    if (senderId.isNotEmpty &&
        (kind == 'message' || kind == 'message_reaction')) {
      requestChatOpen(
        ChatOpenRequest(
          friendId: senderId,
          messageId: messageId.isEmpty ? null : messageId,
        ),
      );
      return;
    }

    final photoId = (data['photo_id'] ?? '').trim();
    if (targetTab != null && photoId.isNotEmpty) {
      final commentId = (data['comment_id'] ?? '').trim();
      requestPostFocus(
        PostFocusRequest(
          tabIndex: targetTab,
          photoId: photoId,
          commentId: commentId.isEmpty ? null : commentId,
        ),
      );
    }
  } catch (_) {
    // Ignore malformed payloads so notification delivery keeps working.
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  _handleNotificationPayload(response.payload);
}

int sideQuestCacheWidth(
  BuildContext context,
  double logicalWidth, {
  double multiplier = 1.0,
}) {
  final pixels =
      logicalWidth * MediaQuery.of(context).devicePixelRatio * multiplier;
  return pixels.round().clamp(32, 4096);
}

/// Toggle for Supabase's on-the-fly image transformation API.
/// REQUIRES Pro plan. On Free plan the `/storage/v1/render/image/` endpoint
/// returns 400, so we keep this off and compress on upload instead (see
/// `compressImageForUpload`). Flip to true when you upgrade to Pro.
const bool kSupabaseImageTransformsEnabled = false;

/// Rewrites a Supabase Storage public URL to use the on-the-fly image
/// transformation endpoint when enabled. On Free plan this is a no-op
/// passthrough — bandwidth savings come from upload-time compression
/// instead.
String? sideQuestThumbnailUrl(
  String? url, {
  int? width,
  int? height,
  int quality = 70,
}) {
  if (url == null) return null;
  final trimmed = url.trim();
  if (trimmed.isEmpty) return trimmed;
  if (!kSupabaseImageTransformsEnabled) return trimmed;
  if (width == null && height == null) return trimmed;
  if (!trimmed.contains('/storage/v1/object/')) return trimmed;

  final transformed = trimmed.replaceFirst(
    '/storage/v1/object/',
    '/storage/v1/render/image/',
  );
  final params = <String>[];
  if (width != null && width > 0) params.add('width=$width');
  if (height != null && height > 0) params.add('height=$height');
  params.add('quality=${quality.clamp(20, 100)}');
  params.add('resize=cover');
  final separator = transformed.contains('?') ? '&' : '?';
  return '$transformed$separator${params.join('&')}';
}

final String _sideQuestMediaHost =
    Uri.tryParse(AppEnvironment.supabaseUrl)?.host ?? '';

/// Only images from our own Supabase project are loaded. A URL pasted into a
/// chat message or a profile_picture pointing elsewhere would otherwise act
/// as a tracking pixel that logs every viewer's IP address.
bool isTrustedSideQuestMediaUrl(String? url) {
  final uri = Uri.tryParse(url?.trim() ?? '');
  return uri != null &&
      uri.scheme == 'https' &&
      _sideQuestMediaHost.isNotEmpty &&
      uri.host == _sideQuestMediaHost;
}

ImageProvider<Object>? sideQuestCachedImageProvider(
  String? imageUrl, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  final trimmedUrl = imageUrl?.trim() ?? '';
  if (trimmedUrl.isEmpty || !isTrustedSideQuestMediaUrl(trimmedUrl)) {
    return null;
  }
  final normalizedWidth = cacheWidth != null && cacheWidth > 0
      ? cacheWidth
      : null;
  final normalizedHeight = cacheHeight != null && cacheHeight > 0
      ? cacheHeight
      : null;
  return CachedNetworkImageProvider(
    trimmedUrl,
    maxWidth: normalizedWidth,
    maxHeight: normalizedHeight,
    cacheManager: sideQuestCacheManagerFor(trimmedUrl),
  );
}

Widget sideQuestNetworkImage({
  required String? imageUrl,
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
  int? cacheWidth,
  int? cacheHeight,
  Alignment alignment = Alignment.center,
  FilterQuality filterQuality = FilterQuality.low,
  Widget? errorWidget,
  Widget? placeholder,
}) {
  final trimmedUrl = imageUrl?.trim() ?? '';
  if (trimmedUrl.isEmpty || !isTrustedSideQuestMediaUrl(trimmedUrl)) {
    return errorWidget ?? const SizedBox.shrink();
  }

  final normalizedWidth = cacheWidth != null && cacheWidth > 0
      ? cacheWidth
      : null;
  final normalizedHeight = cacheHeight != null && cacheHeight > 0
      ? cacheHeight
      : null;

  return CachedNetworkImage(
    imageUrl: trimmedUrl,
    cacheManager: sideQuestCacheManagerFor(trimmedUrl),
    fit: fit,
    width: width,
    height: height,
    alignment: alignment,
    filterQuality: filterQuality,
    // Short cross-fade when a photo finishes loading instead of a hard pop.
    // Images already in the memory cache still show instantly (no fade).
    fadeInDuration: kDurationImageFadeIn,
    fadeInCurve: kCurveEnter,
    fadeOutDuration: kDurationImageFadeOut,
    fadeOutCurve: kCurveExit,
    placeholderFadeInDuration: Duration.zero,
    // Only constrain width for in-memory decode to preserve aspect ratio.
    // Setting both memCacheWidth and memCacheHeight forces exact dimensions
    // which distorts photos whose aspect ratio doesn't match.
    memCacheWidth: normalizedWidth,
    memCacheHeight: normalizedWidth != null ? null : normalizedHeight,
    maxWidthDiskCache: normalizedWidth != null
        ? (normalizedWidth * 2).clamp(64, 4096)
        : null,
    maxHeightDiskCache: normalizedHeight != null
        ? (normalizedHeight * 2).clamp(64, 4096)
        : null,
    placeholder: (context, url) =>
        placeholder ?? Container(color: const Color(0xFF2A2A2A)),
    errorWidget: (context, url, error) =>
        errorWidget ?? Container(color: const Color(0xFF1E1E1E)),
  );
}

bool sideQuestLooksLikeDuplicateConstraintError(
  Object error, {
  String? constraint,
}) {
  if (error is! PostgrestException) return false;
  if (error.code == '23505') {
    if (constraint == null || constraint.isEmpty) return true;
  }

  final combined = '${error.message} ${error.details ?? ''} ${error.hint ?? ''}'
      .toLowerCase();
  final normalizedConstraint = (constraint ?? '').trim().toLowerCase();

  if (normalizedConstraint.isNotEmpty &&
      combined.contains(normalizedConstraint)) {
    return true;
  }

  return combined.contains('duplicate') || combined.contains('unique');
}

Future<void> sideQuestPersistCommentLike({
  required SupabaseClient client,
  required String commentId,
  required String userId,
  required bool shouldLike,
}) async {
  if (commentId.isEmpty || userId.isEmpty) return;

  if (!shouldLike) {
    await client
        .from('comment_likes')
        .delete()
        .eq('comment_id', commentId)
        .eq('user_id', userId);
    return;
  }

  try {
    await client.from('comment_likes').upsert({
      'comment_id': commentId,
      'user_id': userId,
      'created_at': DateTime.now().toIso8601String(),
    }, onConflict: 'comment_id,user_id');
  } on PostgrestException catch (error) {
    if (!sideQuestLooksLikeDuplicateConstraintError(
      error,
      constraint: 'comment_likes_comment_id_user_id_key',
    )) {
      rethrow;
    }
  }
}

double sideQuestResponsiveScale(
  BuildContext context, {
  double designShortestSide = 390,
  double minScale = 0.88,
  double maxScale = 1.0,
}) {
  return sideQuestAdaptiveLayoutOf(context).scale(
    designShortestSide: designShortestSide,
    minScale: minScale,
    maxScale: maxScale,
  );
}

double sideQuestResponsiveSize(
  BuildContext context,
  double base, {
  double minScale = 0.88,
  double maxScale = 1.0,
  double designShortestSide = 390,
}) {
  return sideQuestAdaptiveLayoutOf(context).responsiveSize(
    base,
    designShortestSide: designShortestSide,
    minScale: minScale,
    maxScale: maxScale,
  );
}

class SideQuestAdaptiveLayout {
  final Size size;

  const SideQuestAdaptiveLayout(this.size);

  double get width => size.width;
  double get height => size.height;
  double get shortestSide => size.shortestSide;
  bool get isCompactHeight => height < 760;
  bool get isNarrowWidth => width < 380;
  bool get isUltraNarrowWidth => width < 360;

  double scale({
    double designShortestSide = 390,
    double minScale = 0.88,
    double maxScale = 1.0,
  }) {
    return (shortestSide / designShortestSide)
        .clamp(minScale, maxScale)
        .toDouble();
  }

  double responsiveSize(
    double base, {
    double designShortestSide = 390,
    double minScale = 0.88,
    double maxScale = 1.0,
  }) {
    return base *
        scale(
          designShortestSide: designShortestSide,
          minScale: minScale,
          maxScale: maxScale,
        );
  }

  double get bottomNavHeight => isNarrowWidth
      ? 52
      : isCompactHeight
      ? 56
      : 60;
  double get bottomNavOuterInset => isNarrowWidth
      ? 16
      : isCompactHeight
      ? 18
      : 20;
  double get bottomNavInnerPadding => isNarrowWidth
      ? 10
      : isCompactHeight
      ? 16
      : 20;
  double get bottomNavIconSize => isNarrowWidth
      ? 24
      : isCompactHeight
      ? 27
      : 30;
  double get bottomNavAvatarSize => isNarrowWidth
      ? 32
      : isCompactHeight
      ? 34
      : 36;

  double bottomNavBottomOffset({required bool isKeyboardOpen}) {
    if (isKeyboardOpen) return 8;
    if (isNarrowWidth) return 10;
    if (isCompactHeight) return 12;
    return 24;
  }
}

SideQuestAdaptiveLayout sideQuestAdaptiveLayoutOf(BuildContext context) {
  return SideQuestAdaptiveLayout(MediaQuery.sizeOf(context));
}

SideQuestAdaptiveLayout sideQuestAdaptiveLayoutForSize(Size size) {
  return SideQuestAdaptiveLayout(size);
}

class SideQuestDecorations {
  static final BoxDecoration statCardDecoration = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.10),
        blurRadius: 26,
        offset: const Offset(0, 14),
      ),
    ],
  );
}

final LanguageController languageController = LanguageController();

class LanguageController extends ChangeNotifier {
  String _lang = 'de';
  SharedPreferences? _prefs;

  String get lang => _lang;
  Locale get locale => Locale(_lang);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getString('app_language');
    if (saved != null && (saved == 'de' || saved == 'en')) {
      _lang = saved;
    } else {
      final systemCode =
          WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      _lang = systemCode == 'de' ? 'de' : 'en';
      await _prefs?.setString('app_language', _lang);
    }
  }

  Future<void> setLanguage(String code) async {
    if (code != 'de' && code != 'en') return;
    if (code == _lang) return;
    _lang = code;
    await _prefs?.setString('app_language', code);
    notifyListeners();
    await syncToProfile();
  }

  /// Pushes are written in this language (users_profile.language).
  Future<void> syncToProfile() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      await client
          .from('users_profile')
          .update({'language': _lang})
          .eq('id', userId);
    } catch (e) {
      AppLogger.debug('Saving the app language failed: $e');
    }
  }
}

String t(String de, String en) =>
    repairMojibake(languageController.lang == 'en' ? en : de);

bool isImagePickerAccessDenied(PlatformException error) {
  final code = error.code.trim().toLowerCase();
  return code == 'camera_access_denied' ||
      code == 'camera_access_restricted' ||
      code == 'photo_access_denied' ||
      code == 'photo_access_restricted';
}

String imagePickerAccessDeniedMessage({bool cameraOnly = false}) {
  return cameraOnly
      ? t(
          'Kein Kamerazugriff. Bitte erlaube die Kamera in den Einstellungen und versuche es erneut.',
          'No camera access. Please allow camera access in Settings and try again.',
        )
      : t(
          'Kein Zugriff auf Kamera oder Fotos. Bitte erlaube den Zugriff in den Einstellungen und versuche es erneut.',
          'No camera or photo access. Please allow access in Settings and try again.',
        );
}

// Streak flame tiers, derived purely from the `flames` counter on the
// profile. The DB never stores a tier — when `flames` resets to 1 (missed
// day, Snapchat-style), the icon goes back to orange automatically.
//
// Thresholds:
//   < 3   -> orange
//   3-6   -> green
//   7-29  -> blue
//   >= 30 -> rainbow (rendered via [StreakFlameIcon] with a ShaderMask)
Color streakFlameColor(int flames) {
  if (flames >= 7) return const Color(0xFF4DA3FF);
  if (flames >= 3) return const Color(0xFF34D27F);
  return Colors.orangeAccent;
}

const List<Color> _rainbowFlameGradient = <Color>[
  Color(0xFFFF4D4D),
  Color(0xFFFFB347),
  Color(0xFFFFE066),
  Color(0xFF34D27F),
  Color(0xFF4DA3FF),
  Color(0xFFB266FF),
  Color(0xFFFF4D4D),
];

class StreakFlameIcon extends StatelessWidget {
  final int flames;
  final double size;
  final IconData icon;

  const StreakFlameIcon({
    super.key,
    required this.flames,
    this.size = 18,
    this.icon = Icons.local_fire_department,
  });

  @override
  Widget build(BuildContext context) {
    if (flames >= 30) {
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => const SweepGradient(
          colors: _rainbowFlameGradient,
        ).createShader(bounds),
        child: Icon(icon, size: size, color: Colors.white),
      );
    }
    return Icon(icon, size: size, color: streakFlameColor(flames));
  }
}

/// Parses a database timestamp. `created_at` of photos, comments, likes,
/// challenges and notifications is `timestamp without time zone` holding
/// UTC, so a value without offset is read as UTC, not as device time.
DateTime? parseUtcTimestamp(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  final parsed = DateTime.tryParse(raw.toString().trim());
  if (parsed == null || parsed.isUtc) return parsed;
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const _channelId = 'sidequest_general';
  static const _channelName = 'SideQuest';
  static const _channelDescription =
      'Updates zu Freunden, Quests, Duellen und Nachrichten';
  Future<void>? _initFuture;

  Future<void> init() async {
    _initFuture ??= _doInit();
    await _initFuture;
  }

  Future<void> _doInit() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Permission is asked later (requestPermission), not at app start.
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        _handleNotificationPayload(response.payload);
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _handleNotificationPayload(launchDetails?.notificationResponse?.payload);
    }

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );
  }

  /// Shows the system dialog if the user hasn't decided yet.
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  bool _timeZonesReady = false;

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
    macOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  /// Schedules a notification on the device for an absolute instant. Used
  /// where remote push isn't available (e.g. sideloaded iOS builds can't
  /// register with APNs, so FCM never gets a token).
  Future<void> scheduleAt({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;
    await init();
    if (!_timeZonesReady) {
      tz_data.initializeTimeZones();
      _timeZonesReady = true;
    }
    await _plugin.zonedSchedule(
      id,
      repairMojibake(title),
      repairMojibake(body),
      tz.TZDateTime.from(when.toUtc(), tz.UTC),
      _details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  Future<void> cancel(int id) async {
    if (kIsWeb) return;
    await init();
    await _plugin.cancel(id);
  }

  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    await init();

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      repairMojibake(title),
      repairMojibake(body),
      details,
      payload: payload,
    );
  }
}

class NotificationSettings {
  final bool friendsPosts;
  final bool challengeEnding;
  final bool challengeStart;
  final bool challenged;
  final bool messages;

  const NotificationSettings({
    required this.friendsPosts,
    required this.challengeEnding,
    required this.challengeStart,
    required this.challenged,
    required this.messages,
  });
}

class NotificationPrefs {
  static const _friendsPostsKey = 'notify_friends_posts';
  static const _challengeEndingKey = 'notify_challenge_ending';
  static const _challengeStartKey = 'notify_challenge_start';
  static const _challengedKey = 'notify_challenged';
  static const _messagesKey = 'notify_messages';

  static const _remoteTable = 'user_notification_prefs';

  /// Local key -> column in [_remoteTable].
  static const Map<String, String> _remoteColumns = {
    _friendsPostsKey: 'friends_posts',
    _challengeEndingKey: 'challenge_ending',
    _challengeStartKey: 'challenge_start',
    _challengedKey: 'challenged',
    _messagesKey: 'messages',
  };

  /// The local copy is stored per user, so two accounts on one phone don't
  /// share their settings.
  static String _userKey(String key) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    return userId == null ? key : '${key}_$userId';
  }

  static Future<void> _tryUpsertRemote(Map<String, dynamic> patch) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      await client.from(_remoteTable).upsert({
        'user_id': userId,
        ...patch,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Best-effort only. Push delivery should not break settings UI.
    }
  }

  static Future<NotificationSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Values from before the per-user keys are the fallback until the first
    // sync with the server.
    bool read(String key) =>
        prefs.getBool(_userKey(key)) ?? prefs.getBool(key) ?? true;
    return NotificationSettings(
      friendsPosts: read(_friendsPostsKey),
      challengeEnding: read(_challengeEndingKey),
      challengeStart: read(_challengeStartKey),
      challenged: read(_challengedKey),
      messages: read(_messagesKey),
    );
  }

  static Future<void> _set(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_userKey(key), value);
    await _tryUpsertRemote({_remoteColumns[key]!: value});
  }

  static Future<void> setFriendsPosts(bool value) =>
      _set(_friendsPostsKey, value);
  static Future<void> setChallengeEnding(bool value) =>
      _set(_challengeEndingKey, value);
  static Future<void> setChallengeStart(bool value) =>
      _set(_challengeStartKey, value);
  static Future<void> setChallenged(bool value) => _set(_challengedKey, value);
  static Future<void> setMessages(bool value) => _set(_messagesKey, value);

  /// Called after sign-in. The server copy follows the user across devices,
  /// so it wins; only without a server row are this device's values uploaded.
  /// (Before, every sign-in pushed the device values and a new phone reset
  /// all settings to "on".)
  static Future<void> syncWithServer() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final row = await client
          .from(_remoteTable)
          .select(_remoteColumns.values.join(','))
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        final settings = await load();
        await _tryUpsertRemote({
          'friends_posts': settings.friendsPosts,
          'challenge_ending': settings.challengeEnding,
          'challenge_start': settings.challengeStart,
          'challenged': settings.challenged,
          'messages': settings.messages,
        });
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      for (final entry in _remoteColumns.entries) {
        final value = row[entry.value];
        if (value is bool) await prefs.setBool(_userKey(entry.key), value);
      }
    } catch (e) {
      AppLogger.debug('Syncing notification settings failed: $e');
    }
  }

  static Future<bool> getFriendsPosts() async => (await load()).friendsPosts;
  static Future<bool> getChallengeEnding() async =>
      (await load()).challengeEnding;
  static Future<bool> getChallengeStart() async =>
      (await load()).challengeStart;
  static Future<bool> getChallenged() async => (await load()).challenged;
  static Future<bool> getMessages() async => (await load()).messages;
}

class UserAppSettings {
  final bool defaultPostPublic;
  final bool allowContactDiscovery;
  final String timezoneId;

  const UserAppSettings({
    required this.defaultPostPublic,
    required this.allowContactDiscovery,
    required this.timezoneId,
  });
}

const List<Map<String, String>> kTimezoneOptions = [
  {
    'id': 'Europe/Berlin',
    'label_de': 'Mitteleuropa (Berlin)',
    'label_en': 'Central Europe (Berlin)',
    'offset': 'UTC+1',
  },
  {
    'id': 'Europe/London',
    'label_de': 'Vereinigtes Königreich (London)',
    'label_en': 'United Kingdom (London)',
    'offset': 'UTC+0',
  },
  {
    'id': 'America/New_York',
    'label_de': 'Nordamerika Ost (New York)',
    'label_en': 'North America East (New York)',
    'offset': 'UTC-5',
  },
  {
    'id': 'America/Chicago',
    'label_de': 'Nordamerika Central (Chicago)',
    'label_en': 'North America Central (Chicago)',
    'offset': 'UTC-6',
  },
  {
    'id': 'America/Los_Angeles',
    'label_de': 'Nordamerika West (Los Angeles)',
    'label_en': 'North America West (Los Angeles)',
    'offset': 'UTC-8',
  },
  {
    'id': 'America/Sao_Paulo',
    'label_de': 'Südamerika Ost (Sao Paulo)',
    'label_en': 'South America East (Sao Paulo)',
    'offset': 'UTC-3',
  },
  {
    'id': 'Europe/Moscow',
    'label_de': 'Osteuropa (Moskau)',
    'label_en': 'Eastern Europe (Moscow)',
    'offset': 'UTC+3',
  },
  {
    'id': 'Asia/Dubai',
    'label_de': 'Golfregion (Dubai)',
    'label_en': 'Gulf Region (Dubai)',
    'offset': 'UTC+4',
  },
  {
    'id': 'Asia/Kolkata',
    'label_de': 'Indien (Kolkata)',
    'label_en': 'India (Kolkata)',
    'offset': 'UTC+5:30',
  },
  {
    'id': 'Asia/Singapore',
    'label_de': 'Südostasien (Singapur)',
    'label_en': 'Southeast Asia (Singapore)',
    'offset': 'UTC+8',
  },
  {
    'id': 'Asia/Tokyo',
    'label_de': 'Japan (Tokio)',
    'label_en': 'Japan (Tokyo)',
    'offset': 'UTC+9',
  },
  {
    'id': 'Australia/Sydney',
    'label_de': 'Australien Ost (Sydney)',
    'label_en': 'Eastern Australia (Sydney)',
    'offset': 'UTC+10',
  },
];

String timezoneLabel(String timezoneId) {
  for (final option in kTimezoneOptions) {
    if (option['id'] == timezoneId) {
      return languageController.lang == 'en'
          ? (option['label_en'] ?? timezoneId)
          : (option['label_de'] ?? timezoneId);
    }
  }
  return timezoneId;
}

String timezoneOffsetLabel(String timezoneId) {
  for (final option in kTimezoneOptions) {
    if (option['id'] == timezoneId) {
      return option['offset'] ?? '';
    }
  }
  return '';
}

class UserAppSettingsPrefs {
  static const _defaultPostPublicKey = 'settings_default_post_public_v1';
  static const _allowContactDiscoveryKey =
      'settings_allow_contact_discovery_v1';
  static const _timezoneIdKey = 'settings_timezone_id_v1';
  static UserAppSettings? _cachedLocalSettings;

  static UserAppSettings? peekLocalSettings() => _cachedLocalSettings;

  static bool _boolFromDynamic(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 't') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'f') {
        return false;
      }
    }
    return fallback;
  }

  static String _timezoneIdFromDynamic(dynamic value, String fallback) {
    var timezoneId = (value ?? '').toString().trim();
    if (timezoneId == 'UTC') timezoneId = 'Europe/London';
    return timezoneId.isEmpty ? fallback : timezoneId;
  }

  static Future<void> _persistLocal(UserAppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_defaultPostPublicKey, settings.defaultPostPublic);
    await prefs.setBool(
      _allowContactDiscoveryKey,
      settings.allowContactDiscovery,
    );
    await prefs.setString(_timezoneIdKey, settings.timezoneId);
    _cachedLocalSettings = settings;
  }

  static Future<void> _tryUpdateRemote(Map<String, dynamic> patch) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) return;
      await client.from('users_profile').update(patch).eq('id', userId);
    } catch (_) {
      // Best-effort only. Missing columns should not break local settings.
    }
  }

  static Future<UserAppSettings> loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = UserAppSettings(
      defaultPostPublic: prefs.getBool(_defaultPostPublicKey) ?? false,
      allowContactDiscovery: prefs.getBool(_allowContactDiscoveryKey) ?? true,
      timezoneId: () {
        final tz = prefs.getString(_timezoneIdKey) ?? 'Europe/Berlin';
        return tz == 'UTC' ? 'Europe/London' : tz;
      }(),
    );
    _cachedLocalSettings = settings;
    return settings;
  }

  static Future<UserAppSettings> load({bool includeRemote = true}) async {
    final local = await loadLocal();
    if (!includeRemote) return local;

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) return local;

      final remote = await client
          .from('users_profile')
          .select('default_post_public, allow_contact_discovery, timezone_id')
          .eq('id', userId)
          .maybeSingle();
      if (remote == null) return local;

      final merged = UserAppSettings(
        defaultPostPublic: _boolFromDynamic(
          remote['default_post_public'],
          local.defaultPostPublic,
        ),
        allowContactDiscovery: _boolFromDynamic(
          remote['allow_contact_discovery'],
          local.allowContactDiscovery,
        ),
        timezoneId: _timezoneIdFromDynamic(
          remote['timezone_id'],
          local.timezoneId,
        ),
      );
      await _persistLocal(merged);
      return merged;
    } catch (_) {
      return local;
    }
  }

  static Future<void> setDefaultPostPublic(bool value) async {
    final current = await loadLocal();
    final next = UserAppSettings(
      defaultPostPublic: value,
      allowContactDiscovery: current.allowContactDiscovery,
      timezoneId: current.timezoneId,
    );
    await _persistLocal(next);
    await _tryUpdateRemote({'default_post_public': value});
  }

  static Future<void> setAllowContactDiscovery(bool value) async {
    final current = await loadLocal();
    final next = UserAppSettings(
      defaultPostPublic: current.defaultPostPublic,
      allowContactDiscovery: value,
      timezoneId: current.timezoneId,
    );
    await _persistLocal(next);
    await _tryUpdateRemote({'allow_contact_discovery': value});
  }

  static Future<void> setTimezoneId(String value) async {
    var timezoneId = value.trim().isEmpty ? 'Europe/Berlin' : value.trim();
    if (timezoneId == 'UTC') timezoneId = 'Europe/London';
    final current = await loadLocal();
    final next = UserAppSettings(
      defaultPostPublic: current.defaultPostPublic,
      allowContactDiscovery: current.allowContactDiscovery,
      timezoneId: timezoneId,
    );
    await _persistLocal(next);
    await _tryUpdateRemote({'timezone_id': timezoneId});
  }

  static Future<void> primeLocalCache() async {
    await loadLocal();
  }

  static Future<void> syncAllToSupabase() async {
    final settings = await loadLocal();
    await _tryUpdateRemote({
      'default_post_public': settings.defaultPostPublic,
      'allow_contact_discovery': settings.allowContactDiscovery,
      'timezone_id': settings.timezoneId,
    });
  }
}

class GrowthPromptsPrefs {
  static const _sharePromptSeenKey = 'growth_share_prompt_seen_v1';
  static const _ratingPromptSeenKey = 'growth_rating_prompt_seen_v1';

  static Future<bool> shouldShowSharePrompt({
    required bool isPublicPost,
  }) async {
    if (!isPublicPost) return false;
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_sharePromptSeenKey) ?? false);
  }

  static Future<bool> shouldShowRatingPrompt({required int streakCount}) async {
    if (streakCount < 3) return false;
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_ratingPromptSeenKey) ?? false);
  }

  static Future<void> markSharePromptSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sharePromptSeenKey, true);
  }

  static Future<void> markRatingPromptSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ratingPromptSeenKey, true);
  }
}

// Globale Funktion zum Anzeigen von Profilbildern
void showProfilePictureDialog(
  BuildContext context,
  String? avatarUrl,
  String username,
) {
  showDialog(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: CircleAvatar(
            radius: 96,
            backgroundColor: Colors.black,
            backgroundImage: sideQuestCachedImageProvider(avatarUrl),
            child: avatarUrl == null
                ? Text(
                    username.isNotEmpty ? username[0].toUpperCase() : 'U',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 64,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Thought-bubble icon (comment icon replacement)
// ---------------------------------------------------------------------------

/// Comment icon used across feed + leaderboard. The widget name is kept for
/// API compatibility with existing callers; the rendering is now a clean
/// rounded chat bubble from Material icons.
class ThoughtBubbleIcon extends StatelessWidget {
  final double size;
  final Color color;
  const ThoughtBubbleIcon({
    super.key,
    this.size = 24,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.chat,
      size: size,
      color: color,
    );
  }
}
