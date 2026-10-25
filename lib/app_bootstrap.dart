import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics_service.dart';
import 'core/app_environment.dart';
import 'core/analytics_consent.dart';
import 'core/app_logger.dart';
import 'features/invite/invite_links.dart';
import 'shared.dart';
import 'text_normalizer.dart';

DebugPrintCallback? _defaultDebugPrint;

void _installDebugPrintRepair() {
  if (_defaultDebugPrint != null) return;
  _defaultDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    _defaultDebugPrint!(
      message == null ? null : repairMojibake(message),
      wrapWidth: wrapWidth,
    );
  };
}

String _messageTitle(RemoteMessage message) {
  final notificationTitle = message.notification?.title?.trim();
  if (notificationTitle != null && notificationTitle.isNotEmpty) {
    return repairMojibake(notificationTitle);
  }

  final dataTitle = message.data['title']?.trim();
  if (dataTitle != null && dataTitle.isNotEmpty) {
    return repairMojibake(dataTitle);
  }

  return 'SideQuest';
}

String _messageBody(RemoteMessage message) {
  final notificationBody = message.notification?.body?.trim();
  if (notificationBody != null && notificationBody.isNotEmpty) {
    return repairMojibake(notificationBody);
  }

  final dataBody = message.data['body']?.trim();
  if (dataBody != null && dataBody.isNotEmpty) {
    return repairMojibake(dataBody);
  }

  return 'You have a new notification';
}

bool _hasVisibleNotification(RemoteMessage message) {
  final title = message.notification?.title?.trim();
  final body = message.notification?.body?.trim();
  return (title != null && title.isNotEmpty) ||
      (body != null && body.isNotEmpty);
}

String _notificationPayload(RemoteMessage message) {
  return jsonEncode({
    ...message.data,
    'title': _messageTitle(message),
    'body': _messageBody(message),
  });
}

void _handleRemoteMessageOpen(RemoteMessage message) {
  final targetTab = int.tryParse((message.data['target_tab'] ?? '').trim());
  if (targetTab != null) {
    requestMainTabNavigation(targetTab);
  }

  final kind = (message.data['kind'] ?? '').trim();
  final senderId = (message.data['sender_id'] ?? '').trim();
  final messageId = (message.data['message_id'] ?? '').trim();
  if (senderId.isNotEmpty &&
      (kind == 'message' || kind == 'message_reaction')) {
    requestChatOpen(
      ChatOpenRequest(
        friendId: senderId,
        messageId: messageId.isEmpty ? null : messageId,
      ),
    );
    AppLogger.info(
      'Push opened: kind=${message.data['kind'] ?? 'unknown'} data=${message.data}',
    );
    return;
  }

  final photoId = (message.data['photo_id'] ?? '').trim();
  if (targetTab != null && photoId.isNotEmpty) {
    final commentId = (message.data['comment_id'] ?? '').trim();
    requestPostFocus(
      PostFocusRequest(
        tabIndex: targetTab,
        photoId: photoId,
        commentId: commentId.isEmpty ? null : commentId,
      ),
    );
  }

  AppLogger.info(
    'Push opened: kind=${message.data['kind'] ?? 'unknown'} data=${message.data}',
  );
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // FCM shows notification payloads itself in background. We only need the
  // local-notification fallback for data-only messages.
  if (_hasVisibleNotification(message)) {
    return;
  }

  await NotificationService.instance.init();
  await NotificationService.instance.showNotification(
    title: _messageTitle(message),
    body: _messageBody(message),
    payload: _notificationPayload(message),
  );
}

String? _latestFcmToken;

/// Whether this device registered for remote (FCM) pushes. Sideloaded iOS
/// builds without APNs never get a token and rely on local reminders.
bool get sideQuestHasRemotePushToken =>
    (_latestFcmToken ?? '').trim().isNotEmpty;
Future<void>? _deferredBootstrapFuture;

/// Signs out and first detaches this device from the account's pushes.
/// Otherwise the next person using the device would keep receiving the
/// previous account's notifications (including message previews).
Future<void> signOutSideQuest() async {
  final client = Supabase.instance.client;
  final userId = client.auth.currentUser?.id;
  if (userId != null) {
    try {
      final platform = kIsWeb ? 'web' : Platform.operatingSystem;
      await client
          .from('user_device_tokens')
          .delete()
          .eq('user_id', userId)
          .eq('platform', platform);
    } catch (e) {
      AppLogger.warn('Removing device token on sign-out failed: $e');
    }
  }
  if (!kIsWeb && Firebase.apps.isNotEmpty) {
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      AppLogger.warn('Deleting FCM token on sign-out failed: $e');
    }
  }
  _latestFcmToken = null;
  await client.auth.signOut();
}

/// After a sign-out the FCM token was deleted; fetch a fresh one for the
/// newly signed-in account.
/// Asks for push permission at a moment the user knows why (after the
/// onboarding). If they already decided, no dialog is shown.
Future<void> requestPushPermission() async {
  if (kIsWeb) return;
  try {
    await NotificationService.instance.requestPermission();
  } catch (e) {
    AppLogger.warn('Notification permission request failed: $e');
  }
  if (Firebase.apps.isEmpty) return;
  try {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    AppLogger.info('FCM permission: ${settings.authorizationStatus}');
    await _ensureFcmTokenForSignedInUser();
  } catch (e) {
    AppLogger.warn('FCM permission request failed: $e');
  }
}

Future<void> _ensureFcmTokenForSignedInUser() async {
  if (_latestFcmToken == null) {
    try {
      _latestFcmToken = await FirebaseMessaging.instance.getToken(
        vapidKey: kIsWeb ? AppEnvironment.webPushVapidKey : null,
      );
    } catch (e) {
      AppLogger.warn('FCM getToken after sign-in failed: $e');
      return;
    }
  }
  await _registerFcmTokenWithSupabase(_latestFcmToken);
}

bool _looksLikeDuplicateDeviceTokenWrite(PostgrestException error) {
  if (error.code == '23505') return true;
  final combined = '${error.message} ${error.details ?? ''} ${error.hint ?? ''}'
      .toLowerCase();
  return combined.contains('duplicate') || combined.contains('unique');
}

Future<void> _registerFcmTokenWithSupabase(String? token) async {
  if (token == null || token.isEmpty) return;

  final client = Supabase.instance.client;
  final userId = client.auth.currentUser?.id;
  if (userId == null) return;

  final platform = kIsWeb ? 'web' : Platform.operatingSystem;
  final payload = {'user_id': userId, 'platform': platform, 'token': token};

  try {
    final updatedRows = await client
        .from('user_device_tokens')
        .update({'token': token})
        .eq('user_id', userId)
        .eq('platform', platform)
        .select('user_id');
    if (updatedRows.isNotEmpty) {
      AppLogger.info('Supabase FCM token updated for $userId ($platform)');
      return;
    }

    await client.from('user_device_tokens').insert(payload);
    AppLogger.info('Supabase FCM token inserted for $userId ($platform)');
  } on PostgrestException catch (e) {
    if (_looksLikeDuplicateDeviceTokenWrite(e)) {
      try {
        final updatedRows = await client
            .from('user_device_tokens')
            .update({'token': token})
            .eq('user_id', userId)
            .eq('platform', platform)
            .select('user_id');

        if (updatedRows.isNotEmpty) {
          AppLogger.info(
            'Supabase FCM token updated after duplicate write for $userId ($platform)',
          );
          return;
        }
      } catch (fallbackError) {
        AppLogger.warn(
          'Supabase FCM token duplicate-write recovery failed: $fallbackError',
        );
        return;
      }
    }

    AppLogger.warn('Supabase FCM token save failed: $e');
  } catch (e) {
    AppLogger.warn('Supabase FCM token save failed: $e');
  }
}

/// Fonts ship with the app (assets/google_fonts/) instead of being
/// downloaded on first use: no text jumping from a fallback font, correct
/// fonts offline, and no request to Google's servers. Call before runApp.
void configureBundledFonts() {
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'Inter': 'assets/google_fonts/OFL-Inter.txt',
      'Nunito': 'assets/google_fonts/OFL-Nunito.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks(<String>[
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
}

/// Loads the bundled fonts while the native splash is still visible, so the
/// first frame already renders in the right font.
Future<void> _preloadBundledFonts() async {
  try {
    await GoogleFonts.pendingFonts([
      for (final weight in const [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w800,
        FontWeight.w900,
      ])
        GoogleFonts.inter(fontWeight: weight),
      GoogleFonts.nunito(fontWeight: FontWeight.w900),
    ]).timeout(const Duration(seconds: 3));
  } catch (e) {
    AppLogger.warn('Preloading bundled fonts failed: $e');
  }
}

Future<void> bootstrapSideQuestApp({bool startDeferredServices = true}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installDebugPrintRepair();
  await _preloadBundledFonts();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await languageController.init();
  await UserAppSettingsPrefs.primeLocalCache();

  await Supabase.initialize(
    url: AppEnvironment.supabaseUrl,
    anonKey: AppEnvironment.supabaseAnonKey,
  );
  unawaited(InviteLinks.start());

  if (startDeferredServices) {
    unawaited(startSideQuestDeferredServices());
  }
}

Future<void> startSideQuestDeferredServices() {
  return _deferredBootstrapFuture ??= _bootstrapDeferredServices();
}

Future<void> _bootstrapDeferredServices() async {
  // --- Local notification plugin ---
  try {
    await NotificationService.instance.init();
  } catch (e) {
    AppLogger.warn('NotificationService init failed: $e');
  }

  // --- Firebase Core ---
  var firebaseReady = false;
  try {
    await Firebase.initializeApp();
    AppLogger.info('Firebase initialized');
    firebaseReady = true;
    // Analytics stay off (natively) until the user opted in.
    await AnalyticsConsent.apply();
  } catch (e) {
    AppLogger.warn('Firebase.initializeApp failed (push will NOT work): $e');
  }

  if (firebaseReady) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final messaging = FirebaseMessaging.instance;

    // The permission dialog comes later (requestPushPermission, after the
    // onboarding explains the daily quest push), not on the first screen.
    try {
      await messaging.setAutoInitEnabled(true);
    } catch (e) {
      AppLogger.warn('FCM auto init failed: $e');
    }

    // On iOS, let the system show notification-bearing messages in foreground
    // (data-only messages are handled by the onMessage listener below).
    try {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
    } catch (_) {}

    // --- FCM Token ---
    try {
      final token = await messaging.getToken(
        vapidKey: kIsWeb ? AppEnvironment.webPushVapidKey : null,
      );
      _latestFcmToken = token;
      await _registerFcmTokenWithSupabase(token);
      AppLogger.info(
        'FCM Token obtained: ${token != null ? '${token.substring(0, 12)}…' : 'null'}',
      );
    } catch (e) {
      AppLogger.warn('FCM getToken failed (push will NOT work): $e');
    }

    // --- Foreground messages ---
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      // On iOS, setForegroundNotificationPresentationOptions already
      // displays notification-bearing messages. Only show a local
      // notification for data-only messages to avoid doubles.
      if (!kIsWeb && Platform.isIOS && _hasVisibleNotification(message)) {
        AppLogger.debug(
          'Foreground push (iOS, system-displayed): kind=${message.data['kind'] ?? 'unknown'}',
        );
        return;
      }
      await NotificationService.instance.showNotification(
        title: _messageTitle(message),
        body: _messageBody(message),
        payload: _notificationPayload(message),
      );
    });

    // --- Tap handling ---
    FirebaseMessaging.onMessageOpenedApp.listen(_handleRemoteMessageOpen);

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _handleRemoteMessageOpen(initialMessage);
    }

    // --- Token refresh ---
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      _latestFcmToken = token;
      await _registerFcmTokenWithSupabase(token);
      AppLogger.info('FCM token refreshed');
    });
  }

  // --- Auth state → re-register token & sync prefs ---
  Supabase.instance.client.auth.onAuthStateChange.listen((event) async {
    await AnalyticsService.setUserId(event.session?.user.id);

    if (event.event == AuthChangeEvent.passwordRecovery) {
      setPasswordRecoveryMode(true);
    } else if (event.event == AuthChangeEvent.signedOut) {
      setPasswordRecoveryMode(false);
    }

    if (firebaseReady && event.session?.user != null) {
      await _ensureFcmTokenForSignedInUser();
    }

    if (event.session?.user != null) {
      await NotificationPrefs.syncWithServer();
      await languageController.syncToProfile();
    }
  });

  final existingSession = Supabase.instance.client.auth.currentSession;
  await AnalyticsService.setUserId(existingSession?.user.id);
  if (existingSession == null) {
    setPasswordRecoveryMode(false);
  }

  if (firebaseReady &&
      existingSession?.user != null &&
      _latestFcmToken != null) {
    await _registerFcmTokenWithSupabase(_latestFcmToken);
  }

  if (existingSession?.user != null) {
    await NotificationPrefs.syncWithServer();
    await languageController.syncToProfile();
  }
}
