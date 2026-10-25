// COMPLETE SINGLE-FILE EXAMPLE
// main.dart

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:crypto/crypto.dart';
import 'app_bootstrap.dart';
import 'analytics_service.dart';
import 'block_service.dart';
import 'core/app_environment.dart';
import 'core/app_logger.dart';
import 'core/crash_reporting.dart';
import 'core/error_mapper.dart';
import 'core/legal_texts.dart';
import 'daily_challenges.dart';
import 'features/daily_quest/daily_quest_service.dart';
import 'features/daily_quest/quest_window.dart';
import 'features/chat/message_status.dart';
import 'features/daily_quest/post_streak.dart';
import 'features/media/post_media.dart';
import 'features/invite/invite_links.dart';
import 'features/invite/invite_share.dart';
import 'features/live_photo/live_photo.dart';
import 'core/analytics_consent.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/reminders/challenge_reminders.dart';
import 'gesture_cropper.dart';
import 'london_time.dart';
import 'shared.dart';
import 'friends.dart';
import 'friends.dart' as friends_ui show ChatScreen;
import 'friend_discovery.dart';
import 'username_filter.dart';
import 'comment_filter.dart';
import 'comment_thread_service.dart';
import 'profile.dart';
import 'global.dart';
import 'image_compression.dart';
import 'image_validation.dart';
import 'like_animation.dart';
import 'mentions.dart';
import 'notifications_center.dart';
import 'report_service.dart';
import 'widgets/daily_quest_mini_card.dart';
import 'widgets/friend_likes_preview.dart';
import 'widgets/likers_bottom_sheet.dart';
import 'splash_screen.dart';
import 'text_normalizer.dart';

/// Cached Inter TextStyle – avoids repeated font-family lookups in build().
final TextStyle _inter = GoogleFonts.inter(fontWeight: FontWeight.w700);

enum _PostActionMenuValue { report, delete }

enum _CommentActionMenuValue { report, delete }

/// Lightweight shimmer block used for ftopeed skeleton placeholders.
class _ShimmerBlock extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const _ShimmerBlock({
    required this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  State<_ShimmerBlock> createState() => _ShimmerBlockState();
}

class _ShimmerBlockState extends State<_ShimmerBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * _controller.value, 0),
              end: Alignment(1.0 + 2.0 * _controller.value, 0),
              colors: const [
                Color(0xFF1E1E1E),
                Color(0xFF2A2A2A),
                Color(0xFF1E1E1E),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A single skeleton card that mimics the daily feed card layout.
Widget _feedSkeletonCard(double screenWidth) {
  final cardWidth = screenWidth - 32; // 16px padding each side
  return Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Container(
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2E2E2E)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ShimmerBlock(
                width: 32,
                height: 32,
                borderRadius: BorderRadius.circular(16),
              ),
              const SizedBox(width: 10),
              _ShimmerBlock(
                width: cardWidth * 0.35,
                height: 14,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ShimmerBlock(
            width: cardWidth - 24,
            height: 220,
            borderRadius: BorderRadius.circular(14),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _ShimmerBlock(
                width: 60,
                height: 14,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(width: 16),
              _ShimmerBlock(
                width: 60,
                height: 14,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> ensureUserProfileExists(
  SupabaseClient client, {
  String? preferredUsername,
  User? userOverride,
}) async {
  final user = userOverride ?? client.auth.currentUser;
  if (user == null) {
    throw StateError('No authenticated user available');
  }

  final userId = user.id;

  final existing = await client
      .from('users_profile')
      .select('id')
      .eq('id', userId)
      .maybeSingle();
  if (existing != null) return;

  final metaUsername = user.userMetadata?['username'];
  final fallbackFromEmail = (user.email ?? '').split('@').first;

  String? firstValid(String? raw) {
    if (raw == null) return null;
    final result = UsernameFilter.validate(raw);
    return result.isValid ? result.normalized : null;
  }

  final username =
      firstValid(preferredUsername) ??
      (metaUsername is String ? firstValid(metaUsername) : null) ??
      firstValid(fallbackFromEmail) ??
      UsernameFilter.makeSafeFallback(userId: userId, seed: fallbackFromEmail);

  try {
    // IMPORTANT: Do NOT set last_posted_date here. That field is used to
    // track streak coverage for the current challenge day.
    await client.from('users_profile').upsert({
      'id': userId,
      'username': username,
    }, onConflict: 'id');
  } on PostgrestException catch (e) {
    AppLogger.debug(
      'ensureUserProfileExists failed: code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}',
    );
    rethrow;
  }
}

/// Version of the terms and privacy policy (lib/core/legal_texts.dart).
/// Bumping it shows the consent gate to every user once.
const String kRequiredLegalVersion = '2026-10-24';

String _userMetadataString(User? user, String key) {
  final value = user?.userMetadata?[key];
  return value?.toString().trim() ?? '';
}

bool userHasAcceptedRequiredLegal(User? user) {
  final acceptedTerms = _userMetadataString(user, 'accepted_terms_version');
  final acceptedPrivacy = _userMetadataString(user, 'accepted_privacy_version');
  final acceptedAt = _userMetadataString(user, 'accepted_legal_at');
  return acceptedTerms == kRequiredLegalVersion &&
      acceptedPrivacy == kRequiredLegalVersion &&
      acceptedAt.isNotEmpty;
}

bool userNeedsLaunchCompliance(User? user) {
  if (user == null) return false;
  return !userHasAcceptedRequiredLegal(user);
}

Map<String, Object?> requiredLegalMetadataPayload() {
  return <String, Object?>{
    'accepted_terms_version': kRequiredLegalVersion,
    'accepted_privacy_version': kRequiredLegalVersion,
    'accepted_legal_at': DateTime.now().toIso8601String(),
  };
}

/// Post time in device time ("14:05"), plus "(3h zu spät)" for late quest
/// posts.
String postTimeLabel(DateTime createdAtUtc, {required bool isLate}) {
  final local = createdAtUtc.toLocal();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (!isLate) return time;
  final hours = hoursAfterQuestEnd(createdAtUtc);
  return '$time (${hours}h ${t('zu spät', 'late')})';
}

void main() {
  // Everything must run inside the same zone — bindings, error handlers
  // and runApp. Initializing the binding in the root zone and then calling
  // runApp in a guarded zone produces a "Zone mismatch" assertion in debug.
  runZonedGuarded(
    () {
      final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
      FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
      configureBundledFonts();
      FlutterError.onError = (details) {
        AppLogger.error(
          'Uncaught Flutter framework error',
          details.exception,
          details.stack,
        );
        FlutterError.presentError(details);
        CrashReporting.recordFlutterError(details);
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        AppLogger.error('Uncaught platform error', error, stackTrace);
        CrashReporting.recordError(error, stackTrace, fatal: true);
        return false;
      };
      runApp(const SideQuestApp());
    },
    (error, stackTrace) {
      AppLogger.error('Uncaught zone error', error, stackTrace);
      CrashReporting.recordError(error, stackTrace);
    },
  );
}

class SideQuestApp extends StatefulWidget {
  const SideQuestApp({super.key});

  @override
  State<SideQuestApp> createState() => _SideQuestAppState();
}

/// Survives any State disposal — used for showing preview dialogs after the
/// camera/LivePhoto Activity returns and the underlying tab State has been
/// rebuilt. Local `BuildContext`s are unreliable across that lifecycle.
final GlobalKey<NavigatorState> sideQuestRootNavigatorKey =
    GlobalKey<NavigatorState>();

class _SideQuestAppState extends State<SideQuestApp> {
  @override
  void initState() {
    super.initState();
    languageController.addListener(_onLangChange);
  }

  @override
  void dispose() {
    languageController.removeListener(_onLangChange);
    super.dispose();
  }

  void _onLangChange() => setState(() {});

  TextTheme _thickSansTextTheme(TextTheme base) {
    TextStyle? w(TextStyle? s, FontWeight weight) =>
        s?.copyWith(fontWeight: weight);

    return base.copyWith(
      displayLarge: w(base.displayLarge, FontWeight.w800),
      displayMedium: w(base.displayMedium, FontWeight.w800),
      displaySmall: w(base.displaySmall, FontWeight.w800),
      headlineLarge: w(base.headlineLarge, FontWeight.w800),
      headlineMedium: w(base.headlineMedium, FontWeight.w800),
      headlineSmall: w(base.headlineSmall, FontWeight.w700),
      titleLarge: w(base.titleLarge, FontWeight.w700),
      titleMedium: w(base.titleMedium, FontWeight.w700),
      titleSmall: w(base.titleSmall, FontWeight.w700),
      bodyLarge: w(base.bodyLarge, FontWeight.w700),
      bodyMedium: w(base.bodyMedium, FontWeight.w700),
      bodySmall: w(base.bodySmall, FontWeight.w700),
      labelLarge: w(base.labelLarge, FontWeight.w700),
      labelMedium: w(base.labelMedium, FontWeight.w700),
      labelSmall: w(base.labelSmall, FontWeight.w700),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: sideQuestRootNavigatorKey,
      home: const AppBootstrapGate(),
      debugShowCheckedModeBanner: false,
      locale: languageController.locale,
      supportedLocales: const [Locale('en'), Locale('de')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      // Clamp the system text-scale so very large accessibility settings
      // can't overflow our buttons and tabs. We honour the user's scale up
      // to 120%, but cap there.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.85,
              maxScaleFactor: 1.20,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        // Use platform default sans-serif (Roboto/SF) + thicker weights.
        // Inter everywhere, so unstyled text matches the explicit styles.
        textTheme: GoogleFonts.interTextTheme(
          _thickSansTextTheme(ThemeData(useMaterial3: true).textTheme),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: appGreen,
        colorScheme: ColorScheme.fromSeed(
          seedColor: appGreen,
        ).copyWith(primary: appGreen, secondary: appGreen, tertiary: appGreen),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.black,
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: appGreen,
        ),
      ),
    );
  }
}

class AppBootstrapGate extends StatefulWidget {
  const AppBootstrapGate({super.key});

  @override
  State<AppBootstrapGate> createState() => _AppBootstrapGateState();
}

class _AppBootstrapGateState extends State<AppBootstrapGate> {
  Object? _bootstrapError;
  bool _showHome = false;
  bool _deferredServicesStarted = false;
  bool _nativeSplashRemoved = false;

  @override
  void initState() {
    super.initState();
    _startBootstrap();
  }

  Future<void> _startBootstrap() async {
    setState(() {
      _bootstrapError = null;
      _showHome = false;
    });
    try {
      await bootstrapSideQuestApp(startDeferredServices: false);
      if (!mounted) return;
      _removeNativeSplash();
      _startDeferredServices();
      if (!mounted) return;
      setState(() => _showHome = true);
    } catch (error) {
      if (!mounted) return;
      _removeNativeSplash();
      setState(() => _bootstrapError = error);
    }
  }

  void _removeNativeSplash() {
    if (_nativeSplashRemoved) return;
    _nativeSplashRemoved = true;
    FlutterNativeSplash.remove();
  }

  void _startDeferredServices() {
    if (_deferredServicesStarted) return;
    _deferredServicesStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(startSideQuestDeferredServices());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bootstrapError != null) {
      return _BootstrapErrorScreen(onRetry: _startBootstrap);
    }

    if (_showHome) {
      return const HomeScreen();
    }

    return const SplashScreen();
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AuthGate();
  }
}

class _BootstrapErrorScreen extends StatelessWidget {
  final Future<void> Function() onRetry;

  const _BootstrapErrorScreen({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SplashScreen.backgroundColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'App startup failed',
                style: TextStyle(color: Colors.white70, fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                t(
                  'Bitte versuche den Start erneut.',
                  'Please try starting the app again.',
                ),
                style: const TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: appGreen,
                  foregroundColor: Colors.black,
                ),
                child: Text(t('Erneut versuchen', 'Try again')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  AuthGate({super.key});
  final client = Supabase.instance.client;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: passwordRecoveryModeNotifier,
      builder: (context, recoveryMode, _) => StreamBuilder<AuthState>(
        stream: client.auth.onAuthStateChange,
        builder: (context, snapshot) {
          final session = client.auth.currentSession;
          if (session != null) {
            if (recoveryMode) {
              return const PasswordRecoveryScreen();
            }
            // Google/Apple sign-ins skip the signup form, so they confirm
            // the terms here (also after a new legal version).
            if (userNeedsLaunchCompliance(session.user)) {
              return const AccountComplianceGate();
            }
            return const MainTabs();
          }
          return const LoginScreen();
        },
      ),
    );
  }
}

class _AuthModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _AuthModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? appGreen : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: appGreen.withValues(alpha: 0.32),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              style: _inter.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
                color: selected
                    ? const Color(0xFF0B1108)
                    : Colors.white.withValues(alpha: 0.6),
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final usernameCtrl = TextEditingController();
  Timer? _usernameFeedbackDebounce;
  int _usernameFeedbackRequestId = 0;
  bool _isCheckingUsernameFeedback = false;
  bool _isUsernameTaken = false;
  String? _usernameSuggestion;
  bool loading = false;
  bool _socialLoading = false;
  bool isSignUp = false;
  bool _acceptedLegal = false;

  @override
  void initState() {
    super.initState();
    emailCtrl.addListener(_onFormChanged);
    passCtrl.addListener(_onFormChanged);
    usernameCtrl.addListener(_onFormChanged);
  }

  @override
  void dispose() {
    _usernameFeedbackDebounce?.cancel();
    emailCtrl.removeListener(_onFormChanged);
    passCtrl.removeListener(_onFormChanged);
    usernameCtrl.removeListener(_onFormChanged);
    emailCtrl.dispose();
    passCtrl.dispose();
    usernameCtrl.dispose();
    super.dispose();
  }

  // Tracked snapshot of validation state — we only setState if something
  // visible actually changed. This avoids rebuilding the entire LoginScreen
  // on every keystroke (Issue #1) while still showing errors instantly when
  // they become valid/invalid.
  String? _lastEmailError;
  String? _lastPasswordError;
  String? _lastUsernameError;
  bool _lastCanSubmitSignUp = false;
  bool _lastIsSignUp = false;

  void _onFormChanged() {
    _scheduleUsernameFeedback();
    if (!mounted) return;

    final emailErr = _emailErrorText;
    final passErr = _passwordErrorText;
    final userErr = _usernameErrorText;
    final canSubmit = _canSubmitSignUp;
    final signUp = isSignUp;

    final changed =
        emailErr != _lastEmailError ||
        passErr != _lastPasswordError ||
        userErr != _lastUsernameError ||
        canSubmit != _lastCanSubmitSignUp ||
        signUp != _lastIsSignUp;

    if (!changed) return;

    _lastEmailError = emailErr;
    _lastPasswordError = passErr;
    _lastUsernameError = userErr;
    _lastCanSubmitSignUp = canSubmit;
    _lastIsSignUp = signUp;

    setState(() {});
  }

  bool get _canSubmitSignUp =>
      emailCtrl.text.trim().isNotEmpty &&
      passCtrl.text.trim().isNotEmpty &&
      usernameCtrl.text.trim().isNotEmpty &&
      _emailErrorText == null &&
      _passwordErrorText == null &&
      _usernameErrorText == null &&
      !_isCheckingUsernameFeedback &&
      _acceptedLegal;

  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  String? get _emailErrorText {
    final email = emailCtrl.text.trim();
    if (email.isEmpty) return null;
    if (_emailPattern.hasMatch(email)) return null;
    return t('Bitte gib eine gültige E-Mail ein', 'Please enter a valid email');
  }

  String? get _passwordErrorText {
    if (!isSignUp) return null;
    final pass = passCtrl.text;
    if (pass.isEmpty) return null;
    if (pass.length < 8) {
      return t('Mindestens 8 Zeichen', 'At least 8 characters');
    }
    if (!RegExp(r'[A-Z]').hasMatch(pass)) {
      return t('Mindestens ein Großbuchstabe', 'At least one uppercase letter');
    }
    if (!RegExp(r'[0-9]').hasMatch(pass)) {
      return t('Mindestens eine Zahl', 'At least one digit');
    }
    return null;
  }

  String? get _usernameErrorText {
    if (!isSignUp) return null;

    final rawUsername = usernameCtrl.text.trim();
    if (rawUsername.isEmpty) return null;

    final validation = UsernameFilter.validate(rawUsername);
    if (!validation.isValid) {
      return _usernameValidationMessage(validation.error);
    }

    if (_isUsernameTaken) {
      return _usernameAlreadyTakenMessage();
    }

    return null;
  }

  String _usernameValidationMessage(UsernameValidationError? error) {
    switch (error) {
      case UsernameValidationError.empty:
        return t(
          "Bitte gib einen Benutzernamen ein",
          "Please enter a username",
        );
      case UsernameValidationError.tooShort:
        return t(
          "Benutzername zu kurz (mindestens ${UsernameFilter.minLength} Zeichen)",
          "Username too short (minimum ${UsernameFilter.minLength} characters)",
        );
      case UsernameValidationError.tooLong:
        return t(
          "Benutzername zu lang (maximal ${UsernameFilter.maxLength} Zeichen)",
          "Username too long (maximum ${UsernameFilter.maxLength} characters)",
        );
      case UsernameValidationError.invalidCharacters:
        return t(
          "Erlaubt sind nur Buchstaben, Zahlen, ä, ö, ü, ß und _",
          "Only letters, numbers, ä, ö, ü, ß, and _ are allowed",
        );
      case UsernameValidationError.reservedOrOffensive:
        return t(
          "Dieser Benutzername ist nicht erlaubt",
          "This username is not allowed",
        );
      case null:
        return t("Ungültiger Benutzername", "Invalid username");
    }
  }

  String _legalConsentMessage() {
    return t(
      "Bitte akzeptiere Nutzungsbedingungen und Datenschutzerklärung",
      "Please accept the Terms of Use and Privacy Policy",
    );
  }

  String _fillAllFieldsMessage() {
    return t("Bitte fülle alle Felder aus", "Please fill in all fields");
  }

  String _usernameAlreadyTakenMessage() {
    return t(
      "Dieser Benutzername ist schon vergeben",
      "This username is already taken",
    );
  }

  bool _looksLikeUsernameConflict(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('username') &&
        (normalized.contains('already') ||
            normalized.contains('exists') ||
            normalized.contains('duplicate') ||
            normalized.contains('unique'));
  }

  Future<bool> _isUsernameAvailable(String username) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'is_username_available',
        params: {'p_username': username},
      );
      if (result is bool) return result;
      if (result is num) return result != 0;
      if (result is String) return result.toLowerCase() == 'true';
    } catch (e) {
      AppLogger.warn('Username availability check failed: $e');
    }
    return true;
  }

  void _clearUsernameFeedbackState({bool notify = true}) {
    _usernameFeedbackDebounce?.cancel();
    _usernameFeedbackRequestId++;
    final hadState =
        _isCheckingUsernameFeedback ||
        _isUsernameTaken ||
        _usernameSuggestion != null;
    _isCheckingUsernameFeedback = false;
    _isUsernameTaken = false;
    _usernameSuggestion = null;

    if (notify && hadState && mounted) {
      setState(() {});
    }
  }

  void _scheduleUsernameFeedback() {
    if (!isSignUp) {
      _clearUsernameFeedbackState(notify: false);
      return;
    }

    final rawUsername = usernameCtrl.text.trim();
    if (rawUsername.isEmpty) {
      _clearUsernameFeedbackState(notify: false);
      return;
    }

    final validation = UsernameFilter.validate(rawUsername);
    if (!validation.isValid) {
      _clearUsernameFeedbackState(notify: false);
      return;
    }

    _usernameFeedbackDebounce?.cancel();
    _usernameFeedbackRequestId++;
    final requestId = _usernameFeedbackRequestId;

    _isCheckingUsernameFeedback = true;
    _isUsernameTaken = false;
    _usernameSuggestion = null;

    _usernameFeedbackDebounce = Timer(
      const Duration(milliseconds: 320),
      () async {
        final username = validation.normalized;
        final isAvailable = await _isUsernameAvailable(username);
        if (!mounted || requestId != _usernameFeedbackRequestId) return;

        String? suggestion;
        if (!isAvailable) {
          suggestion = await _generateUsernameSuggestion(username, requestId);
        }

        if (!mounted || requestId != _usernameFeedbackRequestId) return;

        setState(() {
          _isCheckingUsernameFeedback = false;
          _isUsernameTaken = !isAvailable;
          _usernameSuggestion = suggestion;
        });
      },
    );
  }

  Future<String?> _generateUsernameSuggestion(
    String username,
    int requestId,
  ) async {
    final base = UsernameFilter.sanitizeLiveInput(
      username,
    ).replaceAll(RegExp(r'_+'), '_');
    if (base.isEmpty) return null;

    String buildCandidate(String suffix) {
      final maxBaseLength = math.max(
        1,
        UsernameFilter.maxLength - suffix.length,
      );
      final trimmedBase = base.length > maxBaseLength
          ? base.substring(0, maxBaseLength)
          : base;
      return '$trimmedBase$suffix';
    }

    final candidates = <String>{
      for (var i = 1; i <= 12; i++) buildCandidate('_$i'),
      for (var i = 1; i <= 12; i++) buildCandidate('$i'),
    };

    final originalKey = UsernameFilter.comparisonKey(username);

    for (final candidate in candidates) {
      if (UsernameFilter.comparisonKey(candidate) == originalKey) continue;
      if (!mounted || requestId != _usernameFeedbackRequestId) return null;

      final candidateIsFree = await _isUsernameAvailable(candidate);
      if (!mounted || requestId != _usernameFeedbackRequestId) return null;
      if (candidateIsFree) return candidate;
    }

    return null;
  }

  OutlineInputBorder _authFieldBorder(Color color, {double width = 1.2}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  InputDecoration _authFieldDecoration({
    required String hintText,
    required bool hasError,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    const errorColor = Color(0xFFFF6B6B);
    final idleBorder = _authFieldBorder(Colors.white.withValues(alpha: 0.08));
    final normalFocusBorder = _authFieldBorder(appGreen, width: 1.6);
    final errorBorder = _authFieldBorder(errorColor, width: 1.5);

    return InputDecoration(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      hintText: hintText,
      hintStyle: _inter.copyWith(
        color: Colors.white.withValues(alpha: 0.42),
        fontWeight: FontWeight.w600,
      ),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      border: hasError ? errorBorder : idleBorder,
      enabledBorder: hasError ? errorBorder : idleBorder,
      focusedBorder: hasError ? errorBorder : normalFocusBorder,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  Widget _warningIcon() {
    return const Padding(
      padding: EdgeInsets.only(right: 6),
      child: Icon(
        Icons.warning_amber_rounded,
        color: Color(0xFFFF6B6B),
        size: 20,
      ),
    );
  }

  Widget _buildFieldMessage(
    String message, {
    required Color color,
    FontWeight fontWeight = FontWeight.w500,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: Text(
        message,
        style: _inter.copyWith(
          fontSize: 12,
          fontWeight: fontWeight,
          color: color,
        ),
      ),
    );
  }

  void _applyUsernameSuggestion() {
    final suggestion = _usernameSuggestion;
    if (suggestion == null || suggestion.isEmpty) return;

    usernameCtrl.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    _scheduleUsernameFeedback();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openSignupVerificationScreen({
    required String email,
    required String username,
  }) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _SignupEmailVerificationScreen(email: email, username: username),
      ),
    );
  }

  void _showLegalSheet({required String title, required String body}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: 0.85,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: _inter.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: SelectableText(
                        body,
                        style: _inter.copyWith(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.black.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openTermsOfUse() {
    _showLegalSheet(
      title: t('Nutzungsbedingungen', 'Terms of Use'),
      body: sideQuestTermsOfUseText(),
    );
  }

  void _openPrivacyPolicy() {
    _showLegalSheet(
      title: t('Datenschutzerklärung', 'Privacy Policy'),
      body: sideQuestPrivacyPolicyText(),
    );
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Link konnte nicht geöffnet werden.', 'Could not open link.'),
          ),
        ),
      );
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final controller = TextEditingController(text: emailCtrl.text.trim());

    final requested = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(t('Passwort zurücksetzen', 'Reset password')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t(
                  'Wir senden dir einen Link zum Zurücksetzen deines Passworts.',
                  'We will send you a link to reset your password.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: t('E-Mail', 'Email')),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('Abbrechen', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t('Link senden', 'Send link')),
            ),
          ],
        );
      },
    );

    final email = controller.text.trim();
    controller.dispose();
    if (requested != true) return;

    if (!_emailPattern.hasMatch(email)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Bitte gib eine gültige E-Mail ein',
              'Please enter a valid email',
            ),
          ),
        ),
      );
      return;
    }

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb
            ? AppEnvironment.websiteUrl
            : AppEnvironment.mobileAuthRedirectUrl,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Der Reset-Link wurde an deine E-Mail gesendet.',
              'The reset link was sent to your email.',
            ),
          ),
        ),
      );
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      AppLogger.error('Password reset request failed', e);
    }
  }

  Widget _buildLegalConsentCard() {
    final bodyStyle = _inter.copyWith(
      fontSize: 13,
      color: Colors.white.withValues(alpha: 0.74),
      height: 1.35,
      fontWeight: FontWeight.w500,
    );

    ButtonStyle linkStyle() => TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 0),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: appGreen,
      textStyle: _inter.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        decoration: TextDecoration.underline,
        decorationColor: appGreen.withValues(alpha: 0.6),
      ),
    );

    Widget buildCheckboxLine({
      required bool value,
      required ValueChanged<bool?>? onChanged,
      required Widget child,
    }) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Theme(
            data: Theme.of(context).copyWith(
              checkboxTheme: CheckboxThemeData(
                fillColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return appGreen;
                  return Colors.transparent;
                }),
                checkColor: WidgetStateProperty.all(const Color(0xFF0B1108)),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.32),
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            child: Checkbox(value: value, onChanged: onChanged),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: child,
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          buildCheckboxLine(
            value: _acceptedLegal,
            onChanged: loading
                ? null
                : (value) {
                    setState(() => _acceptedLegal = value ?? false);
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      t('Ich akzeptiere die ', 'I accept the '),
                      style: bodyStyle,
                    ),
                    TextButton(
                      onPressed: _openTermsOfUse,
                      style: linkStyle(),
                      child: Text(t('Nutzungsbedingungen', 'Terms of Use')),
                    ),
                    Text(t(' und die ', ' and the '), style: bodyStyle),
                    TextButton(
                      onPressed: _openPrivacyPolicy,
                      style: linkStyle(),
                      child: Text(t('Datenschutzerklärung', 'Privacy Policy')),
                    ),
                    Text('.', style: bodyStyle),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton(
                      onPressed: () =>
                          _openExternalUrl(AppEnvironment.termsUrl),
                      style: linkStyle(),
                      child: Text(t('AGB online öffnen', 'Open terms online')),
                    ),
                    TextButton(
                      onPressed: () =>
                          _openExternalUrl(AppEnvironment.privacyUrl),
                      style: linkStyle(),
                      child: Text(
                        t('Datenschutz online öffnen', 'Open privacy online'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TextEditingValue _formatUsernameValue(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final sanitized = UsernameFilter.sanitizeLiveInput(newValue.text);
    return TextEditingValue(
      text: sanitized,
      selection: TextSelection.collapsed(offset: sanitized.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryActionEnabled = !loading && (!isSignUp || _canSubmitSignUp);
    final usernameErrorText = _usernameErrorText;
    final emailErrorText = _emailErrorText;
    final passwordErrorText = _passwordErrorText;
    final usernameSuffixIcon = usernameErrorText != null
        ? _warningIcon()
        : _isCheckingUsernameFeedback
        ? const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          )
        : null;

    void toggleAuthMode(bool signUp) {
      if (isSignUp == signUp) return;
      if (signUp) AnalyticsService.logOnboardingStarted();
      _clearUsernameFeedbackState(notify: false);
      setState(() {
        isSignUp = signUp;
        _acceptedLegal = false;
      });
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF1C1C1E),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF1C1C1E),
        resizeToAvoidBottomInset: true,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final bottomInset = MediaQuery.of(context).viewInsets.bottom;
            final compactHeight = constraints.maxHeight < 720;

            return Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0xFF1C1C1E),
                    ),
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(22, 6, 22, 26 + bottomInset),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 44,
                      ),
                      child: Column(
                        children: [
                          // Hero column shrink-wraps so longer translations
                          // (DE strings are typically ~20% longer than EN)
                          // never overflow. The vertical padding gives the
                          // logo a bit of breathing room without locking us
                          // into magic-number heights.
                          Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: compactHeight ? 14 : 22,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Image.asset(
                                  'assets/login_hero.png',
                                  height: compactHeight ? 110 : 140,
                                  fit: BoxFit.contain,
                                ),
                                const SizedBox(height: 4),
                                ShaderMask(
                                  shaderCallback: (bounds) => LinearGradient(
                                    colors: [
                                      Colors.white,
                                      appGreen,
                                    ],
                                  ).createShader(bounds),
                                  child: Text(
                                    t(
                                      'Deine Crew. Eure Quests.',
                                      'Your crew. Your quests.',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: _inter.copyWith(
                                      color: Colors.white,
                                      fontSize: compactHeight ? 22 : 26,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.5,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t(
                                    'Chats, Reaktionen und tägliche Quests.',
                                    'Chats, reactions, and daily quests.',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: _inter.copyWith(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxWidth: 430),
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.03),
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.07),
                                width: 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  height: 48,
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.06,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _AuthModeButton(
                                          label: t('Anmelden', 'Sign in'),
                                          selected: !isSignUp,
                                          onTap: () => toggleAuthMode(false),
                                        ),
                                      ),
                                      Expanded(
                                        child: _AuthModeButton(
                                          label: t('Registrieren', 'Sign up'),
                                          selected: isSignUp,
                                          onTap: () => toggleAuthMode(true),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  isSignUp
                                      ? t(
                                          'Starte mit deiner Crew',
                                          'Start with your crew',
                                        )
                                      : t('Willkommen zurück', 'Welcome back'),
                                  style: _inter.copyWith(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                if (isSignUp) ...[
                                  TextField(
                                    controller: usernameCtrl,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    cursorColor: appGreen,
                                    textCapitalization: TextCapitalization.none,
                                    inputFormatters: [
                                      TextInputFormatter.withFunction(
                                        _formatUsernameValue,
                                      ),
                                    ],
                                    style: _inter.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                    decoration: _authFieldDecoration(
                                      hintText: t("Benutzername", "Username"),
                                      hasError: usernameErrorText != null,
                                      prefixIcon: Icon(
                                        Icons.alternate_email_rounded,
                                        color: Colors.white.withValues(
                                          alpha: 0.45,
                                        ),
                                      ),
                                      suffixIcon: usernameSuffixIcon,
                                    ),
                                  ),
                                  if (usernameErrorText != null)
                                    _buildFieldMessage(
                                      usernameErrorText,
                                      color: const Color(0xFFFF6B6B),
                                    ),
                                  if (_isUsernameTaken &&
                                      _usernameSuggestion != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 4,
                                        top: 6,
                                      ),
                                      child: Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            t('Vorschlag:', 'Suggestion:'),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white.withValues(
                                                alpha: 0.6,
                                              ),
                                            ),
                                          ),
                                          GestureDetector(
                                            onTap: _applyUsernameSuggestion,
                                            child: Text(
                                              _usernameSuggestion!,
                                              style: _inter.copyWith(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w900,
                                                color: appGreen,
                                                decoration:
                                                    TextDecoration.underline,
                                                decorationColor: appGreen
                                                    .withValues(alpha: 0.6),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  const SizedBox(height: 12),
                                ],
                                TextField(
                                  controller: emailCtrl,
                                  keyboardType: TextInputType.emailAddress,
                                  cursorColor: appGreen,
                                  style: _inter.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                  decoration: _authFieldDecoration(
                                    hintText: t("E-Mail", "Email"),
                                    hasError: emailErrorText != null,
                                    prefixIcon: Icon(
                                      Icons.mail_outline_rounded,
                                      color: Colors.white.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                                    suffixIcon: emailErrorText != null
                                        ? _warningIcon()
                                        : null,
                                  ),
                                ),
                                if (emailErrorText != null)
                                  _buildFieldMessage(
                                    emailErrorText,
                                    color: const Color(0xFFFF6B6B),
                                  ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: passCtrl,
                                  obscureText: true,
                                  cursorColor: appGreen,
                                  style: _inter.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                  decoration: _authFieldDecoration(
                                    hintText: t("Passwort", "Password"),
                                    hasError: passwordErrorText != null,
                                    prefixIcon: Icon(
                                      Icons.lock_outline_rounded,
                                      color: Colors.white.withValues(
                                        alpha: 0.45,
                                      ),
                                    ),
                                    suffixIcon: passwordErrorText != null
                                        ? _warningIcon()
                                        : null,
                                  ),
                                ),
                                if (passwordErrorText != null)
                                  _buildFieldMessage(
                                    passwordErrorText,
                                    color: const Color(0xFFFF6B6B),
                                  ),
                                if (!isSignUp) ...[
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      style: TextButton.styleFrom(
                                        foregroundColor: appGreen,
                                        padding: EdgeInsets.zero,
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: loading || _socialLoading
                                          ? null
                                          : _showForgotPasswordDialog,
                                      child: Text(
                                        t(
                                          'Passwort vergessen?',
                                          'Forgot password?',
                                        ),
                                        style: _inter.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                if (isSignUp) _buildLegalConsentCard(),
                                SizedBox(height: isSignUp ? 22 : 18),
                                ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: appGreen,
                                      disabledBackgroundColor: Colors.white
                                          .withValues(alpha: 0.10),
                                      disabledForegroundColor: Colors.white
                                          .withValues(alpha: 0.45),
                                      foregroundColor: const Color(0xFF0B1108),
                                      minimumSize: const Size(
                                        double.infinity,
                                        56,
                                      ),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(17),
                                      ),
                                    ),
                                    onPressed: primaryActionEnabled
                                        ? _login
                                        : null,
                                    child: loading
                                        ? const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              color: Color(0xFF0B1108),
                                              strokeWidth: 2.4,
                                            ),
                                          )
                                        : Text(
                                            isSignUp
                                                ? t(
                                                    "Account erstellen",
                                                    "Create account",
                                                  )
                                                : t("Einloggen", "Sign in"),
                                            style: _inter.copyWith(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w900,
                                              color: const Color(0xFF0B1108),
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                  ),
                                const SizedBox(height: 20),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Divider(
                                        color: Colors.white.withValues(
                                          alpha: 0.08,
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        t('oder', 'or'),
                                        style: _inter.copyWith(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white.withValues(
                                            alpha: 0.42,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Divider(
                                        color: Colors.white.withValues(
                                          alpha: 0.08,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  height: 54,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: const Color(0xFF1F1F1F),
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(17),
                                      ),
                                    ),
                                    onPressed: (_socialLoading || loading)
                                        ? null
                                        : _signInWithGoogle,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CustomPaint(
                                            painter: const _GoogleLogoPainter(),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          t(
                                            'Weiter mit Google',
                                            'Continue with Google',
                                          ),
                                          style: _inter.copyWith(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: const Color(0xFF1F1F1F),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (!kIsWeb &&
                                    defaultTargetPlatform ==
                                        TargetPlatform.iOS) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 54,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            17,
                                          ),
                                        ),
                                      ),
                                      onPressed: (_socialLoading || loading)
                                          ? null
                                          : _signInWithApple,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          const SizedBox(
                                            width: 18,
                                            height: 22,
                                            child: CustomPaint(
                                              painter: _AppleLogoPainter(),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Text(
                                            t(
                                              'Weiter mit Apple',
                                              'Continue with Apple',
                                            ),
                                            style: _inter.copyWith(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (_socialLoading)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: appGreen,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _login() async {
    setState(() => loading = true);

    try {
      final client = Supabase.instance.client;
      final email = emailCtrl.text.trim().toLowerCase();
      final password = passCtrl.text.trim();

      if (isSignUp) {
        // Registrierung
        if (email.isEmpty ||
            password.isEmpty ||
            usernameCtrl.text.trim().isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_fillAllFieldsMessage())));
          }
          setState(() => loading = false);
          return;
        }

        if (!_acceptedLegal) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_legalConsentMessage())));
          }
          setState(() => loading = false);
          return;
        }

        if (_emailErrorText != null) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_emailErrorText!)));
          }
          setState(() => loading = false);
          return;
        }

        if (_passwordErrorText != null) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_passwordErrorText!)));
          }
          setState(() => loading = false);
          return;
        }

        final usernameValidation = UsernameFilter.validate(usernameCtrl.text);
        if (!usernameValidation.isValid) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  _usernameValidationMessage(usernameValidation.error),
                ),
              ),
            );
          }
          setState(() => loading = false);
          return;
        }

        final username = usernameValidation.normalized;
        if (usernameCtrl.text.trim() != username) {
          usernameCtrl.value = TextEditingValue(
            text: username,
            selection: TextSelection.collapsed(offset: username.length),
          );
        }

        final isUsernameAvailable = await _isUsernameAvailable(username);
        if (!isUsernameAvailable) {
          final suggestion = await _generateUsernameSuggestion(
            username,
            _usernameFeedbackRequestId,
          );
          if (mounted) {
            setState(() {
              _isCheckingUsernameFeedback = false;
              _isUsernameTaken = true;
              _usernameSuggestion = suggestion;
            });
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(_usernameAlreadyTakenMessage())),
            );
          }
          setState(() => loading = false);
          return;
        }

        // Zuerst registrieren (Username in user_metadata speichern)
        final authResponse = await client.auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: kIsWeb
              ? AppEnvironment.websiteUrl
              : AppEnvironment.mobileAuthRedirectUrl,
          data: {
            'username': username,
            ...requiredLegalMetadataPayload(),
          },
        );

        await AnalyticsService.logOnboardingCompleted(
          emailConfirmedSession: authResponse.session != null,
        );

        // Bei Email-Confirmation ist session oft null -> RLS würde Inserts blocken.
        // Profil wird dann beim ersten Login erstellt (siehe Login-Zweig unten).
        if (authResponse.session != null) {
          try {
            await ensureUserProfileExists(
              client,
              preferredUsername: username,
              userOverride: authResponse.user,
            );
          } on PostgrestException catch (e) {
            if (_looksLikeUsernameConflict(e.message)) {
              final suggestion = await _generateUsernameSuggestion(
                username,
                _usernameFeedbackRequestId,
              );
              if (mounted) {
                setState(() {
                  _isCheckingUsernameFeedback = false;
                  _isUsernameTaken = true;
                  _usernameSuggestion = suggestion;
                });
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_usernameAlreadyTakenMessage())),
                );
              }
              setState(() => loading = false);
              return;
            }
            rethrow;
          }
        }

        if (authResponse.session == null) {
          if (mounted) {
            setState(() => loading = false);
            await _openSignupVerificationScreen(
              email: email,
              username: username,
            );
          }
          return;
        }
      } else {
        // Login
        final authResponse = await client.auth.signInWithPassword(
          email: email,
          password: password,
        );

        await AnalyticsService.setUserId(authResponse.user?.id);
        await AnalyticsService.logLoginSuccess();

        // Kleine Verzögerung damit Auth aktualisiert ist
        await Future.delayed(const Duration(milliseconds: 500));

        // Falls Profil (noch) fehlt: jetzt erstellen (User ist authentifiziert)
        try {
          await ensureUserProfileExists(
            client,
            userOverride: authResponse.user,
          );
        } on PostgrestException catch (e) {
          AppLogger.warn(
            'ensureUserProfileExists failed after login: code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}',
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  t(
                    'Profil konnte nicht erstellt werden: ${e.message}',
                    'Profile could not be created: ${e.message}',
                  ),
                ),
              ),
            );
          }
        } catch (e) {
          AppLogger.warn('ensureUserProfileExists failed after login: $e');
        }
      }
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      final hasUsernameConflict =
          isSignUp && _looksLikeUsernameConflict(e.message);
      if (hasUsernameConflict) {
        final suggestion = await _generateUsernameSuggestion(
          usernameCtrl.text.trim(),
          _usernameFeedbackRequestId,
        );
        if (mounted) {
          setState(() {
            _isCheckingUsernameFeedback = false;
            _isUsernameTaken = true;
            _usernameSuggestion = suggestion;
          });
        }
      }
      final message = hasUsernameConflict
          ? _usernameAlreadyTakenMessage()
          : t(mapped.de, mapped.en);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      AppLogger.warn("Auth error: ${e.message}");
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.error("General error during login", e);
    }

    if (mounted) setState(() => loading = false);
  }

  Future<void> _signInWithGoogle() async {
    if (_socialLoading) return;
    setState(() => _socialLoading = true);

    try {
      final client = Supabase.instance.client;
      final launched = await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : AppEnvironment.mobileAuthRedirectUrl,
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
      if (!launched) {
        throw Exception('Google OAuth browser could not be opened.');
      }
    } on AuthException catch (e) {
      final message = e.message.toLowerCase();
      final isRedirectIssue =
          message.contains('redirect') || message.contains('invalid request');
      final mapped = isRedirectIssue
          ? const UiErrorText(
              'Die Google-Anmeldung ist gerade nicht verfügbar. Bitte melde dich mit E-Mail an oder versuche es später erneut.',
              'Google sign-in is currently unavailable. Please use email or try again later.',
            )
          : ErrorMapper.auth(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.warn("Google OAuth auth error: ${e.message}");
    } on PlatformException catch (e) {
      final details = '${e.code}: ${e.message ?? 'Unknown OAuth launch error'}';
      final normalized = details.toLowerCase();
      final isConfigIssue =
          normalized.contains('no activity found') ||
          normalized.contains('no app found') ||
          normalized.contains('not supported') ||
          normalized.contains('component name for') ||
          normalized.contains('launch');
      final mapped = isConfigIssue
          ? const UiErrorText(
              'Die Google-Anmeldung konnte nicht geöffnet werden. Bitte versuche es erneut.',
              'Google sign-in could not be opened. Please try again.',
            )
          : ErrorMapper.generic(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.warn('Google OAuth platform error: $details');
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.error("Google OAuth sign-in error", e);
    }

    if (mounted) setState(() => _socialLoading = false);
  }

  // ---------------------------------------------------------------------------
  // Apple Sign-In (native iOS flow → Supabase signInWithIdToken)
  // ---------------------------------------------------------------------------
  Future<void> _signInWithApple() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (_socialLoading) return;
    setState(() => _socialLoading = true);

    try {
      // Generate a cryptographic nonce for security
      final rawNonce = _generateNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final idToken = credential.identityToken;
      if (idToken == null) {
        throw Exception('Apple Sign-In failed: no identity token received.');
      }

      final client = Supabase.instance.client;
      final authResponse = await client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );

      await AnalyticsService.setUserId(authResponse.user?.id);
      await AnalyticsService.logLoginSuccess();

      // Ensure profile exists for new OAuth users
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await ensureUserProfileExists(client, userOverride: authResponse.user);
      } catch (e) {
        AppLogger.warn('ensureUserProfileExists failed after Apple login: $e');
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t('Apple-Anmeldung fehlgeschlagen', 'Apple sign-in failed'),
              ),
            ),
          );
        }
        AppLogger.warn("Apple auth error: ${e.code} ${e.message}");
      }
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.warn("Supabase auth error (Apple): ${e.message}");
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      }
      AppLogger.error("Apple sign-in error", e);
    }

    if (mounted) setState(() => _socialLoading = false);
  }

  /// Generates a cryptographically secure random nonce (32 bytes, URL-safe).
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = math.Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }
}

class _SignupEmailVerificationScreen extends StatefulWidget {
  final String email;
  final String username;

  const _SignupEmailVerificationScreen({
    required this.email,
    required this.username,
  });

  @override
  State<_SignupEmailVerificationScreen> createState() =>
      _SignupEmailVerificationScreenState();
}

class _SignupEmailVerificationScreenState
    extends State<_SignupEmailVerificationScreen> {
  final TextEditingController _codeCtrl = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  Timer? _resendCooldownTimer;
  bool _verifying = false;
  bool _resending = false;
  int _resendCooldownSeconds = 30;

  @override
  void initState() {
    super.initState();
    _codeCtrl.addListener(_handleCodeChanged);
    _codeFocusNode.addListener(_refreshCodeBoxes);
    _startResendCooldown();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCodeField());
  }

  @override
  void dispose() {
    _resendCooldownTimer?.cancel();
    _codeCtrl.removeListener(_handleCodeChanged);
    _codeFocusNode.removeListener(_refreshCodeBoxes);
    _codeCtrl.dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  void _refreshCodeBoxes() {
    if (mounted) {
      setState(() {});
    }
  }

  String _normalizedCode(String raw) {
    final digitsOnly = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.length <= 6) return digitsOnly;
    return digitsOnly.substring(0, 6);
  }

  void _handleCodeChanged() {
    final normalized = _normalizedCode(_codeCtrl.text);
    if (normalized != _codeCtrl.text) {
      _codeCtrl.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
      return;
    }

    if (mounted) {
      setState(() {});
    }

    if (normalized.length == 6 && !_verifying) {
      unawaited(_submitCode(autoTriggered: true));
    }
  }

  void _focusCodeField() {
    if (!_codeFocusNode.hasFocus) {
      _codeFocusNode.requestFocus();
    }
  }

  void _startResendCooldown([int seconds = 30]) {
    _resendCooldownTimer?.cancel();
    _resendCooldownSeconds = seconds;
    _resendCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _resendCooldownSeconds = 0);
        return;
      }
      setState(() => _resendCooldownSeconds -= 1);
    });
  }

  Future<AuthResponse> _verifySignupOtp(String code) async {
    final client = Supabase.instance.client;

    try {
      return await client.auth.verifyOTP(
        email: widget.email,
        token: code,
        type: OtpType.email,
      );
    } on AuthException {
      return client.auth.verifyOTP(
        email: widget.email,
        token: code,
        type: OtpType.signup,
      );
    }
  }

  Future<void> _submitCode({bool autoTriggered = false}) async {
    if (_verifying) return;

    final code = _normalizedCode(_codeCtrl.text);
    if (code.length != 6) {
      if (!autoTriggered && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Bitte gib den 6-stelligen Code ein.',
                'Please enter the 6-digit code.',
              ),
            ),
          ),
        );
      }
      _focusCodeField();
      return;
    }

    setState(() => _verifying = true);

    try {
      final authResponse = await _verifySignupOtp(code);
      await AnalyticsService.setUserId(authResponse.user?.id);
      await AnalyticsService.logLoginSuccess();

      await Future<void>.delayed(const Duration(milliseconds: 350));

      try {
        await ensureUserProfileExists(
          Supabase.instance.client,
          preferredUsername: widget.username,
          userOverride: authResponse.user,
        );
      } on PostgrestException catch (e) {
        AppLogger.warn(
          'ensureUserProfileExists failed after email verification: code=${e.code} message=${e.message} details=${e.details} hint=${e.hint}',
        );
      } catch (e) {
        AppLogger.warn(
          'ensureUserProfileExists failed after email verification: $e',
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      _codeCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _codeCtrl.text.length,
      );
      _focusCodeField();
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      AppLogger.error('Signup OTP verification failed', e);
      _focusCodeField();
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  Future<void> _resendCode() async {
    if (_resending || _resendCooldownSeconds > 0) return;

    setState(() => _resending = true);
    try {
      await Supabase.instance.client.auth.resend(
        type: OtpType.signup,
        email: widget.email,
        emailRedirectTo: kIsWeb
            ? AppEnvironment.websiteUrl
            : AppEnvironment.mobileAuthRedirectUrl,
      );
      _codeCtrl.clear();
      _startResendCooldown();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Wir haben dir einen neuen Code geschickt.',
              'We sent you a new code.',
            ),
          ),
        ),
      );
      _focusCodeField();
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      AppLogger.error('Signup OTP resend failed', e);
    } finally {
      if (mounted) {
        setState(() => _resending = false);
      }
    }
  }

  Widget _buildCodeBox(int index) {
    final code = _normalizedCode(_codeCtrl.text);
    final char = index < code.length ? code[index] : '';
    final hasValue = char.isNotEmpty;
    final activeIndex = code.length >= 6 ? 5 : code.length;
    final isActive = _codeFocusNode.hasFocus && index == activeIndex;

    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 62,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasValue || isActive
                ? Colors.black.withValues(alpha: 0.55)
                : Colors.black.withValues(alpha: 0.08),
            width: isActive ? 1.8 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: hasValue ? 0.08 : 0.04),
              blurRadius: hasValue ? 14 : 8,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Text(
          char,
          style: _inter.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final code = _normalizedCode(_codeCtrl.text);
    final continueEnabled = code.length == 6 && !_verifying;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFAAD68F),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFAAD68F),
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 18, 24, 28 + bottomInset),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    onPressed: _verifying
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    t(
                      'Gib den Bestätigungscode ein',
                      'Enter the confirmation code',
                    ),
                    style: _inter.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: t(
                            'Wir haben dir einen 6-stelligen Code an ',
                            'We sent a 6-digit code to ',
                          ),
                        ),
                        TextSpan(
                          text: widget.email,
                          style: _inter.copyWith(fontWeight: FontWeight.w800),
                        ),
                        TextSpan(
                          text: t(
                            ' geschickt. Sobald der Code stimmt, bist du direkt drin.',
                            '. As soon as the code is correct, you are signed in immediately.',
                          ),
                        ),
                      ],
                      style: _inter.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withValues(alpha: 0.72),
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _focusCodeField,
                    child: Row(
                      children: [
                        for (var i = 0; i < 6; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          _buildCodeBox(i),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 1,
                    child: Opacity(
                      opacity: 0,
                      child: TextField(
                        controller: _codeCtrl,
                        focusNode: _codeFocusNode,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        enableSuggestions: false,
                        autocorrect: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        onSubmitted: (_) => unawaited(_submitCode()),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: continueEnabled ? _submitCode : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.black.withValues(
                          alpha: 0.3,
                        ),
                        minimumSize: const Size.fromHeight(56),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: _verifying
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              t('Code bestätigen', 'Confirm code'),
                              style: _inter.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: (_resending || _verifying)
                          ? null
                          : _resendCooldownSeconds > 0
                          ? null
                          : _resendCode,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.black.withValues(alpha: 0.72),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: _resending
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black.withValues(alpha: 0.72),
                              ),
                            )
                          : Text(
                              _resendCooldownSeconds > 0
                                  ? t(
                                      'Code erneut senden in $_resendCooldownSeconds s',
                                      'Resend code in $_resendCooldownSeconds s',
                                    )
                                  : t(
                                      'Ich habe keinen Code erhalten',
                                      'I did not get the code',
                                    ),
                              style: _inter.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black.withValues(alpha: 0.72),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AccountComplianceGate extends StatefulWidget {
  const AccountComplianceGate({super.key});

  @override
  State<AccountComplianceGate> createState() => _AccountComplianceGateState();
}

class _AccountComplianceGateState extends State<AccountComplianceGate> {
  bool _acceptedLegal = false;
  bool _saving = false;

  Future<void> _saveAndContinue() async {
    if (!_acceptedLegal) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Bitte bestätige die Nutzungsbedingungen und den Datenschutz.',
              'Please confirm the terms and the privacy policy.',
            ),
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final currentMetadata = Map<String, Object?>.from(
        client.auth.currentUser?.userMetadata ?? const <String, Object?>{},
      );
      await client.auth.updateUser(
        UserAttributes(
          data: <String, Object?>{
            ...currentMetadata,
            ...requiredLegalMetadataPayload(),
          },
        ),
      );
      await ensureUserProfileExists(client);
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      AppLogger.error('Failed to persist legal compliance', e);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _signOut() async {
    await signOutSideQuest();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFAAD68F),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t('Bevor es weitergeht', 'Before you continue'),
                    style: _inter.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    t(
                      'Bitte bestätige einmal die aktuellen Nutzungsbedingungen und die Datenschutzerklärung.',
                      'Please confirm the current Terms of Use and Privacy Policy once.',
                    ),
                    style: _inter.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withValues(alpha: 0.68),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  CheckboxListTile(
                    value: _acceptedLegal,
                    onChanged: _saving
                        ? null
                        : (value) {
                            setState(() => _acceptedLegal = value ?? false);
                          },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      t(
                        'Ich akzeptiere die Nutzungsbedingungen und die Datenschutzerklärung.',
                        'I accept the Terms of Use and Privacy Policy.',
                      ),
                      style: _inter.copyWith(fontSize: 14),
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => showSideQuestLegalSheet(
                                context,
                                title: t('Nutzungsbedingungen', 'Terms of Use'),
                                body: sideQuestTermsOfUseText(),
                              ),
                        child: Text(
                          t('Nutzungsbedingungen lesen', 'Read the terms'),
                        ),
                      ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => showSideQuestLegalSheet(
                                context,
                                title: t('Datenschutzerklärung', 'Privacy Policy'),
                                body: sideQuestPrivacyPolicyText(),
                              ),
                        child: Text(t('Datenschutz lesen', 'Read the privacy policy')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _saveAndContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t('Weiter', 'Continue')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _saving ? null : _signOut,
                      child: Text(t('Abmelden', 'Sign out')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({super.key});

  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  String? _passwordErrorText(String value) {
    if (value.length < 8) {
      return t('Mindestens 8 Zeichen', 'At least 8 characters');
    }
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return t('Mindestens ein Großbuchstabe', 'At least one uppercase letter');
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return t('Mindestens eine Zahl', 'At least one digit');
    }
    return null;
  }

  Future<void> _submit() async {
    final password = _passwordCtrl.text;
    final confirmPassword = _confirmCtrl.text;
    final validationError = _passwordErrorText(password);
    if (validationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }
    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Die Passwörter stimmen nicht überein.',
              'Passwords do not match.',
            ),
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: password),
      );
      setPasswordRecoveryMode(false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Dein Passwort wurde aktualisiert.',
              'Your password has been updated.',
            ),
          ),
        ),
      );
    } on AuthException catch (e) {
      final mapped = ErrorMapper.auth(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
    } catch (e) {
      final mapped = ErrorMapper.generic(e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t(mapped.de, mapped.en))));
      AppLogger.error('Password recovery update failed', e);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _cancelRecovery() async {
    setPasswordRecoveryMode(false);
    await Supabase.instance.client.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFAAD68F),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t('Neues Passwort setzen', 'Set a new password'),
                    style: _inter.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    t(
                      'Wähle jetzt ein neues Passwort für dein Konto.',
                      'Choose a new password for your account.',
                    ),
                    style: _inter.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black.withValues(alpha: 0.68),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: t('Neues Passwort', 'New password'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: t('Passwort wiederholen', 'Confirm password'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(t('Passwort speichern', 'Save password')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _saving ? null : _cancelRecovery,
                      child: Text(t('Abbrechen', 'Cancel')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the exact Google "G" paths from Google's official sign-in asset.
class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const viewBoxSize = 20.0;
    final scale = math.min(size.width, size.height) / viewBoxSize;
    final dx = (size.width - (viewBoxSize * scale)) / 2;
    final dy = (size.height - (viewBoxSize * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final bluePaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    final greenPaint = Paint()
      ..color = const Color(0xFF34A853)
      ..style = PaintingStyle.fill;
    final yellowPaint = Paint()
      ..color = const Color(0xFFFBBC04)
      ..style = PaintingStyle.fill;
    final redPaint = Paint()
      ..color = const Color(0xFFE94235)
      ..style = PaintingStyle.fill;

    final bluePath = Path()
      ..moveTo(19.6, 10.2273)
      ..cubicTo(19.6, 9.5182, 19.5364, 8.8364, 19.4182, 8.1818)
      ..lineTo(10, 8.1818)
      ..lineTo(10, 12.05)
      ..lineTo(15.3818, 12.05)
      ..cubicTo(15.15, 13.3, 14.4455, 14.3591, 13.3864, 15.0682)
      ..lineTo(13.3864, 17.5773)
      ..lineTo(16.6182, 17.5773)
      ..cubicTo(18.5091, 15.8364, 19.6, 13.2727, 19.6, 10.2273)
      ..close();

    final greenPath = Path()
      ..moveTo(10, 20)
      ..cubicTo(12.7, 20, 14.9636, 19.1045, 16.6181, 17.5773)
      ..lineTo(13.3863, 15.0682)
      ..cubicTo(12.4909, 15.6682, 11.3454, 16.0227, 10, 16.0227)
      ..cubicTo(7.3954, 16.0227, 5.1909, 14.2636, 4.4045, 11.9)
      ..lineTo(1.0636, 11.9)
      ..lineTo(1.0636, 14.4909)
      ..cubicTo(2.7091, 17.7591, 6.0909, 20, 10, 20)
      ..close();

    final yellowPath = Path()
      ..moveTo(4.4045, 11.9)
      ..cubicTo(4.2045, 11.3, 4.0909, 10.6591, 4.0909, 10)
      ..cubicTo(4.0909, 9.3409, 4.2045, 8.7, 4.4045, 8.1)
      ..lineTo(4.4045, 5.5091)
      ..lineTo(1.0636, 5.5091)
      ..cubicTo(0.3864, 6.8591, 0, 8.3864, 0, 10)
      ..cubicTo(0, 11.6136, 0.3864, 13.1409, 1.0636, 14.4909)
      ..lineTo(4.4045, 11.9)
      ..close();

    final redPath = Path()
      ..moveTo(10, 3.9773)
      ..cubicTo(11.4681, 3.9773, 12.7863, 4.4818, 13.8227, 5.4727)
      ..lineTo(16.6909, 2.6045)
      ..cubicTo(14.9591, 0.9909, 12.6954, 0, 10, 0)
      ..cubicTo(6.0909, 0, 2.7091, 2.2409, 1.0636, 5.5091)
      ..lineTo(4.4045, 8.1)
      ..cubicTo(5.1909, 5.7364, 7.3954, 3.9773, 10, 3.9773)
      ..close();

    canvas.drawPath(bluePath, bluePaint);
    canvas.drawPath(greenPath, greenPaint);
    canvas.drawPath(yellowPath, yellowPaint);
    canvas.drawPath(redPath, redPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints the Apple logo silhouette from a vector source.
class _AppleLogoPainter extends CustomPainter {
  const _AppleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const viewBoxWidth = 814.0;
    const viewBoxHeight = 1000.0;

    final scale = math.min(
      size.width / viewBoxWidth,
      size.height / viewBoxHeight,
    );
    final dx = (size.width - (viewBoxWidth * scale)) / 2;
    final dy = (size.height - (viewBoxHeight * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(788.1, 340.9)
      ..cubicTo(782.3, 345.4, 679.9, 403.1, 679.9, 531.4)
      ..cubicTo(679.9, 679.8, 810.2, 732.3, 814.1, 733.6)
      ..cubicTo(813.5, 736.8, 793.4, 805.5, 745.4, 875.5)
      ..cubicTo(702.6, 937.1, 657.9, 998.6, 589.9, 998.6)
      ..cubicTo(521.9, 998.6, 504.4, 959.1, 425.9, 959.1)
      ..cubicTo(349.4, 959.1, 322.2, 999.9, 260.0, 999.9)
      ..cubicTo(197.8, 999.9, 154.4, 942.9, 104.5, 872.9)
      ..cubicTo(46.7, 790.7, 0.0, 663.0, 0.0, 541.8)
      ..cubicTo(0.0, 347.4, 126.4, 244.3, 250.8, 244.3)
      ..cubicTo(316.9, 244.3, 372.0, 287.7, 413.5, 287.7)
      ..cubicTo(453.0, 287.7, 514.6, 241.7, 589.8, 241.7)
      ..cubicTo(618.3, 241.7, 720.7, 244.3, 788.1, 340.9)
      ..close()
      ..moveTo(554.1, 159.4)
      ..cubicTo(585.2, 122.5, 607.2, 71.3, 607.2, 20.1)
      ..cubicTo(607.2, 13.0, 606.6, 5.8, 605.3, 0.0)
      ..cubicTo(554.7, 1.9, 494.5, 33.7, 458.2, 75.8)
      ..cubicTo(429.7, 108.2, 403.1, 159.4, 403.1, 211.3)
      ..cubicTo(403.1, 219.1, 404.4, 226.9, 405.0, 229.4)
      ..cubicTo(408.2, 230.0, 413.4, 230.7, 418.6, 230.7)
      ..cubicTo(464.0, 230.7, 521.1, 200.3, 554.1, 159.4)
      ..close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _UnreadMentionTarget {
  final String notificationId;
  final PostFocusRequest request;

  const _UnreadMentionTarget({
    required this.notificationId,
    required this.request,
  });
}

int _readIntValue(dynamic raw, {int fallback = 0}) {
  if (raw == null) return fallback;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return num.tryParse(raw.toString().trim())?.toInt() ?? fallback;
}

int? _readNullableIntValue(dynamic raw) {
  if (raw == null) return null;
  return _readIntValue(raw);
}

class MainTabs extends StatefulWidget {
  const MainTabs({super.key});

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> with WidgetsBindingObserver {
  static const Duration _postStatusLoaderDelay = Duration(milliseconds: 420);

  int index = 0;
  bool _profileEnsuredOnce = false;
  bool hasPostedToday = false;
  bool isCheckingPostStatus = true;
  bool _showPostStatusLoader = false;
  Map<String, dynamic>? userProfile;
  int unreadCount = 0;
  int unreadFeedNotificationCount = 0;
  int unreadLeaderboardNotificationCount = 0;
  int unreadProfileNotificationCount = 0;
  _UnreadMentionTarget? _latestUnreadFeedMentionTarget;
  _UnreadMentionTarget? _latestUnreadLeaderboardMentionTarget;

  // Keep heavy tab widgets stable across tab switches to avoid rebuild jank.
  String _tabUserId = '';
  GlobalKey<TodayFeedScreenState> _feedTabKey =
      GlobalKey<TodayFeedScreenState>();
  GlobalKey<LeaderboardScreenState> _leaderboardTabKey =
      GlobalKey<LeaderboardScreenState>();
  FriendsScreen? _friendsTab;
  LeaderboardScreen? _leaderboardTab;
  ProfileScreen? _profileTab;
  final Set<int> _loadedTabIndices = <int>{0};
  RealtimeChannel? _messagesSubscription;
  RealtimeChannel? _challengesSubscription;
  RealtimeChannel? _notificationsSubscription;
  RealtimeChannel? _photosSubscription;
  Timer? _challengeEndTimer;
  Timer? _dailyChallengeBoundaryTimer;
  Timer? _postStatusLoaderTimer;
  Set<String> _friendIds = {};
  bool _contactPromptHandled = false;
  bool _contactPromptRunning = false;
  bool _onboardingPromptHandled = false;
  bool _openingPushChat = false;
  bool _resumeRefreshRunning = false;

  void _handlePostDataChanged() {
    unawaited(_loadUserProfile());
  }

  void _handleMainTabNavigationRequest() {
    final requestedIndex = mainTabNavigationRequestNotifier.value;
    if (requestedIndex == null) return;
    if (mounted && index != requestedIndex) {
      setState(() => index = requestedIndex);
    }
    mainTabNavigationRequestNotifier.value = null;
  }

  void _handlePostFocusRequestChange() {
    final request = postFocusRequestNotifier.value;
    if (request != null && request.tabIndex == 0 && !hasPostedToday) {
      clearPostFocusRequest();
    }
  }

  void _handleChatOpenRequestChange() {
    final request = chatOpenRequestNotifier.value;
    if (request == null || _openingPushChat) return;
    clearChatOpenRequest();
    unawaited(_openChatFromPushRequest(request));
  }

  Future<void> _openChatFromPushRequest(ChatOpenRequest request) async {
    if (!mounted || request.friendId.isEmpty) return;
    _openingPushChat = true;

    try {
      if (index != 1 && mounted) {
        setState(() => index = 1);
      }

      String friendUsername = t('Unbekannt', 'Unknown');
      try {
        final row = await Supabase.instance.client
            .from('users_profile')
            .select('username')
            .eq('id', request.friendId)
            .maybeSingle();
        final username = (row?['username'] ?? '').toString().trim();
        if (username.isNotEmpty) {
          friendUsername = username;
        }
      } catch (_) {
        // Best effort only. Falling back to "Unknown" still lets us open chat.
      }

      if (!mounted) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => friends_ui.ChatScreen(
              friendId: request.friendId,
              friendUsername: friendUsername,
            ),
          ),
        );
      });
    } finally {
      _openingPushChat = false;
    }
  }

  void _openProfileTab() {
    if (index == 3) return;
    HapticFeedback.selectionClick();
    setState(() => index = 3);
  }

  Future<void> _scrollFeedToTopSoon() async {
    final state = _feedTabKey.currentState;
    if (state != null) {
      await state.scrollToTop();
      return;
    }

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nextState = _feedTabKey.currentState;
      if (nextState != null) {
        await nextState.scrollToTop();
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    await completer.future;
  }

  Future<void> _scrollLeaderboardToTopSoon() async {
    final state = _leaderboardTabKey.currentState;
    if (state != null) {
      await state.scrollToTop();
      return;
    }

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nextState = _leaderboardTabKey.currentState;
      if (nextState != null) {
        await nextState.scrollToTop();
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    await completer.future;
  }

  Future<void> _markNotificationAsRead(String notificationId) async {
    if (notificationId.isEmpty) return;
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      await client
          .from('notifications')
          .update({'read': true})
          .eq('id', notificationId)
          .eq('user_id', userId)
          .eq('read', false);
    } catch (e) {
      AppLogger.debug('Error marking notification as read from tab tap: $e');
    } finally {
      await _loadUnreadNotificationCounts();
    }
  }

  Future<void> _openUnreadMentionTarget(_UnreadMentionTarget target) async {
    requestPostFocus(target.request);
    await _markNotificationAsRead(target.notificationId);
  }

  Future<void> _handleHomeTabTap() async {
    final latestMentionTarget = _latestUnreadFeedMentionTarget;
    if (index != 0) {
      HapticFeedback.selectionClick();
      setState(() => index = 0);
      return;
    }

    if (latestMentionTarget != null) {
      await _openUnreadMentionTarget(latestMentionTarget);
      return;
    }

    await _scrollFeedToTopSoon();
  }

  Future<void> _handleLeaderboardTabTap() async {
    final latestMentionTarget = _latestUnreadLeaderboardMentionTarget;
    if (index != 2) {
      HapticFeedback.selectionClick();
      setState(() => index = 2);
      return;
    }

    if (latestMentionTarget != null) {
      await _openUnreadMentionTarget(latestMentionTarget);
      return;
    }

    await _scrollLeaderboardToTopSoon();
  }

  /// An invite link was opened while the app is running.
  void _handleInviteLink() {
    if (!mounted || InviteLinks.pendingUsername.value == null) return;
    unawaited(InviteLinks.processPending(context));
  }

  void _openFriendsTab() {
    if (index == 1) return;
    HapticFeedback.selectionClick();
    setState(() => index = 1);
    _loadUnreadCount();
  }

  void _ensureTabInstances(String userId) {
    if (userId.isEmpty) return;
    if (_friendsTab != null && _leaderboardTab != null && _profileTab != null) {
      if (_tabUserId == userId) {
        return;
      }
    }

    _tabUserId = userId;
    _feedTabKey = GlobalKey<TodayFeedScreenState>();
    _leaderboardTabKey = GlobalKey<LeaderboardScreenState>();
    _friendsTab = FriendsScreen(
      key: ValueKey('friends_$userId'),
      onUnreadCountChanged: _loadUnreadCount,
    );
    _leaderboardTab = LeaderboardScreen(
      key: _leaderboardTabKey,
      onOpenOwnProfile: _openProfileTab,
      onOpenFriendsTab: _openFriendsTab,
    );
    _profileTab = ProfileScreen(key: ValueKey('profile_$userId'));
  }

  Widget _buildDeferredTab({required int tabIndex, required Widget child}) {
    if (index == tabIndex) {
      _loadedTabIndices.add(tabIndex);
    }
    if (_loadedTabIndices.contains(tabIndex)) {
      return child;
    }
    return const SizedBox.shrink();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkIfPostedToday();
    _scheduleDailyChallengeBoundaryRefresh();
    _loadUserProfile();

    _loadUnreadCount();
    _loadUnreadNotificationCounts();
    _loadFriendIds();
    _loadNotificationPreferences();
    _setupRealtimeListener();
    unawaited(markMessagesDelivered());
    _scheduleChallengeEndReminder();
    _resolveDuePvpChallenges();
    mainTabNavigationRequestNotifier.addListener(
      _handleMainTabNavigationRequest,
    );
    postDataRefreshNotifier.addListener(_handlePostDataChanged);
    postFocusRequestNotifier.addListener(_handlePostFocusRequestChange);
    chatOpenRequestNotifier.addListener(_handleChatOpenRequestChange);
    InviteLinks.pendingUsername.addListener(_handleInviteLink);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _handleMainTabNavigationRequest();
      _handleChatOpenRequestChange();
      await _maybeShowOnboardingForNewAccount();
      // After the intro explained that the quest comes by push.
      if (mounted) await requestPushPermission();
      if (mounted) await AnalyticsConsent.maybeAsk(context);
      if (mounted) await InviteLinks.processPending(context);
      await _maybePromptContactsOnFirstLogin();
    });
  }

  /// Shows the 3-page intro exactly once after account creation.
  /// Decision is server-side (`users_profile.onboarding_completed`): new
  /// accounts default to false, existing accounts were backfilled to true —
  /// so a re-login or a new device never re-triggers it.
  Future<void> _maybeShowOnboardingForNewAccount() async {
    if (_onboardingPromptHandled || !mounted) return;
    _onboardingPromptHandled = true;

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    // Only act on a positive "not completed" signal. If the profile row is
    // still being created (signup race) retry once, then skip — the flag
    // stays false, so the next app start catches it.
    bool? completed;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final row = await client
            .from('users_profile')
            .select('onboarding_completed')
            .eq('id', userId)
            .maybeSingle();
        if (row != null) {
          completed = row['onboarding_completed'] == true;
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }
    if (completed != false || !mounted) return;

    final result = await Navigator.of(context).push<OnboardingResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const OnboardingScreen(),
      ),
    );

    // Mark as seen regardless of how the screen was left (skip counts too).
    try {
      await client
          .from('users_profile')
          .update({'onboarding_completed': true})
          .eq('id', userId);
    } catch (e) {
      AppLogger.debug('Onboarding flag update failed (will retry next start): $e');
    }

    if (mounted && result == OnboardingResult.openFriends) {
      setState(() => index = 1);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messagesSubscription?.unsubscribe();
    _challengesSubscription?.unsubscribe();
    _notificationsSubscription?.unsubscribe();
    _photosSubscription?.unsubscribe();
    _cancelChallengeEndReminder();
    _dailyChallengeBoundaryTimer?.cancel();
    _postStatusLoaderTimer?.cancel();
    mainTabNavigationRequestNotifier.removeListener(
      _handleMainTabNavigationRequest,
    );
    postDataRefreshNotifier.removeListener(_handlePostDataChanged);
    postFocusRequestNotifier.removeListener(_handlePostFocusRequestChange);
    chatOpenRequestNotifier.removeListener(_handleChatOpenRequestChange);
    InviteLinks.pendingUsername.removeListener(_handleInviteLink);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refreshForAppResume());
  }

  Future<void> _refreshForAppResume() async {
    if (_resumeRefreshRunning || !mounted) return;
    _resumeRefreshRunning = true;
    try {
      unawaited(markMessagesDelivered());
      if (comboComposeFlowActiveNotifier.value) {
        return;
      }

      await _resolveDuePvpChallenges();
      await _checkIfPostedToday();
      if (!mounted) return;

      _scheduleDailyChallengeBoundaryRefresh();
      _scheduleChallengeEndReminder();

      if (!hasPostedToday) return;

      final feedState = _feedTabKey.currentState;
      if (feedState != null &&
          !comboComposeFlowActiveNotifier.value &&
          !feedState._collabFlowActive &&
          feedState._collabUploadingBaseId == null) {
        unawaited(feedState._refreshFeed());
      }
    } finally {
      _resumeRefreshRunning = false;
    }
  }

  void _schedulePostStatusLoader() {
    _postStatusLoaderTimer?.cancel();
    _postStatusLoaderTimer = Timer(_postStatusLoaderDelay, () {
      if (!mounted || !isCheckingPostStatus) return;
      setState(() => _showPostStatusLoader = true);
    });
  }

  void _stopPostStatusLoader() {
    _postStatusLoaderTimer?.cancel();
    _postStatusLoaderTimer = null;
    _showPostStatusLoader = false;
  }

  void _scheduleDailyChallengeBoundaryRefresh() {
    _dailyChallengeBoundaryTimer?.cancel();
    final nowLocal = DateTime.now();
    final todayStartLocal = challengeStartLocal(nowLocal);
    final nextStartLocal = nowLocal.isBefore(todayStartLocal)
        ? todayStartLocal
        : challengeStartLocal(nowLocal.add(const Duration(days: 1)));
    final delay =
        nextStartLocal.difference(nowLocal) + const Duration(seconds: 1);
    if (delay.isNegative) return;
    _dailyChallengeBoundaryTimer = Timer(delay, () async {
      if (!mounted) return;
      await _resolveDuePvpChallenges();

      // Daily challenge just rolled over.
      // Notify (best-effort) and re-schedule the "ending soon" reminder.
      try {
        final allowStart = await NotificationPrefs.getChallengeStart();
        if (allowStart && mounted) {
          _showInAppNotification(
            t(
              'Neue Daily Quest gestartet!',
              'New Daily Quest started!',
            ),
            showDeviceNotification: false,
          );
        }
      } catch (_) {
        // Best-effort only.
      }

      _checkIfPostedToday();
      _scheduleChallengeEndReminder();
      _scheduleDailyChallengeBoundaryRefresh();
    });
  }

  void _setupRealtimeListener() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    AppLogger.debug('_setupRealtimeListener called, userId: $userId');
    if (userId == null) {
      AppLogger.debug('No user logged in, cannot setup realtime listener');
      return;
    }

    AppLogger.debug('Setting up realtime listeners for user: $userId');

    // Channel für Nachrichten
    _messagesSubscription?.unsubscribe();
    _messagesSubscription = client
        .channel('messages_changes_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (payload) async {
            AppLogger.debug('Message change detected, reloading unread count...');
            unawaited(markMessagesDelivered());
            _loadUnreadCount();
            final allow = await NotificationPrefs.getMessages();
            if (!allow) return;
            if (mounted) {
              _showInAppNotification(
                t('Neue Nachricht erhalten', 'New message received'),
                showDeviceNotification: false,
              );
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (_) {
            _loadUnreadCount();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (_) {
            _loadUnreadCount();
          },
        )
        .subscribe();

    // Channel für Challenges (eingehend und Statusänderungen). Filtered on
    // both participant columns so the server only checks this user's duels.
    Future<void> onChallengeInsert(PostgresChangePayload payload) async {
      _loadUnreadCount();
      final row = payload.newRecord;
      final status = row['status'] as String?;
      final challengedId = row['challenged_id'] as String?;
      final challengerId = row['challenger_id'] as String?;

      if (status == 'pending' && challengedId == userId) {
        // Hole Challenger-Info für die Benachrichtigung
        try {
          final challengerProfile = await client
              .from('users_profile')
              .select('username')
              .eq('id', challengerId ?? '')
              .maybeSingle();
          final challengerName =
              challengerProfile?['username'] ?? 'Jemand';

          final allow = await NotificationPrefs.getChallenged();
          if (allow && mounted) {
            _showInAppNotification(
              t(
                '$challengerName fordert dich zum Duell heraus!',
                '$challengerName challenges you to a duel!',
              ),
              showDeviceNotification: false,
            );
          }
        } catch (e) {
          AppLogger.debug('Error loading challenger info: $e');
          final allow = await NotificationPrefs.getChallenged();
          if (allow && mounted) {
            _showInAppNotification(
              t(
                'Du wurdest zum Duell herausgefordert!',
                'You have been challenged to a duel!',
              ),
              showDeviceNotification: false,
            );
          }
        }
      }

      if (status == 'accepted' &&
          (challengedId == userId || challengerId == userId)) {
        final allowStart = await NotificationPrefs.getChallengeStart();
        if (allowStart && mounted) {
          _showInAppNotification(
            t('Neues Duell gestartet!', 'New duel started!'),
            showDeviceNotification: false,
          );
        }
        _scheduleChallengeEndReminder();
      }
    }

    Future<void> onChallengeUpdate(PostgresChangePayload payload) async {
      _loadUnreadCount();
      final row = payload.newRecord;
      final status = row['status'] as String?;
      final challengedId = row['challenged_id'] as String?;
      final challengerId = row['challenger_id'] as String?;
      final completedAt = row['completed_at'];

      if (status == 'accepted' &&
          (challengedId == userId || challengerId == userId)) {
        final allowStart = await NotificationPrefs.getChallengeStart();
        if (allowStart && mounted) {
          _showInAppNotification(
            t('Neues Duell gestartet!', 'New duel started!'),
            showDeviceNotification: false,
          );
        }
        _scheduleChallengeEndReminder();
      }

      if (completedAt != null &&
          (challengedId == userId || challengerId == userId)) {
        _cancelChallengeEndReminder();
      }
    }

    _challengesSubscription?.unsubscribe();
    var challengesChannel = client.channel('challenges_changes_$userId');
    for (final column in const ['challenged_id', 'challenger_id']) {
      final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: column,
        value: userId,
      );
      challengesChannel = challengesChannel
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'challenges',
            filter: filter,
            callback: onChallengeInsert,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'challenges',
            filter: filter,
            callback: onChallengeUpdate,
          );
    }
    // Realtime can't filter DELETE events; they only carry the id.
    _challengesSubscription = challengesChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'challenges',
          callback: (_) {
            _loadUnreadCount();
          },
        )
        .subscribe();

    _notificationsSubscription?.unsubscribe();
    _notificationsSubscription = client
        .channel('notifications_changes_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) async {
            final row = payload.newRecord;
            final type = (row['type'] ?? '').toString();
            final message = (row['message'] ?? '').toString().trim();

            _loadUnreadNotificationCounts();
            if (message.isEmpty) return;
            if (type == 'mention') {
              if (mounted) {
                _showInAppNotification(message, showDeviceNotification: false);
              }
              return;
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _loadUnreadNotificationCounts();
          },
        )
        .subscribe();

    _subscribeFriendPosts();

    AppLogger.debug('Realtime listeners set up');
  }

  Future<void> _loadUnreadCount() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final nowLocal = DateTime.now();
      DateTime activeStartLocal = challengeStartLocal(nowLocal);
      if (nowLocal.isBefore(activeStartLocal)) {
        activeStartLocal = challengeStartLocal(
          nowLocal.subtract(const Duration(days: 1)),
        );
      }
      // Duel invites expire after 2 hours (enforced by the server).
      final inviteLifetimeCutoff = nowLocal.subtract(const Duration(hours: 2));
      final pendingChallengeCutoffIso =
          (inviteLifetimeCutoff.isAfter(activeStartLocal)
                  ? inviteLifetimeCutoff
                  : activeStartLocal)
              .toUtc()
              .toIso8601String();

      final unread = await client
          .from("messages")
          .select('id')
          .eq("receiver_id", userId)
          .eq("read", false);

      final pendingChallenges = await client
          .from('challenges')
          .select('id')
          .eq('challenged_id', userId)
          .eq('status', 'pending')
          .gte('created_at', pendingChallengeCutoffIso);

      final incomingFriendRequests = await client
          .from('friends')
          .select('id')
          .eq('friend_id', userId)
          .eq('status', 'pending');

      if (mounted) {
        setState(() {
          unreadCount =
              unread.length +
              pendingChallenges.length +
              incomingFriendRequests.length;
        });
      }
    } catch (e) {
      AppLogger.debug("Error loading unread count: $e");
    }
  }

  Future<void> _loadUnreadNotificationCounts() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final unread = List<Map<String, dynamic>>.from(
        await client
            .from('notifications')
            .select('id, type, photo_id, comment_id, created_at')
            .eq('user_id', userId)
            .eq('read', false)
            .order('created_at', ascending: false),
      );

      final photoIds = unread
          .where((row) => row['type'] == 'mention')
          .map((row) => (row['photo_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      final photoMetaById = <String, Map<String, dynamic>>{};
      if (photoIds.isNotEmpty) {
        final photos = await client
            .from('photos')
            .select('id, is_public, is_challenge_photo, is_late')
            .inFilter('id', photoIds);
        for (final row in photos) {
          final photoId = (row['id'] ?? '').toString().trim();
          if (photoId.isEmpty) continue;
          photoMetaById[photoId] = Map<String, dynamic>.from(row);
        }
      }

      var feedCount = 0;
      var leaderboardCount = 0;
      var profileCount = 0;
      _UnreadMentionTarget? latestFeedMentionTarget;
      _UnreadMentionTarget? latestLeaderboardMentionTarget;

      for (final row in unread) {
        final photoId = (row['photo_id'] ?? '').toString().trim();
        final type = (row['type'] ?? '').toString().trim();
        // Only mentions badge the feed tabs (tapping the tab opens them);
        // likes, requests, duels etc. count on the profile tab with the bell.
        if (photoId.isEmpty || type != 'mention') {
          profileCount++;
          continue;
        }

        final photoMeta = photoMetaById[photoId];
        final isPublic = photoMeta?['is_public'] == true;
        if (isPublic) {
          leaderboardCount++;
        } else {
          feedCount++;
        }

        if (type != 'mention') continue;

        final notificationId = (row['id'] ?? '').toString().trim();
        if (notificationId.isEmpty) continue;

        final commentId = (row['comment_id'] ?? '').toString().trim();
        final request = PostFocusRequest(
          tabIndex: isPublic ? 2 : 0,
          photoId: photoId,
          commentId: commentId.isEmpty ? null : commentId,
          todayFeedFilter: isPublic
              ? null
              : ((photoMeta?['is_challenge_photo'] == true &&
                        photoMeta?['is_late'] != true)
                    ? 'pvp'
                    : 'daily'),
        );

        final target = _UnreadMentionTarget(
          notificationId: notificationId,
          request: request,
        );
        if (isPublic) {
          latestLeaderboardMentionTarget ??= target;
        } else {
          latestFeedMentionTarget ??= target;
        }
      }

      if (mounted) {
        setState(() {
          unreadFeedNotificationCount = feedCount;
          unreadLeaderboardNotificationCount = leaderboardCount;
          unreadProfileNotificationCount = profileCount;
          _latestUnreadFeedMentionTarget = latestFeedMentionTarget;
          _latestUnreadLeaderboardMentionTarget =
              latestLeaderboardMentionTarget;
        });
      }
    } catch (e) {
      AppLogger.debug("Error loading unread notifications: $e");
    }
  }

  Future<void> _loadFriendIds() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final friendships = await client
          .from("friends")
          .select("user_id, friend_id, status")
          .or("user_id.eq.$userId,friend_id.eq.$userId")
          .eq("status", "accepted");

      final ids = <String>{userId};
      for (var row in friendships) {
        final isRequester = row['user_id'] == userId;
        ids.add(
          isRequester ? row['friend_id'] as String : row['user_id'] as String,
        );
      }

      if (mounted) {
        setState(() => _friendIds = ids);
        _subscribeFriendPosts();
      }
    } catch (e) {
      AppLogger.debug("Error loading friend ids for notifications: $e");
    }
  }

  /// In-app hint when a friend posts. Filtered to the friends' ids (max 100
  /// per realtime filter) instead of every public photo of every user.
  void _subscribeFriendPosts() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    _photosSubscription?.unsubscribe();
    _photosSubscription = null;
    if (userId == null) return;

    final friendIds = _friendIds
        .where((id) => id != userId)
        .take(100)
        .toList();
    if (friendIds.isEmpty) return;

    _photosSubscription = client
        .channel('photos_changes_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'photos',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.inFilter,
            column: 'user_id',
            value: friendIds,
          ),
          callback: (payload) async {
            final posterId = payload.newRecord['user_id'] as String?;
            if (posterId == null || !_friendIds.contains(posterId)) return;
            final allow = await NotificationPrefs.getFriendsPosts();
            if (allow && mounted) {
              _showInAppNotification(
                t('Dein Freund hat gepostet', 'Your friend just posted'),
                showDeviceNotification: false,
              );
            }
          },
        )
        .subscribe();
  }

  Future<void> _loadNotificationPreferences() async {
    try {
      // Preload preferences so they are available immediately for quick checks.
      await NotificationPrefs.load();
    } catch (e) {
      AppLogger.debug("Error preloading notification preferences: $e");
    }
  }

  void _showInAppNotification(
    String message, {
    bool showDeviceNotification = true,
  }) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(repairMojibake(message), style: _inter)),
      );
    });
    if (showDeviceNotification) {
      NotificationService.instance.showNotification(
        title: 'SideQuest',
        body: message,
      );
    }
  }

  void _cancelChallengeEndReminder() {
    _challengeEndTimer?.cancel();
    _challengeEndTimer = null;
  }

  DateTime? _tryParseDateTime(dynamic raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  bool _isPvpUploadWindowClosed(
    Map<String, dynamic> challenge,
    DateTime nowUtc,
  ) {
    final fallbackExpires = _tryParseDateTime(challenge['expires_at'])?.toUtc();
    final challengerExpires =
        (_tryParseDateTime(challenge['challenger_expires_at']) ??
                fallbackExpires)
            ?.toUtc();
    final challengedExpires =
        (_tryParseDateTime(challenge['challenged_expires_at']) ??
                fallbackExpires)
            ?.toUtc();

    if (challengerExpires == null || challengedExpires == null) {
      // If timer fields are missing, treat as closed to avoid stuck challenges.
      return true;
    }
    return !nowUtc.isBefore(challengerExpires) &&
        !nowUtc.isBefore(challengedExpires);
  }

  Future<Map<String, int>> _loadLikeCountsBefore(
    List<String> photoIds,
    String boundaryUtcIso,
  ) async {
    final counts = <String, int>{for (final id in photoIds) id: 0};
    if (photoIds.isEmpty) return counts;

    final client = Supabase.instance.client;
    List<dynamic> rows = [];

    try {
      rows = await client
          .from('likes')
          .select('photo_id, created_at')
          .inFilter('photo_id', photoIds)
          .lt('created_at', boundaryUtcIso);
    } catch (_) {
      try {
        rows = await client
            .from('likes')
            .select('photo_id')
            .inFilter('photo_id', photoIds);
      } catch (_) {
        return counts;
      }
    }

    for (final row in rows) {
      final photoId = (row['photo_id'] ?? '').toString();
      if (counts.containsKey(photoId)) {
        counts[photoId] = (counts[photoId] ?? 0) + 1;
      }
    }
    return counts;
  }

  Future<void> _resolveDuePvpChallenges() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final nowLocal = DateTime.now();
      final nowUtc = nowLocal.toUtc();
      DateTime activeStartLocal = challengeStartLocal(nowLocal);
      if (nowLocal.isBefore(activeStartLocal)) {
        activeStartLocal = challengeStartLocal(
          nowLocal.subtract(const Duration(days: 1)),
        );
      }
      final boundaryUtcIso = activeStartLocal.toUtc().toIso8601String();

      // Resolve only challenges from the previous challenge day.
      final dueChallenges = await client
          .from("challenges")
          .select(
            "id, challenger_id, challenged_id, created_at, status, completed_at, expires_at, challenger_expires_at, challenged_expires_at",
          )
          .or("challenger_id.eq.$userId,challenged_id.eq.$userId")
          .eq("status", "accepted")
          .isFilter("completed_at", null)
          .lt("created_at", boundaryUtcIso);

      if (dueChallenges.isEmpty) return;

      var resolvedAny = false;

      for (final rawChallenge in dueChallenges) {
        final challenge = Map<String, dynamic>.from(rawChallenge);
        final challengeId = (challenge['id'] ?? '').toString();
        final challengerId = (challenge['challenger_id'] ?? '').toString();
        final challengedId = (challenge['challenged_id'] ?? '').toString();
        if (challengeId.isEmpty ||
            challengerId.isEmpty ||
            challengedId.isEmpty) {
          continue;
        }

        if (!_isPvpUploadWindowClosed(challenge, nowUtc)) {
          continue;
        }

        List<dynamic> photos;
        try {
          photos = await client
              .from('photos')
              .select('id, user_id, created_at')
              .eq('challenge_id', challengeId)
              .inFilter('user_id', [challengerId, challengedId])
              .order('created_at', ascending: false);
        } catch (e) {
          AppLogger.debug('Could not load challenge photos for $challengeId: $e');
          continue;
        }

        Map<String, dynamic>? challengerPhoto;
        Map<String, dynamic>? challengedPhoto;
        for (final row in photos) {
          final photoUserId = (row['user_id'] ?? '').toString();
          if (photoUserId == challengerId && challengerPhoto == null) {
            challengerPhoto = Map<String, dynamic>.from(row);
          } else if (photoUserId == challengedId && challengedPhoto == null) {
            challengedPhoto = Map<String, dynamic>.from(row);
          }
          if (challengerPhoto != null && challengedPhoto != null) break;
        }

        String? winnerId;
        if (challengerPhoto == null && challengedPhoto == null) {
          winnerId = null;
        } else if (challengerPhoto != null && challengedPhoto == null) {
          winnerId = challengerId;
        } else if (challengerPhoto == null && challengedPhoto != null) {
          winnerId = challengedId;
        } else {
          final challengerPhotoId = (challengerPhoto!['id'] ?? '').toString();
          final challengedPhotoId = (challengedPhoto!['id'] ?? '').toString();
          if (challengerPhotoId.isEmpty || challengedPhotoId.isEmpty) continue;

          final likeCounts = await _loadLikeCountsBefore([
            challengerPhotoId,
            challengedPhotoId,
          ], boundaryUtcIso);
          final challengerLikes = likeCounts[challengerPhotoId] ?? 0;
          final challengedLikes = likeCounts[challengedPhotoId] ?? 0;

          if (challengerLikes > challengedLikes) {
            winnerId = challengerId;
          } else if (challengedLikes > challengerLikes) {
            winnerId = challengedId;
          } else {
            winnerId = null; // Tie -> no winner, no joker.
          }
        }

        await client
            .from('challenges')
            .update({
              'completed_at': DateTime.now().toIso8601String(),
              'winner_id': winnerId,
            })
            .eq('id', challengeId)
            .isFilter('completed_at', null);

        // The server picks the winner and awards the joker
        // (guard_challenge_result, award_joker_on_challenge_completion).
        resolvedAny = true;
      }

      if (resolvedAny) {
        notifyPostDataChanged();
      }
    } catch (e) {
      AppLogger.debug("Error resolving due PvP challenges: $e");
    }
  }

  Future<void> _scheduleChallengeEndReminder() async {
    _cancelChallengeEndReminder();

    final allow = await NotificationPrefs.getChallengeEnding();
    if (!allow) return;

    try {
      final nowLocal = DateTime.now();

      // Determine the currently active daily challenge window (London-based).
      DateTime activeStartLocal = challengeStartLocal(nowLocal);
      if (nowLocal.isBefore(activeStartLocal)) {
        activeStartLocal = challengeStartLocal(
          nowLocal.subtract(const Duration(days: 1)),
        );
      }
      final activeEndLocal = challengeEndLocal(activeStartLocal);

      // Notify 10 minutes before the daily challenge ends.
      DateTime triggerAtLocal = activeEndLocal.subtract(
        const Duration(minutes: 10),
      );

      // If we're already past today's trigger, schedule the next one.
      if (!nowLocal.isBefore(triggerAtLocal)) {
        final todayStartLocal = challengeStartLocal(nowLocal);
        final nextStartLocal = nowLocal.isBefore(todayStartLocal)
            ? todayStartLocal
            : challengeStartLocal(nowLocal.add(const Duration(days: 1)));
        final nextEndLocal = challengeEndLocal(nextStartLocal);
        triggerAtLocal = nextEndLocal.subtract(const Duration(minutes: 10));
      }

      final duration = triggerAtLocal.difference(nowLocal);
      if (duration.isNegative) return;

      _challengeEndTimer = Timer(duration, () async {
        final stillAllowed = await NotificationPrefs.getChallengeEnding();
        if (!stillAllowed || !mounted) return;

        var postedToday = hasPostedToday;
        try {
          postedToday = await _hasUploadedPhotoInActiveChallengeDay();
        } catch (_) {
          // Best-effort only; fallback to in-memory state.
        }
        if (postedToday) {
          // No reminder if today's challenge is already posted.
          _scheduleChallengeEndReminder();
          return;
        }

        _showInAppNotification(
          t(
            'Noch 10 Minuten bis zum Ende der Daily Quest!',
            '10 minutes left in today\'s quest!',
          ),
          showDeviceNotification: false,
        );

        // Re-arm for the next day.
        _scheduleChallengeEndReminder();
      });
    } catch (e) {
      AppLogger.debug('Error scheduling daily challenge end reminder: $e');
    }
  }

  Future<void> _checkIfPostedToday() async {
    if (mounted) {
      setState(() {
        isCheckingPostStatus = true;
        _showPostStatusLoader = false;
      });
    } else {
      isCheckingPostStatus = true;
      _showPostStatusLoader = false;
    }
    _schedulePostStatusLoader();

    try {
      final postedToday = await _hasUploadedPhotoInActiveChallengeDay();
      if (mounted) {
        setState(() {
          _stopPostStatusLoader();
          hasPostedToday = postedToday;
          isCheckingPostStatus = false;
        });
      } else {
        _stopPostStatusLoader();
        isCheckingPostStatus = false;
      }
      unawaited(
        ChallengeReminders.reschedule(postedActiveDay: postedToday),
      );
    } catch (e) {
      AppLogger.debug("Error checking post status: $e");
      _stopPostStatusLoader();
      if (mounted) {
        setState(() => isCheckingPostStatus = false);
      } else {
        isCheckingPostStatus = false;
      }
    }
  }

  Future<bool> _hasUploadedPhotoInActiveChallengeDay() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return false;

    final nowLocal = DateTime.now();
    // Use challenge boundaries (London-based) instead of calendar midnight.
    DateTime activeChallengeStartLocal = challengeStartLocal(nowLocal);
    if (nowLocal.isBefore(activeChallengeStartLocal)) {
      activeChallengeStartLocal = challengeStartLocal(
        nowLocal.subtract(const Duration(days: 1)),
      );
    }
    final activeChallengeStartUtc = activeChallengeStartLocal.toUtc();
    final sinceUtc = activeChallengeStartUtc.toIso8601String();

    // Only today's quest post unlocks the feed. Duel photos and collab
    // extensions don't count (same rule as the server's streak trigger),
    // otherwise a duel photo would hide the quest camera for the whole day.
    // server_created_at is UTC; created_at is a client timestamp.
    final photoResult = await client
        .from("photos")
        .select("id")
        .eq("user_id", userId)
        .filter("challenge_id", "is", null)
        .or("is_challenge_photo.is.null,is_challenge_photo.eq.false")
        .eq("is_collab_extension", false)
        .gte("server_created_at", sinceUtc)
        .limit(1);

    final postedQuestToday = photoResult.isNotEmpty;
    AppLogger.debug("Post status check - quest posted today: $postedQuestToday");
    return postedQuestToday;
  }

  Future<void> _loadUserProfile() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      if (!_profileEnsuredOnce) {
        _profileEnsuredOnce = true;
        try {
          await ensureUserProfileExists(client);
        } catch (e) {
          AppLogger.debug('ensureUserProfileExists failed in _loadUserProfile: $e');
        }
      }

      final profile = await client
          .from("users_profile")
          .select("username, profile_picture, joker")
          .eq("id", userId)
          .maybeSingle();

      if (mounted && profile != null) {
        final normalizedProfile = Map<String, dynamic>.from(profile);
        normalizedProfile['joker'] = _readIntValue(normalizedProfile['joker']);
        setState(() => userProfile = normalizedProfile);
      }
    } catch (e) {
      AppLogger.debug("Error loading user profile: $e");
    }
  }

  Future<void> _maybePromptContactsOnFirstLogin() async {
    if (_contactPromptHandled || _contactPromptRunning || !mounted) return;
    _contactPromptHandled = true;

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final alreadySeen = await FriendDiscoveryService.hasSeenContactsOnboarding(
      userId,
    );
    if (alreadySeen || !mounted) return;

    _contactPromptRunning = true;
    try {
      final shouldLink = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: const Color(0xFF1E1E1E),
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('Kontakte verknüpfen?', 'Link contacts?'),
                    style: _inter.copyWith(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      'Damit wir dir persönliche Vorschläge zeigen können, verknüpfe jetzt deine Kontakte.',
                      'To show personalized suggestions, link your contacts now.',
                    ),
                    style: _inter.copyWith(
                      color: Colors.white70,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF3A3A3A)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: Text(
                            t('Später', 'Later'),
                            style: _inter.copyWith(
                              color: Colors.white70,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: appGreen,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: Text(
                            t('Jetzt verknüpfen', 'Link now'),
                            style: _inter.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );

      await FriendDiscoveryService.markContactsOnboardingSeen(userId);

      if (shouldLink != true || !mounted) return;

      final result = await FriendDiscoveryService.linkContactsForCurrentUser();
      if (!mounted) return;

      final message = switch (result.status) {
        ContactLinkStatus.linked when result.contactsProcessed > 0 => t(
          '${result.contactsProcessed} Kontakte verknüpft. Vorschläge sind jetzt persönlicher.',
          '${result.contactsProcessed} contacts linked. Suggestions are now personalized.',
        ),
        ContactLinkStatus.linked => t(
          'Keine Kontakte gefunden.',
          'No contacts found.',
        ),
        ContactLinkStatus.permissionDenied => t(
          'Kontaktzugriff nicht erlaubt. Du kannst das später in den Einstellungen aktivieren.',
          'Contacts permission denied. You can enable it later in settings.',
        ),
        ContactLinkStatus.unavailable => t(
          'Kontakte sind auf diesem Gerät nicht verfügbar.',
          'Contacts are not available on this device.',
        ),
        ContactLinkStatus.failed => t(
          'Kontakte konnten nicht verknüpft werden.',
          'Could not link contacts.',
        ),
      };

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      _contactPromptRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
    const profileIndex = 3;
    final screenSize = MediaQuery.sizeOf(context);
    final isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final compactNavLayout = _usesCompactBottomNav(screenSize);
    final narrowNavLayout = _usesNarrowBottomNav(screenSize);
    final navBottom = _bottomNavBottomOffsetForSize(
      screenSize,
      isKeyboardOpen: isKeyboardOpen,
    );
    final navHeight = _bottomNavHeightForSize(screenSize);
    final navOuterInset = _bottomNavOuterInsetForSize(screenSize);
    final navInnerPadding = _bottomNavInnerPaddingForSize(screenSize);
    final navAvatarSize = narrowNavLayout
        ? 32.0
        : compactNavLayout
        ? 34.0
        : 36.0;
    final navAvatarRadius = (navAvatarSize - 4) / 2;
    final navAvatarBorderWidth = narrowNavLayout ? 2.0 : 2.5;
    final navAvatarTextSize = narrowNavLayout ? 12.0 : 14.0;
    final navProfileBadgeMinSize = narrowNavLayout ? 14.0 : 16.0;
    final navProfileBadgeFontSize = narrowNavLayout ? 8.0 : 9.0;

    _ensureTabInstances(userId);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          systemNavigationBarColor: Color(0xFF121212),
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
        child: Stack(
          children: [
            IndexedStack(
              index: index,
              children: [
                isCheckingPostStatus
                    ? ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: _showPostStatusLoader ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            child: SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.3,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF1A1A1A),
                                ),
                                backgroundColor: Colors.black12,
                              ),
                            ),
                          ),
                        ),
                      )
                    : (hasPostedToday
                          ? TodayFeedScreen(
                              key: _feedTabKey,
                              onOpenOwnProfile: _openProfileTab,
                              onOpenFriendsTab: _openFriendsTab,
                            )
                          : CameraScreen(
                              key: ValueKey('camera_$userId'),
                              profileJokerCount: _readNullableIntValue(
                                userProfile?['joker'],
                              ),
                              onChallengeStatusChanged: _checkIfPostedToday,
                              onCancel: () => setState(() => index = 1),
                            )),
                _buildDeferredTab(
                  tabIndex: 1,
                  child: _friendsTab ?? const SizedBox.shrink(),
                ),
                _buildDeferredTab(
                  tabIndex: 2,
                  child: _leaderboardTab ?? const SizedBox.shrink(),
                ),
                _buildDeferredTab(
                  tabIndex: 3,
                  child: _profileTab ?? const SizedBox.shrink(),
                ),
              ],
            ),
            Positioned(
              left: navOuterInset,
              right: navOuterInset,
              bottom: navBottom,
              child: Opacity(
                opacity: isKeyboardOpen ? 0.96 : 1,
                child: Container(
                  height: navHeight,
                  padding: EdgeInsets.symmetric(horizontal: navInnerPadding),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1C),
                    borderRadius: BorderRadius.circular(
                      narrowNavLayout
                          ? 20
                          : compactNavLayout
                          ? 22
                          : 25,
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _NavBarItem(
                        icon: hasPostedToday
                            ? Icons.home_rounded
                            : Icons.camera_alt_rounded,
                        isSelected: index == 0,
                        onTap: () {
                          unawaited(_handleHomeTabTap());
                        },
                        badgeCount: unreadFeedNotificationCount,
                        isDark: true,
                      ),
                      _NavBarItem(
                        icon: Icons.people_rounded,
                        isSelected: index == 1,
                        onTap: () {
                          if (index != 1) {
                            HapticFeedback.selectionClick();
                            setState(() => index = 1);
                          }
                          _loadUnreadCount();
                        },
                        badgeCount: unreadCount,
                        isDark: true,
                      ),
                      _NavBarItem(
                        icon: Icons.public,
                        isSelected: index == 2,
                        onTap: () {
                          unawaited(_handleLeaderboardTabTap());
                        },
                        badgeCount: unreadLeaderboardNotificationCount,
                        isDark: true,
                      ),
                      GestureDetector(
                        onTap: () {
                          if (index == profileIndex) return;
                          HapticFeedback.selectionClick();
                          setState(() => index = profileIndex);
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: navAvatarSize,
                              height: navAvatarSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: index == profileIndex
                                      ? appGreen
                                      : Colors.transparent,
                                  width: navAvatarBorderWidth,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: navAvatarRadius,
                                backgroundColor: Colors.black,
                                backgroundImage:
                                    userProfile?['profile_picture'] != null
                                    ? sideQuestCachedImageProvider(
                                        userProfile!['profile_picture'],
                                        cacheWidth: sideQuestCacheWidth(
                                          context,
                                          32,
                                        ),
                                        cacheHeight: sideQuestCacheWidth(
                                          context,
                                          32,
                                        ),
                                      )
                                    : null,
                                child: userProfile?['profile_picture'] == null
                                    ? Text(
                                        (userProfile?['username'] ?? 'U')[0]
                                            .toUpperCase(),
                                        style: _inter.copyWith(
                                          color: Colors.white,
                                          fontSize: navAvatarTextSize,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                            if (unreadProfileNotificationCount > 0)
                              Positioned(
                                right: -3,
                                top: -3,
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: narrowNavLayout ? 3.5 : 4,
                                    vertical: narrowNavLayout ? 1.5 : 2,
                                  ),
                                  constraints: BoxConstraints(
                                    minWidth: navProfileBadgeMinSize,
                                    minHeight: navProfileBadgeMinSize,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0xFF1C1C1C),
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      unreadProfileNotificationCount > 9
                                          ? '9+'
                                          : unreadProfileNotificationCount
                                                .toString(),
                                      style: _inter.copyWith(
                                        color: Colors.white,
                                        fontSize: navProfileBadgeFontSize,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Custom NavBar Item Widget
class _NavBarItem extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final int? badgeCount;
  final bool isDark;

  const _NavBarItem({
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.badgeCount,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final compactNavLayout = _usesCompactBottomNav(screenSize);
    final narrowNavLayout = _usesNarrowBottomNav(screenSize);
    final iconSize = narrowNavLayout
        ? 24.0
        : compactNavLayout
        ? 27.0
        : 30.0;
    final itemPadding = EdgeInsets.symmetric(
      horizontal: narrowNavLayout
          ? 8.0
          : compactNavLayout
          ? 10.0
          : 12.0,
      vertical: narrowNavLayout ? 8.0 : 10.0,
    );
    final badgeMinSize = narrowNavLayout ? 16.0 : 18.0;
    final badgeFontSize = narrowNavLayout ? 9.0 : 10.0;
    final borderRadius = narrowNavLayout ? 14.0 : 16.0;

    // Wenn isDark true ist (schwarze Bar), nutzen wir Weiß/Grün statt Grau/Grün
    final color = isSelected
        ? appGreen
        : (isDark ? Colors.white54 : Colors.grey.shade600);
    final bg = isSelected
        ? appGreen.withValues(alpha: 0.2)
        : Colors.transparent;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: kDurationFast,
            curve: kCurveStandard,
            padding: itemPadding,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(borderRadius),
            ),
            child: AnimatedScale(
              scale: isSelected ? 1.0 : 0.92,
              duration: kDurationFast,
              curve: kCurveStandard,
              child: Icon(icon, color: color, size: iconSize),
            ),
          ),
          if (badgeCount != null && badgeCount! > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: EdgeInsets.all(narrowNavLayout ? 3.5 : 4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                constraints: BoxConstraints(
                  minWidth: badgeMinSize,
                  minHeight: badgeMinSize,
                ),
                child: Center(
                  child: Text(
                    badgeCount! > 99 ? '99+' : badgeCount.toString(),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: badgeFontSize,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final int? profileJokerCount;
  final Future<void> Function() onChallengeStatusChanged;
  final VoidCallback onCancel;
  const CameraScreen({
    super.key,
    this.profileJokerCount,
    required this.onChallengeStatusChanged,
    required this.onCancel,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  bool uploading = false;
  String challengeTitle = "";
  String challengeDescription = "";
  String challengeStartLocalText = "";
  final LivePhotoRepository _livePhotoRepository = LivePhotoRepository();
  final ValueNotifier<String> _timeRemaining = ValueNotifier<String>(
    "00:00:00",
  );
  DateTime? _challengeStartLocal;
  DateTime? _challengeEndLocal;
  bool _challengeEnded = false;
  int jokerCount = 0;
  bool _jokerUsedForActiveChallenge = false;
  Timer? _timer;
  Timer? _challengeBoundaryTimer;

  void _setUploading(bool value) {
    if (!mounted) return;
    setState(() => uploading = value);
  }

  bool _isJokerUsedForActiveChallenge(Map<String, dynamic>? profile) {
    if (profile == null || profile['joker_used_today'] != true) return false;

    final lastPostedDate = (profile['last_posted_date'] ?? '')
        .toString()
        .trim();
    if (lastPostedDate.isEmpty) return false;

    final activeDayStr = activeLondonChallengeDayStrFromUtc(
      DateTime.now().toUtc(),
    );
    return lastPostedDate == activeDayStr;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    languageController.addListener(_onLanguageChanged);
    postDataRefreshNotifier.addListener(_onPostDataChanged);
    jokerCount = widget.profileJokerCount ?? 0;
    _loadTodayChallenge();
    _updateTimer();
    _loadJokerState();
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(_recoverLostCameraPhoto());
    }
  }

  /// Android can kill the app while the system camera is open; the photo is
  /// then delivered on the next start and would be lost without this.
  Future<void> _recoverLostCameraPhoto() async {
    try {
      final response = await ImagePicker().retrieveLostData();
      final file = response.file;
      if (response.isEmpty || file == null) return;
      await _showCapturedPhotoPreview(file);
    } catch (e) {
      AppLogger.warn('Recovering lost camera photo failed: $e');
    }
  }

  @override
  void didUpdateWidget(covariant CameraScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextJokerCount = widget.profileJokerCount;
    if (nextJokerCount != oldWidget.profileJokerCount) {
      if (nextJokerCount != null) {
        setState(() => jokerCount = nextJokerCount);
      }
      unawaited(_loadJokerState());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    languageController.removeListener(_onLanguageChanged);
    postDataRefreshNotifier.removeListener(_onPostDataChanged);
    _timer?.cancel();
    _challengeBoundaryTimer?.cancel();
    _timeRemaining.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _loadTodayChallenge();
    _updateTimer();
    unawaited(_loadJokerState());
  }

  void _onLanguageChanged() {
    if (!mounted) return;
    _loadTodayChallenge();
  }

  void _onPostDataChanged() {
    if (!mounted) return;
    unawaited(_loadJokerState());
  }

  void _scheduleChallengeRefreshAtNextStart() {
    _challengeBoundaryTimer?.cancel();
    final nowLocal = DateTime.now();
    final todayStartLocal = challengeStartLocal(nowLocal);
    final nextStartLocal = nowLocal.isBefore(todayStartLocal)
        ? todayStartLocal
        : challengeStartLocal(nowLocal.add(const Duration(days: 1)));
    final delay =
        nextStartLocal.difference(nowLocal) + const Duration(seconds: 1);
    if (delay.isNegative) return;
    _challengeBoundaryTimer = Timer(delay, () {
      if (!mounted) return;
      _loadTodayChallenge();
    });
  }

  void _updateTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      final nowLocal = DateTime.now();
      final start = _challengeStartLocal;
      final end = _challengeEndLocal;
      Duration difference;

      final hasStarted = start != null && !nowLocal.isBefore(start);
      final target = hasStarted ? end : start;
      if (target == null) {
        difference = Duration.zero;
      } else {
        difference = target.difference(nowLocal);
        if (difference.isNegative) difference = Duration.zero;
      }

      final displayedSeconds = difference.inSeconds;
      final newEnded = end != null && hasStarted && displayedSeconds <= 0;
      if (newEnded != _challengeEnded) {
        setState(() => _challengeEnded = newEnded);
      }

      final newValue =
          "${difference.inHours.toString().padLeft(2, '0')}:"
          "${(difference.inMinutes % 60).toString().padLeft(2, '0')}:"
          "${(displayedSeconds % 60).toString().padLeft(2, '0')}";
      if (_timeRemaining.value != newValue) {
        _timeRemaining.value = newValue;
      }
    });
  }

  void _loadTodayChallenge() {
    final nowLocal = DateTime.now();
    // Match feed/leaderboard: the "active" daily challenge is the last one that started.
    // If we're before today's start, this will be yesterday's start.
    DateTime activeStartLocal = challengeStartLocal(nowLocal);
    if (nowLocal.isBefore(activeStartLocal)) {
      activeStartLocal = challengeStartLocal(
        nowLocal.subtract(const Duration(days: 1)),
      );
    }

    _challengeStartLocal = activeStartLocal;
    _challengeEndLocal = challengeEndLocal(activeStartLocal);

    if (!mounted) return;
    // Instant render from the local rotation, then upgrade to the
    // server-managed quest (community quests, hotfixes) once it arrives.
    _applyQuestTexts(DailyQuestService.currentForActiveDay(), activeStartLocal);
    unawaited(
      DailyQuestService.ensureLoadedForActiveDay().then((_) {
        if (!mounted) return;
        final start = _challengeStartLocal;
        if (start == null) return;
        _applyQuestTexts(DailyQuestService.currentForActiveDay(), start);
      }),
    );

    _scheduleChallengeRefreshAtNextStart();
  }

  void _applyQuestTexts(DailyQuest quest, DateTime activeStartLocal) {
    // "09:52–14:52 · 5 Std. Zeit" (was "Gepostet um 09:52", which read like
    // the user's own post time).
    final postedAt = questWindowLabel(
      activeStartLocal,
      challengeEndLocal(activeStartLocal),
    );
    final author = quest.authorUsername;

    setState(() {
      challengeTitle = t(quest.titleDe, quest.titleEn);
      challengeDescription = t(quest.descDe, quest.descEn);
      challengeStartLocalText = author == null
          ? postedAt
          : '$postedAt · ${t('💡 Quest von @$author', '💡 Quest by @$author')}';
    });
  }

  Future<void> _loadJokerState() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final profile = await client
          .from("users_profile")
          .select("joker, joker_used_today, last_posted_date")
          .eq("id", userId)
          .maybeSingle();

      if (mounted && profile != null) {
        setState(() {
          jokerCount = _readIntValue(profile['joker']);
          _jokerUsedForActiveChallenge = _isJokerUsedForActiveChallenge(
            profile,
          );
        });
      }
    } catch (e) {
      AppLogger.debug("Error loading joker state: $e");
    }
  }

  Future<void> _launchGrowthStoreUrl() async {
    final url = Theme.of(context).platform == TargetPlatform.iOS
        ? AppEnvironment.appleAppStoreUrl
        : AppEnvironment.googlePlayStoreUrl;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        url.contains('0000000000') ||
        url.contains('com.example.nummwe3')) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _maybeShowPostGrowthPrompt({
    required bool isPublic,
    required int streakCount,
  }) async {
    if (!mounted) return;

    final shouldRate = await GrowthPromptsPrefs.shouldShowRatingPrompt(
      streakCount: streakCount,
    );
    final shouldShare = await GrowthPromptsPrefs.shouldShowSharePrompt(
      isPublicPost: isPublic,
    );

    if (!shouldRate && !shouldShare) return;
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF121417),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final accent = Theme.of(sheetContext).colorScheme.primary;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shouldRate
                      ? t('Starker Lauf', 'Strong run')
                      : t('Hol Freunde rein', 'Bring friends in'),
                  style: _inter.copyWith(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  shouldRate
                      ? t(
                          'Du hast gerade eine laufende Streak. Ein schnelles Rating hilft uns enorm beim Store-Start.',
                          'You are building a real streak. A quick rating helps a lot with launch momentum.',
                        )
                      : t(
                          'Mit Freunden macht SideQuest doppelt Spaß. Schick deinen Link – wer ihn antippt, schickt dir direkt eine Freundschaftsanfrage.',
                          'SideQuest is twice the fun with friends. Send your link – whoever taps it sends you a friend request right away.',
                        ),
                  style: _inter.copyWith(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      if (shouldRate) {
                        await GrowthPromptsPrefs.markRatingPromptSeen();
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        await _launchGrowthStoreUrl();
                      } else {
                        await GrowthPromptsPrefs.markSharePromptSeen();
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        if (!mounted) return;
                        await shareSideQuestInvite(
                          surface: 'growth_prompt',
                          context: context,
                        );
                      }
                    },
                    icon: Icon(
                      shouldRate
                          ? Icons.star_rate_rounded
                          : Icons.share_rounded,
                    ),
                    label: Text(
                      shouldRate
                          ? t('Jetzt bewerten', 'Rate now')
                          : t('Meinen Link teilen', 'Share my link'),
                      style: _inter.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (shouldRate && shouldShare)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () async {
                        await GrowthPromptsPrefs.markSharePromptSeen();
                        await GrowthPromptsPrefs.markRatingPromptSeen();
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        if (!mounted) return;
                        await shareSideQuestInvite(
                          surface: 'growth_prompt',
                          context: context,
                        );
                      },
                      icon: const Icon(Icons.group_add_rounded),
                      label: Text(
                        t('Lieber Freunde einladen', 'Invite friends instead'),
                        style: _inter.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                Center(
                  child: TextButton(
                    onPressed: () async {
                      if (shouldRate) {
                        await GrowthPromptsPrefs.markRatingPromptSeen();
                      } else {
                        await GrowthPromptsPrefs.markSharePromptSeen();
                      }
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                    child: Text(
                      t('Später', 'Later'),
                      style: _inter.copyWith(color: Colors.white70),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> takePhoto() async {
    if (sideQuestLivePhotoCaptureEnabled) {
      await takeLivePhoto();
      return;
    }

    final start = _challengeStartLocal;
    if (start != null && DateTime.now().isBefore(start)) {
      final hh = start.hour.toString().padLeft(2, '0');
      final mm = start.minute.toString().padLeft(2, '0');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Die Quest startet um $hh:$mm',
                'Quest starts at $hh:$mm',
              ),
            ),
          ),
        );
      }
      return;
    }
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.camera);
    } on PlatformException catch (e) {
      if (mounted) {
        final msg = isImagePickerAccessDenied(e)
            ? imagePickerAccessDeniedMessage(cameraOnly: true)
            : t(
                'Kamera konnte nicht geöffnet werden (${e.code}).',
                'Could not open camera (${e.code}).',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return;
    }

    final pickedFile = picked;
    if (pickedFile == null) return;
    await _showCapturedPhotoPreview(pickedFile);
  }

  Future<void> _showCapturedPhotoPreview(XFile pickedFile) async {
    // Use the global root navigator: the local State can be disposed while
    // the camera Activity is up (lifecycle + realtime listener rebuilds),
    // making `this.context`/`mounted` unreliable for showing the preview.
    await WidgetsBinding.instance.endOfFrame;
    final rootCtx = sideQuestRootNavigatorKey.currentContext;
    if (rootCtx == null) return;
    // Intentional: rootCtx comes from a GlobalKey, not a local State, so it
    // is safe to use after async gaps even if `this` is unmounted.
    await showDialog<void>(
      // ignore: use_build_context_synchronously
      context: rootCtx,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) => CameraOverlay(
        imageFile: pickedFile,
        onConfirm: (isPublic, postDescription) =>
            _uploadPhoto(pickedFile, isPublic, postDescription),
        onCancel: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  Future<void> takeLivePhoto() async {
    if (!sideQuestLivePhotoCaptureEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Live Photo ist in diesem Build deaktiviert.',
                'Live photo is disabled in this build.',
              ),
            ),
          ),
        );
      }
      return;
    }

    final start = _challengeStartLocal;
    if (start != null && DateTime.now().isBefore(start)) {
      final hh = start.hour.toString().padLeft(2, '0');
      final mm = start.minute.toString().padLeft(2, '0');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Die Quest startet um $hh:$mm',
                'Quest starts at $hh:$mm',
              ),
            ),
          ),
        );
      }
      return;
    }

    final capture = await Navigator.of(context).push<LivePhotoCaptureResult>(
      MaterialPageRoute(
        builder: (_) =>
            LivePhotoCaptureScreen(repository: _livePhotoRepository),
      ),
    );
    if (capture == null) {
      // Capture cancelled / no result — only surface the snackbar if the
      // State is still alive; otherwise just bail silently.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Kamera-Aufnahme abgebrochen. Tippe nochmal auf den Auslöser.',
                'Capture cancelled. Tap the camera button again.',
              ),
            ),
          ),
        );
      }
      return;
    }

    // The CameraScreen State is sometimes disposed between Navigator.push and
    // pop on Android (camera lifecycle + realtime listeners can rebuild the
    // tab tree). Use the root navigator key — it survives any local State
    // disposal — to show the preview dialog regardless.
    await WidgetsBinding.instance.endOfFrame;
    final rootCtx = sideQuestRootNavigatorKey.currentContext;
    if (rootCtx == null) {
      unawaited(_cleanupLivePhotoCapture(capture));
      return;
    }
    await showDialog<void>(
      // ignore: use_build_context_synchronously
      context: rootCtx,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) => CameraOverlay(
        imageFile: XFile(capture.photoPath),
        livePhotoCapture: capture,
        onConfirm: (isPublic, postDescription) =>
            _uploadLivePhoto(capture, isPublic, postDescription),
        onCancel: () {
          Navigator.of(dialogContext).pop();
          unawaited(_cleanupLivePhotoCapture(capture));
        },
      ),
    );
  }

  Future<void> _uploadPhoto(
    XFile file,
    bool isPublic,
    String? postDescription, {
    bool deleteLocalFileOnSuccess = false,
  }) async {
    if (!mounted) return;

    // Validate image before upload (size + MIME type)
    final validation = await validateImageFile(file.path);
    if (!validation.isValid) {
      if (mounted) {
        final msg = validation.error == ImageValidationError.tooLarge
            ? t(
                'Bild ist zu groß (max. 25 MB)',
                'Image is too large (max 25 MB)',
              )
            : t(
                'Ungültiges Bildformat (nur JPEG/PNG)',
                'Invalid image format (JPEG/PNG only)',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Bitte erneut anmelden.', 'Please sign in again.')),
          ),
        );
      }
      return;
    }
    _setUploading(true);
    final normalizedPostDescription = (postDescription ?? '').trim();
    var resultingStreakCount = 0;

    final fileName = "${DateTime.now().millisecondsSinceEpoch}.jpg";
    final nowLocal = DateTime.now();
    DateTime activeStartLocal = challengeStartLocal(nowLocal);
    if (nowLocal.isBefore(activeStartLocal)) {
      activeStartLocal = challengeStartLocal(
        nowLocal.subtract(const Duration(days: 1)),
      );
    }
    final activeEndLocal = challengeEndLocal(activeStartLocal);
    final effectiveIsLate = nowLocal.isAfter(activeEndLocal);
    // The server decides lateness on insert (guard_photo_timing).
    var postedLate = effectiveIsLate;
    String? insertedPhotoId;
    var storageUploaded = false;

    try {
      // UPLOAD IMAGE TO STORAGE BUCKET (compressed to ~1080px JPEG q80
      // before upload — saves up to 90% Supabase egress).
      final compressedFeedFile = await compressPhotoForUpload(file.path);
      await client.storage
          .from("photos")
          .upload("$userId/$fileName", compressedFeedFile);
      storageUploaded = true;
      final thumbUrl = await uploadPostThumbnail(
        client: client,
        sourcePath: compressedFeedFile.path,
        fullStoragePath: "$userId/$fileName",
      );

      // GET PUBLIC URL
      final publicUrl = client.storage
          .from("photos")
          .getPublicUrl("$userId/$fileName");
      final createdAtIso = DateTime.now().toUtc().toIso8601String();

      // INSERT INTO DATABASE
      final basePayload = <String, dynamic>{
        "user_id": userId,
        "url": publicUrl,
        "thumb_url": ?thumbUrl,
        "created_at": createdAtIso,
        "is_public": isPublic,
        // Daily Quest upload: never tag as PvP challenge photo.
        "is_challenge_photo": false,
        "challenge_id": null,
        "is_late": effectiveIsLate,
        if (normalizedPostDescription.isNotEmpty)
          "post_description": normalizedPostDescription,
      };
      var descriptionPersisted = normalizedPostDescription.isEmpty;
      final insertAttempts =
          <({Map<String, dynamic> payload, bool descriptionPersisted})>[];

      void addInsertAttempt(
        Map<String, dynamic> payload, {
        required bool descriptionWasIncluded,
      }) {
        insertAttempts.add((
          payload: Map<String, dynamic>.from(payload),
          descriptionPersisted:
              normalizedPostDescription.isEmpty || descriptionWasIncluded,
        ));
      }

      addInsertAttempt(
        basePayload,
        descriptionWasIncluded: basePayload.containsKey('post_description'),
      );
      if (normalizedPostDescription.isNotEmpty) {
        final withoutDescription = Map<String, dynamic>.from(basePayload)
          ..remove('post_description');
        addInsertAttempt(withoutDescription, descriptionWasIncluded: false);
      }
      addInsertAttempt({
        "user_id": userId,
        "url": publicUrl,
        "created_at": createdAtIso,
        "is_public": isPublic,
        "is_late": effectiveIsLate,
      }, descriptionWasIncluded: false);
      addInsertAttempt({
        "user_id": userId,
        "url": publicUrl,
        "created_at": createdAtIso,
        "is_public": isPublic,
      }, descriptionWasIncluded: false);

      Object? insertError;
      for (final attempt in insertAttempts) {
        try {
          final insertedRow = await client
              .from("photos")
              .insert(attempt.payload)
              .select('id, is_late')
              .single();
          insertedPhotoId = insertedRow['id']?.toString();
          postedLate = insertedRow['is_late'] == true;
          descriptionPersisted = attempt.descriptionPersisted;
          break;
        } catch (error) {
          insertError = error;
        }
      }

      if (insertedPhotoId == null) {
        throw insertError ?? StateError('Could not insert photo row');
      }

      // The post exists now: later steps must not fail the upload (a retry
      // would post twice).
      try {
        if (descriptionPersisted && normalizedPostDescription.isNotEmpty) {
          await MentionService.createMentionNotifications(
            text: normalizedPostDescription,
            entityKind: MentionEntityKind.description,
            photoId: insertedPhotoId,
          );
        }
        await AnalyticsService.logPostCreated(
          isPublic: isPublic,
          isLate: postedLate,
        );
        await AnalyticsService.logChallengeCompleted(isLate: postedLate);
      } catch (e) {
        AppLogger.debug('Post-upload follow-ups failed: $e');
      }

      // The server counts the streak on insert; late posts don't count.
      if (!postedLate) {
        resultingStreakCount = await readStreakAfterQuestPost(client, userId);
      }

      notifyPostDataChanged();

      // SUCCESS FEEDBACK
      if (mounted) {
        final snack = !descriptionPersisted
            ? t(
                'Foto gepostet, aber die Beschreibung konnte nicht gespeichert werden.',
                'Photo posted, but the description could not be saved.',
              )
            : postedLate
            ? t(
                'Zu spät! Post als "Late" markiert - keine Streak.',
                'Too late! Post marked as "Late" - no streak.',
              )
            : t('Foto erfolgreich gepostet!', 'Photo posted!');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(snack)));

        await _maybeShowPostGrowthPrompt(
          isPublic: isPublic,
          streakCount: resultingStreakCount,
        );

        // Kleine Verzögerung damit DB aktualisiert ist
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        // Markiere als gepostet - Tab verwandelt sich automatisch in Feed
        await widget.onChallengeStatusChanged();

        if (deleteLocalFileOnSuccess) {
          try {
            final uploadedFile = File(file.path);
            if (await uploadedFile.exists()) {
              await uploadedFile.delete();
            }
          } catch (_) {
            // Best effort cleanup for app-generated temp files.
          }
        }
      }
    } catch (e) {
      AppLogger.debug("UPLOAD ERROR: $e");
      // No post was created: don't leave the photo behind in storage.
      if (storageUploaded && insertedPhotoId == null) {
        try {
          await client.storage.from("photos").remove([
            "$userId/$fileName",
            thumbnailPathFor("$userId/$fileName"),
          ]);
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
    }

    _setUploading(false);
  }

  Future<void> _uploadLivePhoto(
    LivePhotoCaptureResult capture,
    bool isPublic,
    String? postDescription,
  ) async {
    if (!mounted) return;

    if (capture.isStillOnlyFallback || !capture.hasPlayableClip) {
      if (capture.fallbackReason != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Live-Clip konnte nicht erstellt werden. Das Bild wird als normales Foto gepostet.',
                'Live clip could not be created. The still will be posted as a normal photo.',
              ),
            ),
          ),
        );
      }
      await _uploadPhoto(
        XFile(capture.photoPath),
        isPublic,
        postDescription,
        deleteLocalFileOnSuccess: true,
      );
      await _cleanupLivePhotoCapture(capture);
      return;
    }

    _setUploading(true);
    try {
      final result = await _livePhotoRepository.uploadCapture(
        LivePhotoPostUploadRequest(
          captureResult: capture,
          isPublic: isPublic,
          postDescription: postDescription,
          deleteLocalFilesOnSuccess: true,
        ),
      );

      if (mounted) {
        final snack = !result.descriptionPersisted
            ? t(
                'Live Photo gepostet, aber die Beschreibung konnte nicht gespeichert werden.',
                'Live photo posted, but the description could not be saved.',
              )
            : result.isLate
            ? t(
                'Zu spät! Live Photo als "Late" markiert - keine Streak.',
                'Too late! Live photo marked as "Late" - no streak.',
              )
            : t('Live Photo erfolgreich gepostet!', 'Live photo posted!');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(snack)));

        await _maybeShowPostGrowthPrompt(
          isPublic: isPublic,
          streakCount: result.streakCount,
        );

        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        await widget.onChallengeStatusChanged();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMapper.describe(error))),
        );
      }
      await _cleanupLivePhotoCapture(capture);
    }

    _setUploading(false);
  }

  Future<void> _cleanupLivePhotoCapture(LivePhotoCaptureResult capture) async {
    for (final path in <String>[capture.photoPath, capture.clipPath]) {
      if (path.trim().isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best effort cleanup for canceled or failed live-photo drafts.
      }
    }
  }

  Future<void> skipWithJoker({bool openCameraAfterSave = true}) async {
    if (!mounted) return;
    _setUploading(true);
    var shouldOpenCamera = false;

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      final profile = await client
          .from("users_profile")
          .select("joker, joker_used_today, last_posted_date")
          .eq("id", userId)
          .maybeSingle();

      final currentJokerCount = _readIntValue(profile?['joker']);
      if (_isJokerUsedForActiveChallenge(profile)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Joker heute schon benutzt. Deine Streak ist sicher, aber du kannst trotzdem noch posten.",
                  "Joker already used today. Your streak is safe, but you can still post.",
                ),
              ),
            ),
          );
        }
        await _loadJokerState();
        shouldOpenCamera = openCameraAfterSave;
      } else if (currentJokerCount < 1) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Du hast keine Joker! Gewinne Duelle um Joker zu verdienen.",
                  "No jokers left! Win duels to earn more.",
                ),
              ),
            ),
          );
        }
      } else {
        // Joker abziehen und Flag setzen
        final newJokerCount = currentJokerCount - 1;

        // Hole auch den aktuellen Flames-Stand
        final currentProfile = await client
            .from("users_profile")
            .select("flames, last_posted_date")
            .eq("id", userId)
            .maybeSingle();

        int newFlames = 1;
        final lastPostedDate = currentProfile?['last_posted_date'];

        if (lastPostedDate != null) {
          final nowUtc = DateTime.now().toUtc();
          final activeDay = activeLondonChallengeDayFromUtc(nowUtc);
          final activeDayStr = londonDateStrFromLondonDay(activeDay);
          final prevDayStr = londonDateStrFromLondonDay(
            activeDay.subtract(const Duration(days: 1)),
          );

          // Compatibility fallback for older stored values.
          final nowLocal = DateTime.now();
          final localTodayStr = nowLocal.toIso8601String().split('T')[0];
          final localYesterdayStr = nowLocal
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .split('T')[0];

          final lastStr = lastPostedDate as String;
          final isSameDay = lastStr == activeDayStr || lastStr == localTodayStr;
          final isPrevDay =
              lastStr == prevDayStr || lastStr == localYesterdayStr;

          if (isSameDay) {
            newFlames = currentProfile?['flames'] ?? 1;
            AppLogger.debug("Heute bereits gepostet. Flames bleiben: $newFlames");
          } else if (isPrevDay) {
            newFlames = (currentProfile?['flames'] ?? 0) + 1;
            AppLogger.debug("Streak fortgesetzt mit Joker! Flames: $newFlames");
          } else {
            newFlames = 1;
            AppLogger.debug("Neuer Streak mit Joker gestartet! Flames: 1");
          }
        } else {
          // Erster Post überhaupt
          newFlames = 1;
          AppLogger.debug("Erster Post mit Joker! Flames: 1");
        }

        final nowUtc = DateTime.now().toUtc();
        final activeDayStr = activeLondonChallengeDayStrFromUtc(nowUtc);

        await client
            .from("users_profile")
            .update({
              "joker": newJokerCount,
              "joker_used_today": true,
              "last_posted_date": activeDayStr,
              "flames": newFlames,
            })
            .eq("id", userId);

        notifyPostDataChanged();

        AppLogger.debug(
          "Joker verwendet! Count: $newJokerCount, joker_used_today: true, Flames: $newFlames",
        );

        if (mounted) {
          setState(() {
            jokerCount = newJokerCount;
            _jokerUsedForActiveChallenge = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Streak mit Joker gesichert. Kamera wird geöffnet. Verbleibende Joker: $newJokerCount",
                  "Streak saved with joker. Opening camera now. Remaining jokers: $newJokerCount",
                ),
              ),
            ),
          );
        }

        shouldOpenCamera = openCameraAfterSave;
      }
    } catch (e) {
      AppLogger.debug("SKIP ERROR: $e");

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
    }

    if (shouldOpenCamera && mounted) {
      // Keep `uploading` true while the camera intent is alive so the parent
      // scaffold doesn't rebuild between flipping the joker flag and opening
      // the picker — that intermediate rebuild was sometimes invalidating the
      // dialog context, dropping the user back on the daily quest screen
      // without showing the preview.
      await takePhoto();
    }
    _setUploading(false);
  }

  /// Splits the challenge description into spans, coloring "important" words
  /// (length > 5, ignoring trailing punctuation) with the accent color so the
  /// copy reads with rhythm instead of as a flat block of text.
  TextSpan _buildDescriptionSpan(
    String text, {
    required Color baseColor,
    required Color accentColor,
  }) {
    if (text.isEmpty) {
      return TextSpan(text: text, style: TextStyle(color: baseColor));
    }
    final children = <TextSpan>[];
    // Walk the string preserving whitespace runs verbatim, since
    // `String.split(RegExp)` in Dart discards the separator (unlike JS).
    final pattern = RegExp(r'\s+');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        final word = text.substring(cursor, match.start);
        children.add(_descriptionWordSpan(word, baseColor, accentColor));
      }
      children.add(TextSpan(text: match.group(0)));
      cursor = match.end;
    }
    if (cursor < text.length) {
      children.add(
        _descriptionWordSpan(text.substring(cursor), baseColor, accentColor),
      );
    }
    return TextSpan(children: children);
  }

  TextSpan _descriptionWordSpan(
    String word,
    Color baseColor,
    Color accentColor,
  ) {
    final core = word.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
    final isAccent = core.length > 5;
    return TextSpan(
      text: word,
      style: TextStyle(
        color: isAccent ? accentColor : baseColor,
        fontWeight: isAccent ? FontWeight.w800 : FontWeight.w600,
      ),
    );
  }

  Widget _buildDailyChallengeCard({
    required Color cardDark,
    required Color textPrimary,
    required Color textSecondary,
    required Color accentGreen,
    required bool compactLayout,
  }) {
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    final widthScale = (screenWidth / 390).clamp(0.76, 1.0).toDouble();
    final heightScale = (screenSize.height / 844).clamp(0.68, 1.0).toDouble();
    final layoutScale = math.min(widthScale, heightScale);
    final narrowLayout = screenWidth < 360;
    final typographyScale = math.max(widthScale, narrowLayout ? 0.92 : 0.96);
    final horizontalMargin = 0.0;
    final cardPadding = compactLayout
        ? EdgeInsets.fromLTRB(
            18 * layoutScale,
            20 * layoutScale,
            18 * layoutScale,
            18 * layoutScale,
          )
        : EdgeInsets.fromLTRB(
            22 * layoutScale,
            24 * layoutScale,
            22 * layoutScale,
            22 * layoutScale,
          );
    final titleFontSize =
        (compactLayout ? (narrowLayout ? 29.0 : 31.0) : 34.0) * typographyScale;
    final descriptionFontSize = (compactLayout ? 15.5 : 16.0) * typographyScale;
    final startTimeFontSize = (compactLayout ? 13.0 : 13.5) * typographyScale;
    final bodyGap = (compactLayout ? 9.0 : 10.0) * layoutScale;
    final timerSectionGap = (compactLayout ? 14.0 : 16.0) * layoutScale;
    final timerLabelGap = (compactLayout ? 7.0 : 8.0) * layoutScale;
    final timerValueGap = (compactLayout ? 9.0 : 10.0) * layoutScale;
    final timerFontSize = (compactLayout ? 38.0 : 42.0) * typographyScale;

    return ValueListenableBuilder<String>(
      valueListenable: _timeRemaining,
      builder: (context, value, _) {
        final now = DateTime.now();
        final start = _challengeStartLocal;
        final end = _challengeEndLocal;
        final hasStarted = start != null && !now.isBefore(start);
        final remainingRaw = end == null
            ? Duration.zero
            : end.difference(now);
        final remaining = remainingRaw.isNegative
            ? Duration.zero
            : remainingRaw;
        final showEndedState =
            end != null && hasStarted && remaining.inSeconds <= 0;
        // Urgent threshold raised from 10 → 30 min so the red treatment is
        // visible during the realistic last-stretch (mockup shows 8 min).
        final isUrgent =
            !showEndedState && remaining <= const Duration(minutes: 30);
        final isCritical =
            !showEndedState && remaining <= const Duration(minutes: 5);

        // Urgent color palette — pinkish-red glow matching the mockup.
        const urgentBorder = Color(0xFFFF4D5E);
        const urgentGlow = Color(0xFFFF6B7A);
        const urgentSoftLabel = Color(0xFFFF8A95);

        // Outer-card glow flips between green (chill) and red (urgent).
        final outerGlow = isUrgent
            ? urgentGlow
            : showEndedState
            ? const Color(0xFFFF5E6D)
            : accentGreen;
        final outerBorder = isUrgent
            ? urgentBorder
            : showEndedState
            ? const Color(0xFFFF5E6D)
            : accentGreen.withValues(alpha: 0.72);

        // Two-tone title: first word white, remainder accent (green normally,
        // pink-red when urgent). Falls back to plain white if title is a
        // single word.
        final titleAccent = isUrgent ? urgentGlow : accentGreen;
        final words = challengeTitle.trim().split(RegExp(r'\s+'));
        TextSpan titleSpan;
        if (words.length <= 1) {
          titleSpan = TextSpan(
            text: challengeTitle,
            style: TextStyle(color: textPrimary),
          );
        } else {
          titleSpan = TextSpan(
            children: [
              TextSpan(
                text: '${words.first}\n',
                style: TextStyle(color: textPrimary),
              ),
              TextSpan(
                text: words.skip(1).join(' '),
                style: TextStyle(color: titleAccent),
              ),
            ],
          );
        }

        double progress = 0;
        if (start != null && end != null) {
          final totalSeconds = end.difference(start).inSeconds;
          if (totalSeconds > 0) {
            final elapsed = (totalSeconds - remaining.inSeconds).clamp(
              0,
              totalSeconds,
            );
            progress = elapsed.toDouble() / totalSeconds;
          } else if (showEndedState) {
            progress = 1;
          }
        }

        return Container(
          margin: EdgeInsets.symmetric(horizontal: horizontalMargin),
          padding: cardPadding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24 * layoutScale),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [cardDark, const Color(0xFF171A18)],
            ),
            border: Border.all(
              color: outerBorder,
              width: 1.55 * layoutScale,
            ),
            boxShadow: [
              BoxShadow(
                color: outerGlow.withValues(alpha: isUrgent ? 0.42 : 0.34),
                blurRadius: 38,
                spreadRadius: -2,
              ),
              BoxShadow(
                color: outerGlow.withValues(alpha: isUrgent ? 0.32 : 0.24),
                blurRadius: 62,
                spreadRadius: 1,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Decorative scattered stars (very subtle, no perf cost)
              Positioned(
                top: -2,
                left: 6,
                child: Icon(
                  Icons.star_rounded,
                  size: 10 * layoutScale,
                  color: const Color(0xFFB39DFF).withValues(alpha: 0.6),
                ),
              ),
              Positioned(
                top: 24,
                right: 10,
                child: Icon(
                  Icons.star_rounded,
                  size: 12 * layoutScale,
                  color: appGreen.withValues(alpha: 0.55),
                ),
              ),
              Positioned(
                bottom: 8,
                left: -2,
                child: Icon(
                  Icons.star_rounded,
                  size: 9 * layoutScale,
                  color: const Color(0xFFFF7AA8).withValues(alpha: 0.55),
                ),
              ),
              Column(
                children: [
                  // Eyebrow: "— Today's sidequest —"
                  Padding(
                    padding: EdgeInsets.only(bottom: bodyGap),
                    child: Text(
                      t('— Heutige Quest —', "— Today's quest —"),
                      // Nunito (the headline font) instead of a third
                      // display font; 18/21 matches the old 25/29 width.
                      style: GoogleFonts.nunito(
                        fontSize: (compactLayout ? 18.0 : 21.0) * typographyScale,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFFB39DFF),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  // Two-tone bold headline — Nunito w900 matches the chunky,
                  // rounded geometric feel from the mockup.
                  Text.rich(
                    titleSpan,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                      fontSize: titleFontSize,
                      fontWeight: FontWeight.w900,
                      height: 1.02,
                      letterSpacing: -0.5,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: bodyGap),
                  // Description container
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: 14 * layoutScale,
                      vertical: 10 * layoutScale,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(14 * layoutScale),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Text.rich(
                      _buildDescriptionSpan(
                        challengeDescription,
                        baseColor: textSecondary,
                        accentColor: titleAccent,
                      ),
                      style: _inter.copyWith(
                        fontSize: descriptionFontSize,
                        fontWeight: FontWeight.w600,
                        color: textSecondary,
                        height: 1.35,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(height: bodyGap),
                  Text(
                    challengeStartLocalText,
                    style: _inter.copyWith(
                      fontSize: startTimeFontSize,
                      fontWeight: FontWeight.w600,
                      color: textSecondary.withValues(alpha: 0.9),
                    ),
                  ),
                  SizedBox(height: timerSectionGap),
                  // Timer card — green when chill, red when urgent
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    padding: compactLayout
                        ? EdgeInsets.fromLTRB(
                            14 * layoutScale,
                            12 * layoutScale,
                            14 * layoutScale,
                            14 * layoutScale,
                          )
                        : EdgeInsets.fromLTRB(
                            16 * layoutScale,
                            14 * layoutScale,
                            16 * layoutScale,
                            16 * layoutScale,
                          ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18 * layoutScale),
                      color: Colors.black.withValues(alpha: 0.4),
                      border: Border.all(
                        color: (isUrgent || showEndedState)
                            ? urgentBorder
                            : accentGreen.withValues(alpha: 0.55),
                        width: 1.4 * layoutScale,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              ((isUrgent || showEndedState)
                                      ? urgentGlow
                                      : accentGreen)
                                  .withValues(
                                    alpha: (isUrgent || showEndedState)
                                        ? 0.32
                                        : 0.18,
                                  ),
                          blurRadius: 28,
                          spreadRadius: -8,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Header: hourglass icon + "time left" label
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.hourglass_empty_rounded,
                              size:
                                  (compactLayout ? 14.0 : 15.0) *
                                  typographyScale,
                              color: (isUrgent || showEndedState)
                                  ? urgentSoftLabel
                                  : accentGreen,
                            ),
                            SizedBox(width: 6 * layoutScale),
                            Text(
                              showEndedState
                                  ? t('ABGELAUFEN', 'ENDED')
                                  : isCritical
                                  ? t('LETZTER PUSH', 'FINAL PUSH')
                                  : t('ZEIT ÜBRIG', 'TIME LEFT'),
                              style: _inter.copyWith(
                                fontSize:
                                    (compactLayout ? 12.5 : 13.0) *
                                    typographyScale,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.6,
                                color: (isUrgent || showEndedState)
                                    ? urgentSoftLabel
                                    : accentGreen,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: timerLabelGap),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            value,
                            maxLines: 1,
                            style: GoogleFonts.inter(
                              fontSize: timerFontSize,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                              letterSpacing: 1.8,
                              height: 1,
                              // Equal-width digits: the countdown doesn't
                              // wiggle as the numbers change.
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              shadows: isUrgent
                                  ? [
                                      Shadow(
                                        color: urgentGlow.withValues(
                                          alpha: 0.55,
                                        ),
                                        blurRadius: 18,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                        SizedBox(height: timerValueGap),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                            999 * layoutScale,
                          ),
                          child: LinearProgressIndicator(
                            minHeight: (compactLayout ? 5 : 6) * layoutScale,
                            value: progress,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.08,
                            ),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              (isUrgent || showEndedState)
                                  ? urgentGlow
                                  : accentGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: _ChallengeScreenScaffold(),
    );
  }
}

bool _usesCompactBottomNav(Size size) {
  return sideQuestAdaptiveLayoutForSize(size).isCompactHeight;
}

bool _usesNarrowBottomNav(Size size) {
  return sideQuestAdaptiveLayoutForSize(size).isNarrowWidth;
}

double _bottomNavHeightForSize(Size size) {
  return sideQuestAdaptiveLayoutForSize(size).bottomNavHeight;
}

double _bottomNavOuterInsetForSize(Size size) {
  return sideQuestAdaptiveLayoutForSize(size).bottomNavOuterInset;
}

double _bottomNavInnerPaddingForSize(Size size) {
  return sideQuestAdaptiveLayoutForSize(size).bottomNavInnerPadding;
}

double _bottomNavBottomOffsetForSize(
  Size size, {
  required bool isKeyboardOpen,
}) {
  return sideQuestAdaptiveLayoutForSize(
    size,
  ).bottomNavBottomOffset(isKeyboardOpen: isKeyboardOpen);
}

class _ChallengeScreenScaffold extends StatelessWidget {
  const _ChallengeScreenScaffold();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_CameraScreenState>();
    if (state == null) return const SizedBox.shrink();

    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: darkBg,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final navSize = Size(constraints.maxWidth, constraints.maxHeight);
            final safeBottom = MediaQuery.of(context).padding.bottom;
            final widthScale = (constraints.maxWidth / 390).clamp(0.78, 1.0);
            final heightScale = (constraints.maxHeight / 844).clamp(0.7, 1.0);
            final layoutScale = math.min(
              widthScale.toDouble(),
              heightScale.toDouble(),
            );
            // Threshold bumped from 760 → 820 so regular iPhones (14, 15)
            // also get the compact treatment — otherwise the daily card +
            // camera button + joker section overflow and force scrolling.
            final compactLayout =
                constraints.maxHeight < 820 || layoutScale < 0.96;
            final ultraCompactLayout =
                constraints.maxHeight < 700 || layoutScale < 0.82;
            final uiTextScale = math.max(
              widthScale.toDouble(),
              compactLayout ? 0.92 : 0.96,
            );
            final horizontalPagePadding =
                (ultraCompactLayout
                    ? 14.0
                    : compactLayout
                    ? 16.0
                    : 20.0) *
                layoutScale;
            final navBarHeight = _bottomNavHeightForSize(navSize);
            final bottomSpacing = _bottomNavBottomOffsetForSize(
              navSize,
              isKeyboardOpen: false,
            );
            final reservedBottom =
                navBarHeight + bottomSpacing + safeBottom + 4 * layoutScale;
            final topPadding =
                (ultraCompactLayout
                    ? 6.0
                    : compactLayout
                    ? 10.0
                    : 18.0) *
                layoutScale;
            final contentMinHeight = math.max(
              0.0,
              constraints.maxHeight - reservedBottom - topPadding,
            );
            final contentMaxWidth = math.min(
              constraints.maxWidth - (horizontalPagePadding * 2),
              430.0,
            );
            // Regular iPhones (14/15) hit `compactLayout` after the 820
            // threshold bump and ended up with the small 88px shutter — bump
            // it back close to non-compact size so it reads as the primary
            // action. ultraCompactLayout (iPhone SE) stays smaller.
            final cameraButtonSize =
                (ultraCompactLayout
                    ? 84.0
                    : compactLayout
                    ? 104.0
                    : 100.0) *
                layoutScale;
            final cameraIconSize =
                (ultraCompactLayout
                    ? 36.0
                    : compactLayout
                    ? 48.0
                    : 45.0) *
                layoutScale;
            // Push the camera button a bit further down on compact iPhones
            // (was 26, felt cramped under the card).
            final cardToButtonGap =
                (ultraCompactLayout
                    ? 18.0
                    : compactLayout
                    ? 44.0
                    : 42.0) *
                layoutScale;
            // Regular iPhones (14/15) hit `compactLayout` after we bumped the
            // threshold to 820 — they have plenty of vertical room left between
            // the camera button and the bottom nav, so push the joker down a
            // bit instead of stranding it directly under the shutter.
            final buttonToJokerGap =
                (ultraCompactLayout
                    ? 22.0
                    : compactLayout
                    ? 52.0
                    : 34.0) *
                layoutScale;
            final jokerCardWidth = math.min(
              contentMaxWidth * (compactLayout ? 0.88 : 0.82),
              320.0,
            );

            return SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.only(top: topPadding, bottom: reservedBottom),
              child: Center(
                child: SizedBox(
                  width: contentMaxWidth,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: contentMinHeight),
                    child: Column(
                      mainAxisAlignment: compactLayout
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: state._buildDailyChallengeCard(
                            cardDark: cardDark,
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                            accentGreen: accentGreen,
                            compactLayout: compactLayout,
                          ),
                        ),
                        SizedBox(height: cardToButtonGap),
                        state.uploading
                            ? CircularProgressIndicator(color: accentGreen)
                            : GestureDetector(
                                onTap: state.takePhoto,
                                child: Container(
                                  width: cameraButtonSize,
                                  height: cameraButtonSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: accentGreen.withValues(alpha: 0.18),
                                    border: Border.all(
                                      color: accentGreen,
                                      width:
                                          (compactLayout ? 2.5 : 3) *
                                          layoutScale,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.camera_alt,
                                    size: cameraIconSize,
                                    color: accentGreen,
                                  ),
                                ),
                              ),
                        SizedBox(height: buttonToJokerGap),
                        if (!state.uploading &&
                            state._challengeEndLocal != null &&
                            DateTime.now().isAfter(state._challengeEndLocal!))
                          _JokerButton(
                            jokerCount: state.jokerCount,
                            alreadyUsed: state._jokerUsedForActiveChallenge,
                            onUseJoker: state.skipWithJoker,
                            onOpenCamera: state.takePhoto,
                            uiTextScale: uiTextScale,
                            layoutScale: layoutScale,
                            compactLayout: compactLayout,
                            maxWidth: jokerCardWidth,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact pill-shaped joker button matching the SideQuest mockup:
/// dark fill, thin amber-glow border, gold star + "Use joker" label, and a
/// small inset "N LEFT" badge on the right. Tap = consume a joker and open
/// the camera so the streak is saved.
class _JokerButton extends StatelessWidget {
  final int jokerCount;
  final bool alreadyUsed;
  final VoidCallback onUseJoker;
  final VoidCallback onOpenCamera;
  final double uiTextScale;
  final double layoutScale;
  final bool compactLayout;
  final double maxWidth;

  const _JokerButton({
    required this.jokerCount,
    required this.alreadyUsed,
    required this.onUseJoker,
    required this.onOpenCamera,
    required this.uiTextScale,
    required this.layoutScale,
    required this.compactLayout,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB347);
    const amberSoft = Color(0xFFFFA336);
    const fillDark = Color(0xFF1B1B1B);

    final hasJokers = jokerCount > 0;
    final isInteractive = !alreadyUsed && hasJokers;

    final radius = 28.0 * layoutScale;
    final outerHeight = (compactLayout ? 52.0 : 58.0) * layoutScale;
    final iconSize = (compactLayout ? 22.0 : 24.0) * layoutScale;
    final labelSize = (compactLayout ? 16.0 : 17.0) * uiTextScale;
    final pillFontSize = (compactLayout ? 11.0 : 11.5) * uiTextScale;

    final label = alreadyUsed
        ? t('Joker bereits genutzt', 'Joker already used')
        : t('Joker einsetzen', 'Use joker');

    return Center(
      child: Opacity(
        opacity: alreadyUsed ? 0.55 : 1.0,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: alreadyUsed
              ? onOpenCamera
              : (hasJokers ? onUseJoker : null),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Container(
              height: outerHeight,
              padding: EdgeInsets.symmetric(horizontal: 16 * layoutScale),
              decoration: BoxDecoration(
                color: fillDark,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: isInteractive
                      ? amber.withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.12),
                  width: 1.4 * layoutScale,
                ),
                boxShadow: isInteractive
                    ? [
                        BoxShadow(
                          color: amberSoft.withValues(alpha: 0.30),
                          blurRadius: 22,
                          spreadRadius: -4,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    alreadyUsed
                        ? Icons.camera_alt_rounded
                        : Icons.star_rounded,
                    size: iconSize,
                    color: alreadyUsed ? Colors.white : amber,
                  ),
                  SizedBox(width: 12 * layoutScale),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _inter.copyWith(
                        fontSize: labelSize,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  if (!alreadyUsed) ...[
                    SizedBox(width: 10 * layoutScale),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10 * layoutScale,
                        vertical: 5 * layoutScale,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: amber.withValues(alpha: 0.55),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        t('$jokerCount ÜBRIG', '$jokerCount LEFT'),
                        style: _inter.copyWith(
                          fontSize: pillFontSize,
                          fontWeight: FontWeight.w800,
                          color: amber,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CollabComposePreviewScreen extends StatefulWidget {
  final String baseImageUrl;
  final String initialExtensionImagePath;
  final bool initialHasCropped;
  final Future<_CollabPostRequestResult> Function(String extensionImagePath)
  onPostRequested;

  const _CollabComposePreviewScreen({
    required this.baseImageUrl,
    required this.initialExtensionImagePath,
    required this.initialHasCropped,
    required this.onPostRequested,
  });

  @override
  State<_CollabComposePreviewScreen> createState() =>
      _CollabComposePreviewScreenState();
}

class _CollabPostRequestResult {
  final bool didPost;
  final String? errorMessage;

  const _CollabPostRequestResult.success()
    : didPost = true,
      errorMessage = null;

  const _CollabPostRequestResult.failure([this.errorMessage]) : didPost = false;
}

class _CollabComposePreviewScreenState
    extends State<_CollabComposePreviewScreen> {
  late String _extensionImagePath;
  // Untouched pre-crop path. Kept separate so that re-opening the cropper
  // always starts from the full original picture instead of the previously
  // cropped result (which would cumulatively shave off more of the frame on
  // every re-edit).
  late String _originalImagePath;
  late bool _hasCropped;
  bool _openingCropper = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _extensionImagePath = widget.initialExtensionImagePath;
    _originalImagePath = widget.initialExtensionImagePath;
    _hasCropped = widget.initialHasCropped;
  }

  Future<void> _openCropper() async {
    if (_openingCropper) return;
    setState(() => _openingCropper = true);
    try {
      final recropped = await Navigator.of(context).push<File>(
        MaterialPageRoute(
          builder: (_) => GestureCropperScreen.combo(
            sourcePath: _originalImagePath,
            title: t('Kombi zuschneiden', 'Crop combo post'),
            cancelLabel: t('Abbrechen', 'Cancel'),
            confirmLabel: t('Fertig', 'Done'),
          ),
        ),
      );
      if (!mounted || recropped == null) return;
      setState(() {
        _extensionImagePath = recropped.path;
        _hasCropped = true;
      });
    } catch (e) {
      AppLogger.debug('Error opening collab cropper: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Fehler beim Zuschneiden', 'Crop failed'))),
      );
    } finally {
      if (mounted) {
        setState(() => _openingCropper = false);
      } else {
        _openingCropper = false;
      }
    }
  }

  Future<void> _submitPost() async {
    if (_posting || _openingCropper) return;
    setState(() => _posting = true);
    try {
      final result = await widget.onPostRequested(_extensionImagePath);
      if (!mounted) return;
      if (result.didPost) {
        Navigator.of(context).pop();
        return;
      }
      final errorMessage = (result.errorMessage ?? '').trim();
      if (errorMessage.isNotEmpty) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(errorMessage)));
      }
    } catch (error) {
      AppLogger.debug('Error posting combo extension: $error');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            t('Kombi konnte nicht gepostet werden.', 'Could not post combo.'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _posting = false);
      } else {
        _posting = false;
      }
    }
  }

  Widget _buildBasePreviewHalf({
    required BuildContext context,
    required BorderRadius borderRadius,
  }) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          if (w <= 0 || h <= 0) {
            return Container(color: const Color(0xFF171717));
          }

          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: w * 2,
              maxWidth: w * 2,
              minHeight: h,
              maxHeight: h,
              child: sideQuestNetworkImage(
                imageUrl: widget.baseImageUrl,
                width: w * 2,
                height: h,
                fit: BoxFit.cover,
                alignment: Alignment.centerLeft,
                filterQuality: FilterQuality.low,
                cacheWidth: sideQuestCacheWidth(context, w * 2),
                cacheHeight: sideQuestCacheWidth(context, h),
                errorWidget: Container(
                  width: w * 2,
                  height: h,
                  color: const Color(0xFF171717),
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: w,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      color: Color(0xFF8A8A8A),
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Kombi-Vorschau', 'Combo preview'),
                      style: _inter.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t(
                        'Links die linke Hälfte vom Originalbild, rechts dein Ergänzungsbild.',
                        'Left the original image half, right your extension photo.',
                      ),
                      style: _inter.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFFB0B0B0),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 240,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildBasePreviewHalf(
                              context: context,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(12),
                                bottomLeft: Radius.circular(12),
                              ),
                            ),
                          ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.only(
                                topRight: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                              child: SizedBox.expand(
                                child: Image.file(
                                  File(_extensionImagePath),
                                  width: double.infinity,
                                  height: double.infinity,
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Container(
                                        color: const Color(0xFF171717),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.broken_image_outlined,
                                          color: Color(0xFF8A8A8A),
                                          size: 24,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale = MediaQuery.textScalerOf(
                          context,
                        ).scale(1);
                        final useStackedActions =
                            constraints.maxWidth < 350 || textScale > 1.05;

                        final cancelButton = TextButton(
                          onPressed: (_openingCropper || _posting)
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: Text(t('Abbrechen', 'Cancel')),
                        );
                        final cropButton = TextButton(
                          onPressed: (_openingCropper || _posting)
                              ? null
                              : _openCropper,
                          child: _openingCropper
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                )
                              : Text(
                                  _hasCropped
                                      ? t('Neu zuschneiden', 'Re-crop')
                                      : t('Zuschneiden', 'Crop'),
                                ),
                        );
                        final postButton = ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: (_openingCropper || _posting)
                              ? null
                              : _submitPost,
                          child: _posting
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black.withValues(alpha: 0.8),
                                  ),
                                )
                              : Text(t('Posten', 'Post')),
                        );

                        if (!useStackedActions) {
                          return Row(
                            children: [
                              cancelButton,
                              const Spacer(),
                              cropButton,
                              const SizedBox(width: 6),
                              postButton,
                            ],
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                cancelButton,
                                const Spacer(),
                                cropButton,
                              ],
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: postButton,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TodayFeedScreen extends StatefulWidget {
  final VoidCallback? onOpenOwnProfile;
  final VoidCallback? onOpenFriendsTab;

  const TodayFeedScreen({
    super.key,
    this.onOpenOwnProfile,
    this.onOpenFriendsTab,
  });

  @override
  State<TodayFeedScreen> createState() => TodayFeedScreenState();
}

class TodayFeedScreenState extends State<TodayFeedScreen> {
  String feedFilter = 'daily'; // 'daily' oder 'pvp'
  List<Map<String, dynamic>> cachedPhotos = [];
  List<Map<String, dynamic>> _dailyFeedItems = const [];
  List<Map<String, dynamic>> _pvpFeedItems = const [];
  bool _showFullRefreshLoader = false;
  Map<String, dynamic>? currentUserProfile;
  String? _animatingLikePhotoId;

  /// Bumped on every like/comment-like change so that only
  /// [ListenableBuilder]-wrapped like buttons rebuild — not the full feed.
  final ValueNotifier<int> _likeRevision = ValueNotifier<int>(0);
  Timer? _challengeBoundaryTimer;
  Future<List<Map<String, dynamic>>>? _feedFuture;
  Future<void>? _refreshFeedInFlight;
  final ImagePicker _collabPicker = ImagePicker();
  final Map<String, int> _collabPageByBaseId = {};
  final Map<String, PageController> _collabPageControllers = {};
  String? _collabUploadingBaseId;
  bool _collabFlowActive = false;
  final ItemScrollController _feedItemScrollController = ItemScrollController();
  final ItemPositionsListener _feedItemPositionsListener =
      ItemPositionsListener.create();
  PostFocusRequest? _pendingPostFocusRequest;
  bool _isApplyingPostFocusRequest = false;
  final Set<String> _commentLikeInFlightIds = <String>{};
  // Per-photo press-state notifiers. The friend-likes overlay listens to
  // these so it can fade out while the user holds down the post image to
  // inspect the photo cleanly.
  final Map<String, ValueNotifier<bool>> _photoPressNotifiers = {};

  ValueNotifier<bool> _photoPressNotifierFor(String photoId) {
    return _photoPressNotifiers.putIfAbsent(
      photoId,
      () => ValueNotifier<bool>(false),
    );
  }

  Future<void> scrollToTop() async {
    if (!_feedItemScrollController.isAttached) return;
    await _feedItemScrollController.scrollTo(
      index: 0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUserProfile();
    _scheduleFeedRefreshAtNextChallengeStart();
    languageController.addListener(_onLanguageChanged);
    postFocusRequestNotifier.addListener(_handlePostFocusRequest);
    _feedFuture = _loadAndCacheFeed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handlePostFocusRequest();
    });
  }

  @override
  void dispose() {
    _challengeBoundaryTimer?.cancel();
    _likeRevision.dispose();
    for (final controller in _collabPageControllers.values) {
      controller.dispose();
    }
    for (final notifier in _photoPressNotifiers.values) {
      notifier.dispose();
    }
    _photoPressNotifiers.clear();
    languageController.removeListener(_onLanguageChanged);
    postFocusRequestNotifier.removeListener(_handlePostFocusRequest);
    super.dispose();
  }

  PageController _collabPageControllerFor(String baseId, int initialPage) {
    return _collabPageControllers.putIfAbsent(
      baseId,
      () => PageController(initialPage: initialPage, keepPage: false),
    );
  }

  void _setCollabPage(
    String baseId,
    int targetPage, {
    bool syncController = true,
  }) {
    if (baseId.isEmpty) return;
    if (_collabPageByBaseId[baseId] == targetPage && !syncController) return;

    if (mounted) {
      setState(() => _collabPageByBaseId[baseId] = targetPage);
    } else {
      _collabPageByBaseId[baseId] = targetPage;
    }

    if (syncController) {
      _syncCollabPageController(baseId, targetPage);
    }
  }

  void _syncCollabPageController(String baseId, int targetPage) {
    final controller = _collabPageControllers[baseId];
    if (controller == null) return;

    void syncOnNextFrame([int attempt = 0]) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final activeController = _collabPageControllers[baseId];
        if (activeController == null) return;
        if (!activeController.hasClients) {
          if (attempt < 4) {
            syncOnNextFrame(attempt + 1);
          }
          return;
        }
        final activePage =
            activeController.page?.round() ?? activeController.initialPage;
        if (activePage != targetPage) {
          activeController.jumpToPage(targetPage);
        }
      });
    }

    if (controller.hasClients) {
      final currentPage = controller.page?.round() ?? controller.initialPage;
      if (currentPage == targetPage) return;
    }
    syncOnNextFrame();
  }

  void _pruneCollabPageControllers(
    Iterable<Map<String, dynamic>> activeEntries,
  ) {
    final activeBaseIds = activeEntries
        .where((entry) => (entry['_daily_collab'] ?? false) == true)
        .map(
          (entry) =>
              ((entry['base_photo'] as Map<String, dynamic>?)?['id'] ?? '')
                  .toString(),
        )
        .where((baseId) => baseId.isNotEmpty)
        .toSet();

    final staleBaseIds = _collabPageControllers.keys
        .where((baseId) => !activeBaseIds.contains(baseId))
        .toList(growable: false);
    for (final baseId in staleBaseIds) {
      _collabPageControllers.remove(baseId)?.dispose();
      _collabPageByBaseId.remove(baseId);
    }
  }

  void _onLanguageChanged() {
    if (mounted) {
      setState(() {
        _feedFuture = _loadAndCacheFeed();
      });
    }
  }

  void _scheduleFeedRefreshAtNextChallengeStart() {
    _challengeBoundaryTimer?.cancel();
    final nowLocal = DateTime.now();
    final todayStartLocal = challengeStartLocal(nowLocal);
    final nextStartLocal = nowLocal.isBefore(todayStartLocal)
        ? todayStartLocal
        : challengeStartLocal(nowLocal.add(const Duration(days: 1)));
    final delay =
        nextStartLocal.difference(nowLocal) + const Duration(seconds: 1);
    if (delay.isNegative) return;
    _challengeBoundaryTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        _feedFuture = _loadAndCacheFeed();
      });
      _scheduleFeedRefreshAtNextChallengeStart();
    });
  }

  void _storeFeedData(List<Map<String, dynamic>> data) {
    cachedPhotos = data;

    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final dailyItems = data
        .where((photo) {
          final isChallenge = photo['is_challenge_photo'] == true;
          final isLate = photo['is_late'] == true;
          return !isChallenge || isLate;
        })
        .toList(growable: false);
    final pvpItems = data
        .where((photo) {
          final isChallenge = photo['is_challenge_photo'] == true;
          final isLate = photo['is_late'] == true;
          return isChallenge && !isLate;
        })
        .toList(growable: false);

    final sortedDailyItems = List<Map<String, dynamic>>.from(dailyItems)
      ..sort((a, b) {
        final aIsCurrentUser = a['user_id'] == currentUserId;
        final bIsCurrentUser = b['user_id'] == currentUserId;

        if (aIsCurrentUser && !bIsCurrentUser) return -1;
        if (!aIsCurrentUser && bIsCurrentUser) return 1;

        return (b['created_at'] as String).compareTo(a['created_at'] as String);
      });

    _dailyFeedItems = _buildDailyCollabItems(sortedDailyItems, currentUserId);
    _pvpFeedItems = _buildPvpDuelItems(pvpItems);
    _pruneCollabPageControllers(_dailyFeedItems);
  }

  Future<List<Map<String, dynamic>>> _loadAndCacheFeed({
    bool refreshProfile = false,
    bool surfaceErrors = false,
  }) async {
    final data = await loadTodayFeed(surfaceErrors: surfaceErrors);
    if (mounted) {
      setState(() {
        _storeFeedData(data);
      });
    } else {
      _storeFeedData(data);
    }
    if (refreshProfile) {
      await _loadCurrentUserProfile();
    }
    return data;
  }

  Future<void> _refreshFeed() async {
    if (_collabFlowActive) return;
    final inFlight = _refreshFeedInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      final loadFuture = _loadAndCacheFeed(
        refreshProfile: true,
        surfaceErrors: true,
      );
      setState(() {
        _showFullRefreshLoader = true;
        _feedFuture = loadFuture;
      });
      try {
        await loadFuture;
      } finally {
        _refreshFeedInFlight = null;
        if (mounted) {
          setState(() {
            _showFullRefreshLoader = false;
          });
        }
      }
    }();

    _refreshFeedInFlight = future;
    return future;
  }

  void _handlePostFocusRequest() {
    final request = postFocusRequestNotifier.value;
    if (request == null || request.tabIndex != 0) return;

    final desiredFilter = (request.todayFeedFilter ?? '').trim();
    final future = _loadAndCacheFeed(surfaceErrors: true);
    if (!mounted) {
      _pendingPostFocusRequest = request;
      if (desiredFilter.isNotEmpty) {
        feedFilter = desiredFilter;
      }
      _feedFuture = future;
      return;
    }

    setState(() {
      _pendingPostFocusRequest = request;
      _feedFuture = future;
      if (desiredFilter.isNotEmpty && feedFilter != desiredFilter) {
        feedFilter = desiredFilter;
      }
    });
  }

  bool _entryContainsPhoto(Map<String, dynamic> entry, String photoId) {
    if (photoId.isEmpty) return false;

    if ((entry['_pvp_duel'] ?? false) == true) {
      final challengerPhoto =
          entry['challenger_photo'] as Map<String, dynamic>?;
      final challengedPhoto =
          entry['challenged_photo'] as Map<String, dynamic>?;
      return (challengerPhoto?['id'] ?? '').toString() == photoId ||
          (challengedPhoto?['id'] ?? '').toString() == photoId;
    }

    if ((entry['_daily_collab'] ?? false) == true) {
      final basePhoto = entry['base_photo'] as Map<String, dynamic>?;
      if ((basePhoto?['id'] ?? '').toString() == photoId) {
        return true;
      }
      final extensions = (entry['extensions'] as List? ?? const []);
      return extensions.any(
        (extension) => (extension['id'] ?? '').toString() == photoId,
      );
    }

    final rawPhoto = feedFilter == 'pvp'
        ? ((entry['photo'] as Map<String, dynamic>?) ?? entry)
        : entry;
    return (rawPhoto['id'] ?? '').toString() == photoId;
  }

  /// Returns a stable key for a feed entry so TweenAnimationBuilder elements
  /// survive setState rebuilds without re-animating.
  String _feedEntryKey(Map<String, dynamic> entry) {
    if ((entry['_pvp_duel'] ?? false) == true) {
      return 'pvp_${(entry['challenge_id'] ?? entry['id'] ?? '').toString()}';
    }
    if ((entry['_daily_collab'] ?? false) == true) {
      final base = entry['base_photo'] as Map<String, dynamic>?;
      return 'collab_${(base?['id'] ?? '').toString()}';
    }
    return 'post_${(entry['id'] ?? '').toString()}';
  }

  int _findDisplayItemIndex(
    List<Map<String, dynamic>> displayItems,
    String photoId,
  ) {
    for (var i = 0; i < displayItems.length; i++) {
      if (_entryContainsPhoto(displayItems[i], photoId)) {
        return i;
      }
    }
    return -1;
  }

  Future<void> _openCommentsForFocusedEntry(
    Map<String, dynamic> entry,
    PostFocusRequest request,
  ) async {
    final highlightedCommentId = (request.commentId ?? '').trim();
    if (highlightedCommentId.isEmpty) return;

    if ((entry['_pvp_duel'] ?? false) == true) {
      final challengerPhoto =
          entry['challenger_photo'] as Map<String, dynamic>?;
      final challengedPhoto =
          entry['challenged_photo'] as Map<String, dynamic>?;
      final challengerPhotoId = (challengerPhoto?['id'] ?? '').toString();
      final challengedPhotoId = (challengedPhoto?['id'] ?? '').toString();
      final linkedPhotoIds = <String>[
        if (challengerPhotoId.isNotEmpty) challengerPhotoId,
        if (challengedPhotoId.isNotEmpty) challengedPhotoId,
      ];
      final postTargetPhotoId = challengerPhotoId.isNotEmpty
          ? challengerPhotoId
          : challengedPhotoId;
      final duelComments = <Map<String, dynamic>>[
        ...((challengerPhoto?['comments'] as List?) ?? const []).map(
          (comment) => Map<String, dynamic>.from(comment),
        ),
        ...((challengedPhoto?['comments'] as List?) ?? const []).map(
          (comment) => Map<String, dynamic>.from(comment),
        ),
      ];
      duelComments.sort(
        (a, b) => (a['created_at'] ?? '').toString().compareTo(
          (b['created_at'] ?? '').toString(),
        ),
      );

      if (postTargetPhotoId.isEmpty || linkedPhotoIds.isEmpty) return;
      await showCommentsBottomSheet(
        context,
        postTargetPhotoId,
        duelComments,
        linkedPhotoIds: linkedPhotoIds,
        postTargetPhotoId: postTargetPhotoId,
        highlightCommentId: highlightedCommentId,
      );
      return;
    }

    if ((entry['_daily_collab'] ?? false) == true) {
      final basePhoto = Map<String, dynamic>.from(
        (entry['base_photo'] as Map?) ?? const <String, dynamic>{},
      );
      final extensions = List<Map<String, dynamic>>.from(
        ((entry['extensions'] as List?) ?? const []).map(
          (extension) => Map<String, dynamic>.from(extension),
        ),
      );
      final baseId = (basePhoto['id'] ?? '').toString();
      var targetPage = 0;
      var targetPhoto = basePhoto;

      final extensionIndex = extensions.indexWhere(
        (extension) => (extension['id'] ?? '').toString() == request.photoId,
      );
      if (extensionIndex != -1) {
        targetPage = extensionIndex + 1;
        targetPhoto = extensions[extensionIndex];
      }

      if (baseId.isNotEmpty && _collabPageByBaseId[baseId] != targetPage) {
        _setCollabPage(baseId, targetPage);
      }

      final targetPhotoId = (targetPhoto['id'] ?? '').toString();
      if (targetPhotoId.isEmpty) return;

      final targetComments = ((targetPhoto['comments'] as List?) ?? const [])
          .map((comment) => Map<String, dynamic>.from(comment))
          .toList();
      await showCommentsBottomSheet(
        context,
        targetPhotoId,
        targetComments,
        highlightCommentId: highlightedCommentId,
      );
      return;
    }

    final targetPhoto = Map<String, dynamic>.from(
      feedFilter == 'pvp' ? ((entry['photo'] as Map?) ?? entry) : entry,
    );
    final targetPhotoId = (targetPhoto['id'] ?? '').toString();
    if (targetPhotoId.isEmpty) return;

    final photoComments = ((targetPhoto['comments'] as List?) ?? const [])
        .map((comment) => Map<String, dynamic>.from(comment))
        .toList();
    await showCommentsBottomSheet(
      context,
      targetPhotoId,
      photoComments,
      highlightCommentId: highlightedCommentId,
    );
  }

  void _prepareFocusedEntryForRequest(
    Map<String, dynamic> entry,
    String photoId,
  ) {
    if ((entry['_daily_collab'] ?? false) != true) return;

    final basePhoto = Map<String, dynamic>.from(
      (entry['base_photo'] as Map?) ?? const <String, dynamic>{},
    );
    final extensions = List<Map<String, dynamic>>.from(
      ((entry['extensions'] as List?) ?? const []).map(
        (extension) => Map<String, dynamic>.from(extension),
      ),
    );
    final baseId = (basePhoto['id'] ?? '').toString();
    if (baseId.isEmpty) return;

    var targetPage = 0;
    final extensionIndex = extensions.indexWhere(
      (extension) => (extension['id'] ?? '').toString() == photoId,
    );
    if (extensionIndex != -1) {
      targetPage = extensionIndex + 1;
    }

    if (_collabPageByBaseId[baseId] != targetPage) {
      _setCollabPage(baseId, targetPage);
    }
  }

  int _commentCountForPost(Map<String, dynamic> post) {
    final explicitCount = (post['comments_count'] as num?)?.toInt();
    if (explicitCount != null) return explicitCount;
    final comments = (post['comments'] as List?) ?? const [];
    return comments.length;
  }

  List<Map<String, dynamic>> _previewCommentsForPost(
    Map<String, dynamic> post,
  ) {
    final comments = (post['comments'] as List?) ?? const [];
    return comments
        .whereType<Map>()
        .map((comment) => Map<String, dynamic>.from(comment))
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _previewCommentsForDuel(
    Map<String, dynamic> duel,
  ) {
    final challengerPhoto = duel['challenger_photo'] as Map<String, dynamic>?;
    final challengedPhoto = duel['challenged_photo'] as Map<String, dynamic>?;
    final duelComments = <Map<String, dynamic>>[
      ...((challengerPhoto?['comments'] as List?) ?? const []).map(
        (comment) => Map<String, dynamic>.from(comment),
      ),
      ...((challengedPhoto?['comments'] as List?) ?? const []).map(
        (comment) => Map<String, dynamic>.from(comment),
      ),
    ];
    duelComments.sort(
      (a, b) => (a['created_at'] ?? '').toString().compareTo(
        (b['created_at'] ?? '').toString(),
      ),
    );
    return duelComments;
  }

  bool _applyCommentLikeToPhoto(
    Map<String, dynamic> photo,
    String commentId,
    bool wasLiked,
  ) {
    final comments = photo['comments'] as List?;
    if (comments == null) return false;

    for (var index = 0; index < comments.length; index++) {
      final comment = comments[index];
      if (comment is! Map) continue;
      if ((comment['id'] ?? '').toString() != commentId) continue;

      final mutableComment = Map<String, dynamic>.from(comment);
      final count = (mutableComment['likes_count'] as num?)?.toInt() ?? 0;
      mutableComment['is_liked'] = !wasLiked;
      mutableComment['likes_count'] = wasLiked
          ? math.max(0, count - 1)
          : count + 1;
      comments[index] = mutableComment;
      return true;
    }

    return false;
  }

  void _maybeApplyPendingPostFocusRequest(
    List<Map<String, dynamic>> displayItems,
  ) {
    final request = _pendingPostFocusRequest;
    if (request == null || _isApplyingPostFocusRequest) return;

    final targetIndex = _findDisplayItemIndex(displayItems, request.photoId);
    _isApplyingPostFocusRequest = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;

        if (targetIndex == -1) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Dieser Post ist nicht im aktuellen Feed.',
                  'This post is not in the current feed.',
                ),
              ),
            ),
          );
          return;
        }

        _prepareFocusedEntryForRequest(
          displayItems[targetIndex],
          request.photoId,
        );

        // List indices mirror the build-time math: optional daily-quest
        // mini-card slot (only in the daily feed), then photos, then the
        // suggestions rail.
        final miniCardSlot = feedFilter == 'daily' ? 1 : 0;
        var listIndex = targetIndex + miniCardSlot;
        final hasSuggestionsSlot = displayItems.isNotEmpty;
        final suggestionsIndex = (displayItems.length >= 2 ? 2 : 1);
        if (hasSuggestionsSlot && targetIndex >= suggestionsIndex) {
          listIndex += 1;
        }

        if (_feedItemScrollController.isAttached) {
          await _feedItemScrollController.scrollTo(
            index: listIndex,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            alignment: 0.08,
          );
        }

        if (!mounted) return;
        if ((request.commentId ?? '').trim().isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          if (!mounted) return;
          await _openCommentsForFocusedEntry(
            displayItems[targetIndex],
            request,
          );
        }
      } finally {
        if (mounted) {
          setState(() => _pendingPostFocusRequest = null);
        } else {
          _pendingPostFocusRequest = null;
        }
        clearPostFocusRequest();
        _isApplyingPostFocusRequest = false;
      }
    });
  }

  Future<void> _loadCurrentUserProfile() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final row = await client
          .from("users_profile")
          .select("flames")
          .eq("id", userId)
          .single();
      final profile = Map<String, dynamic>.from(row);

      if (mounted) {
        setState(() {
          currentUserProfile = profile;
        });
      }
    } catch (e) {
      AppLogger.debug("Error loading current user profile: $e");
    }
  }

  Widget _feedAnimated(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: child,
    );
  }

  void _openPhotoPreview(String? url) {
    final imageUrl = (url ?? '').trim();
    if (imageUrl.isEmpty) return;

    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: sideQuestNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.contain,
                    cacheWidth: sideQuestCacheWidth(
                      dialogContext,
                      MediaQuery.of(dialogContext).size.width,
                      multiplier: 1.2,
                    ),
                    errorWidget: Container(
                      color: const Color(0xFF111111),
                      alignment: Alignment.center,
                      child: Text(
                        t(
                          'Bild konnte nicht geladen werden',
                          'Could not load image',
                        ),
                        style: _inter.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCollabComposePreview({
    required String baseImageUrl,
    required String extensionImagePath,
    required bool hasCropped,
    required Future<_CollabPostRequestResult> Function(
      String extensionImagePath,
    )
    onPostRequested,
  }) async {
    try {
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push<void>(
        PageRouteBuilder<void>(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.black.withValues(alpha: 0.58),
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 180),
          pageBuilder: (routeContext, animation, secondaryAnimation) =>
              Material(
                type: MaterialType.transparency,
                child: _CollabComposePreviewScreen(
                  baseImageUrl: baseImageUrl,
                  initialExtensionImagePath: extensionImagePath,
                  initialHasCropped: hasCropped,
                  onPostRequested: onPostRequested,
                ),
              ),
          transitionsBuilder:
              (routeContext, animation, secondaryAnimation, child) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: curved,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
                    child: child,
                  ),
                );
              },
        ),
      );
    } catch (e) {
      AppLogger.debug('Error opening collab compose preview: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Fehler in der Vorschau', 'Preview failed')),
          ),
        );
      }
    }
  }

  String _collabUploadErrorMessage(Object error) {
    final message = error.toString();
    final normalized = message.toLowerCase();

    if (normalized.contains('is_collab_extension') ||
        normalized.contains('collab_base_photo_id')) {
      return t(
        'Kombi-Feature ist noch nicht freigeschaltet. Bitte SQL-Migration ausführen.',
        'Combo feature is not enabled yet. Please run the SQL migration.',
      );
    }
    if (normalized.contains('permission denied') ||
        normalized.contains('row-level security')) {
      return t(
        'Keine Berechtigung für diesen Kombi-Post.',
        'You do not have permission for this combo post.',
      );
    }
    if (normalized.contains('network') || normalized.contains('socket')) {
      return t(
        'Netzwerkfehler beim Hochladen. Bitte nochmal probieren.',
        'Network error while uploading. Please try again.',
      );
    }
    return t('Kombi konnte nicht gepostet werden.', 'Could not post combo.');
  }

  Future<_CollabPostRequestResult> _submitCollabExtension({
    required String currentUserId,
    required String baseId,
    required Map<String, dynamic> basePhoto,
    required String extensionImagePath,
  }) async {
    if (mounted) {
      setState(() => _collabUploadingBaseId = baseId);
    } else {
      _collabUploadingBaseId = baseId;
    }

    final client = Supabase.instance.client;

    final collabValidation = await validateImageFile(extensionImagePath);
    if (!collabValidation.isValid) {
      final msg = collabValidation.error == ImageValidationError.tooLarge
          ? t('Bild ist zu groß (max. 25 MB)', 'Image is too large (max 25 MB)')
          : t(
              'Ungültiges Bildformat (nur JPEG/PNG)',
              'Invalid image format (JPEG/PNG only)',
            );
      if (mounted) {
        setState(() => _collabUploadingBaseId = null);
      } else {
        _collabUploadingBaseId = null;
      }
      return _CollabPostRequestResult.failure(msg);
    }

    String? uploadedPath;
    try {
      final fileName = 'collab_${DateTime.now().millisecondsSinceEpoch}.jpg';
      uploadedPath = '$currentUserId/$fileName';
      final compressedCollabFile = await compressPhotoForUpload(
        extensionImagePath,
      );
      await client.storage
          .from('photos')
          .upload(uploadedPath, compressedCollabFile);
      final thumbUrl = await uploadPostThumbnail(
        client: client,
        sourcePath: compressedCollabFile.path,
        fullStoragePath: uploadedPath,
      );
      final publicUrl = client.storage
          .from('photos')
          .getPublicUrl(uploadedPath);
      final createdAtIso = DateTime.now().toUtc().toIso8601String();
      final isPublic = basePhoto['is_public'] == true;

      final insertAttempts = <Map<String, dynamic>>[
        {
          'user_id': currentUserId,
          'url': publicUrl,
          'thumb_url': ?thumbUrl,
          'created_at': createdAtIso,
          'is_public': isPublic,
          'is_challenge_photo': false,
          'challenge_id': null,
          'is_late': false,
          'is_collab_extension': true,
          'collab_base_photo_id': baseId,
        },
        {
          'user_id': currentUserId,
          'url': publicUrl,
          'created_at': createdAtIso,
          'is_public': isPublic,
          'is_late': false,
          'is_collab_extension': true,
          'collab_base_photo_id': baseId,
        },
        {
          'user_id': currentUserId,
          'url': publicUrl,
          'created_at': createdAtIso,
          'is_public': isPublic,
          'is_collab_extension': true,
          'collab_base_photo_id': baseId,
        },
      ];

      Object? insertError;
      for (final payload in insertAttempts) {
        try {
          await client.from('photos').insert(payload).select('id').single();
          insertError = null;
          break;
        } catch (error) {
          insertError = error;
        }
      }

      if (insertError != null) {
        throw insertError;
      }
      // Posted: from here on the file belongs to the post.
      uploadedPath = null;

      final updatedFeed = await loadTodayFeed();
      if (!mounted) return const _CollabPostRequestResult.success();
      setState(() {
        _storeFeedData(updatedFeed);
        _feedFuture = Future.value(updatedFeed);
      });
      _setCollabPage(baseId, 1);
      notifyPostDataChanged();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Kombi ergänzt! Swipe nach rechts.', 'Combo added! Swipe right.'),
          ),
        ),
      );
      return const _CollabPostRequestResult.success();
    } catch (e) {
      AppLogger.debug('Error creating collab extension: $e');
      if (uploadedPath != null) {
        try {
          await client.storage.from('photos').remove([
            uploadedPath,
            thumbnailPathFor(uploadedPath),
          ]);
        } catch (_) {
          // Best effort cleanup.
        }
      }
      return _CollabPostRequestResult.failure(_collabUploadErrorMessage(e));
    } finally {
      if (mounted) {
        setState(() => _collabUploadingBaseId = null);
      } else {
        _collabUploadingBaseId = null;
      }
    }
  }

  bool _isTruthy(dynamic value) {
    return value == true || value == 1 || value == 'true' || value == 't';
  }

  bool _isCollabExtensionPhoto(Map<String, dynamic> photo) {
    return _isTruthy(photo['is_collab_extension']);
  }

  String _collabBasePhotoId(Map<String, dynamic> photo) {
    return (photo['collab_base_photo_id'] ?? '').toString();
  }

  String _collabPairKey(String firstUserId, String secondUserId) {
    final a = firstUserId.trim();
    final b = secondUserId.trim();
    if (a.isEmpty || b.isEmpty) return '';
    return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
  }

  Map<String, int> _computeCollabPairStreaks(
    List<Map<String, dynamic>> historyExtensions,
    Map<String, String> baseOwnerById,
  ) {
    final comboDaysByPair = <String, Set<String>>{};

    for (final extension in historyExtensions) {
      final extensionUserId = (extension['user_id'] ?? '').toString().trim();
      final baseId = (extension['collab_base_photo_id'] ?? '')
          .toString()
          .trim();
      final baseOwnerId = (baseOwnerById[baseId] ?? '').trim();
      if (extensionUserId.isEmpty || baseOwnerId.isEmpty) continue;

      final pairKey = _collabPairKey(baseOwnerId, extensionUserId);
      if (pairKey.isEmpty) continue;

      final createdAtUtc = parseUtcTimestamp(extension['created_at']);
      if (createdAtUtc == null) continue;

      final comboDay = activeLondonChallengeDayStrFromUtc(createdAtUtc);
      comboDaysByPair.putIfAbsent(pairKey, () => <String>{}).add(comboDay);
    }

    final nowUtc = DateTime.now().toUtc();
    final activeDay = activeLondonChallengeDayFromUtc(nowUtc);
    final previousDay = activeDay.subtract(const Duration(days: 1));
    final streaksByPair = <String, int>{};

    for (final entry in comboDaysByPair.entries) {
      final comboDays = entry.value;
      DateTime? anchorDay;

      if (comboDays.contains(londonDateStrFromLondonDay(activeDay))) {
        anchorDay = activeDay;
      } else if (comboDays.contains(londonDateStrFromLondonDay(previousDay))) {
        anchorDay = previousDay;
      }

      if (anchorDay == null) {
        streaksByPair[entry.key] = 0;
        continue;
      }

      var streak = 0;
      var cursor = anchorDay;
      while (comboDays.contains(londonDateStrFromLondonDay(cursor))) {
        streak += 1;
        cursor = cursor.subtract(const Duration(days: 1));
      }

      streaksByPair[entry.key] = streak;
    }

    return streaksByPair;
  }

  bool _canBeCollabBase(Map<String, dynamic> photo) {
    final isChallenge = _isTruthy(photo['is_challenge_photo']);
    final isExtension = _isCollabExtensionPhoto(photo);
    return !isChallenge && !isExtension;
  }

  bool _canContributeToBase(
    Map<String, dynamic> basePhoto,
    List<Map<String, dynamic>> existingExtensions,
    String currentUserId,
  ) {
    if (currentUserId.trim().isEmpty) return false;
    if (!_canBeCollabBase(basePhoto)) return false;
    final baseId = (basePhoto['id'] ?? '').toString();
    final ownerId = (basePhoto['user_id'] ?? '').toString();
    if (baseId.isEmpty || ownerId.isEmpty) return false;
    if (ownerId == currentUserId) return false;
    if (existingExtensions.length >= 2) return false;
    if (existingExtensions.any(
      (e) => (e['user_id'] ?? '').toString() == currentUserId,
    )) {
      return false;
    }
    return true;
  }

  List<Map<String, dynamic>> _buildDailyCollabItems(
    List<Map<String, dynamic>> dailyItems,
    String currentUserId,
  ) {
    final extensionsByBase = <String, List<Map<String, dynamic>>>{};
    final orphanExtensions = <Map<String, dynamic>>[];

    for (final item in dailyItems) {
      if (!_isCollabExtensionPhoto(item)) continue;
      final baseId = _collabBasePhotoId(item);
      if (baseId.isEmpty) {
        orphanExtensions.add(item);
        continue;
      }
      extensionsByBase.putIfAbsent(baseId, () => []).add(item);
    }

    for (final variants in extensionsByBase.values) {
      variants.sort(
        (a, b) => (a['created_at'] ?? '').toString().compareTo(
          (b['created_at'] ?? '').toString(),
        ),
      );
    }

    final result = <Map<String, dynamic>>[];
    for (final item in dailyItems) {
      if (_isCollabExtensionPhoto(item)) continue;
      final baseId = (item['id'] ?? '').toString();
      final variants = List<Map<String, dynamic>>.from(
        extensionsByBase[baseId] ?? const <Map<String, dynamic>>[],
      );
      final canBase = _canBeCollabBase(item);
      final canContribute = _canContributeToBase(item, variants, currentUserId);
      final isOwnPost = (item['user_id'] ?? '').toString() == currentUserId;
      final shouldShowCollabCard =
          canBase && (variants.isNotEmpty || canContribute || isOwnPost);

      if (shouldShowCollabCard) {
        result.add({
          '_daily_collab': true,
          'base_photo': item,
          'extensions': variants,
        });
      } else {
        result.add(item);
      }
    }

    if (orphanExtensions.isNotEmpty) {
      result.addAll(orphanExtensions);
    }
    return result;
  }

  Future<void> _captureCollabExtension(
    Map<String, dynamic> basePhoto,
    List<Map<String, dynamic>> existingExtensions,
  ) async {
    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id ?? '';
    final baseId = (basePhoto['id'] ?? '').toString();
    final baseOwnerId = (basePhoto['user_id'] ?? '').toString();

    if (currentUserId.isEmpty || baseId.isEmpty || baseOwnerId.isEmpty) return;
    if (_collabUploadingBaseId != null) return;

    if (baseOwnerId == currentUserId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Du kannst deinen eigenen Post nicht ergänzen.',
                'You cannot complete your own post.',
              ),
            ),
          ),
        );
      }
      return;
    }

    if (!_canContributeToBase(basePhoto, existingExtensions, currentUserId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Für diesen Post ist keine Ergänzung mehr möglich.',
                'No extension is possible for this post anymore.',
              ),
            ),
          ),
        );
      }
      return;
    }

    try {
      final existing = await client
          .from('photos')
          .select('id, user_id')
          .eq('is_collab_extension', true)
          .eq('collab_base_photo_id', baseId);

      if (existing.length >= 2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Dieses Kombi-Bild hat schon 2 Ergänzungen.',
                  'This combo already has 2 extensions.',
                ),
              ),
            ),
          );
        }
        return;
      }

      final alreadyContributed = existing.any(
        (e) => (e['user_id'] ?? '').toString() == currentUserId,
      );
      if (alreadyContributed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Du hast diesen Post bereits ergänzt.',
                  'You have already extended this post.',
                ),
              ),
            ),
          );
        }
        return;
      }
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('is_collab_extension') ||
          msg.contains('collab_base_photo_id')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Kombi-Feature ist noch nicht freigeschaltet. Bitte SQL-Migration ausführen.',
                  'Combo feature is not enabled yet. Please run the SQL migration.',
                ),
              ),
            ),
          );
        }
        return;
      }
      AppLogger.debug('Error validating collab extension: $e');
    }

    try {
      setComboComposeFlowActive(true);
      if (mounted) {
        setState(() => _collabFlowActive = true);
      } else {
        _collabFlowActive = true;
      }

      XFile? picked;
      try {
        picked = await _collabPicker.pickImage(source: ImageSource.camera);
      } on PlatformException catch (e) {
        if (mounted) {
          final msg = isImagePickerAccessDenied(e)
              ? imagePickerAccessDeniedMessage(cameraOnly: true)
              : t(
                  'Kamera konnte nicht geöffnet werden (${e.code}).',
                  'Could not open camera (${e.code}).',
                );
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
        }
        return;
      }
      if (!mounted || picked == null) return;

      String extensionImagePath = picked.path;
      var hasCropped = false;

      final baseImageUrl = (basePhoto['url'] ?? '').toString().trim();
      if (baseImageUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Originalbild konnte nicht geladen werden.',
                  'Could not load the original image.',
                ),
              ),
            ),
          );
        }
        return;
      }

      await _showCollabComposePreview(
        baseImageUrl: baseImageUrl,
        extensionImagePath: extensionImagePath,
        hasCropped: hasCropped,
        onPostRequested: (currentImagePath) => _submitCollabExtension(
          currentUserId: currentUserId,
          baseId: baseId,
          basePhoto: basePhoto,
          extensionImagePath: currentImagePath,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _collabFlowActive = false);
      } else {
        _collabFlowActive = false;
      }
      setComboComposeFlowActive(false);
    }
  }

  Future<List<Map<String, dynamic>>> loadTodayFeed({
    bool surfaceErrors = false,
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return <Map<String, dynamic>>[];
    final blockedUserIds = await BlockService.loadBlockedRelationshipIdsForUser(
      userId,
    );

    // Bestimme den Start der aktuellen Challenge (nicht Mitternacht)
    final nowLocal = DateTime.now();
    DateTime activeChallengeStartLocal = challengeStartLocal(nowLocal);
    if (nowLocal.isBefore(activeChallengeStartLocal)) {
      // Vor dem heutigen Start: nutze den Start der letzten Challenge
      activeChallengeStartLocal = challengeStartLocal(
        nowLocal.subtract(const Duration(days: 1)),
      );
    }
    final activeChallengeStartUtc = activeChallengeStartLocal.toUtc();

    try {
      // Hole alle gegenseitig akzeptierten Freundschaften
      final acceptedFriends = await client
          .from("friends")
          .select("user_id, friend_id")
          .eq("status", "accepted")
          .or("user_id.eq.$userId,friend_id.eq.$userId");

      // Sammle alle akzeptierten Freund-IDs
      Set<String> friendIds = {userId};
      for (var friendship in acceptedFriends) {
        final isRequester = friendship['user_id'] == userId;
        final friendId = isRequester
            ? friendship['friend_id']
            : friendship['user_id'];
        friendIds.add(friendId);
      }
      friendIds.removeWhere(
        (friendId) => friendId != userId && blockedUserIds.contains(friendId),
      );

      final allPhotos =
          List<dynamic>.from(
                await client
                    .from("photos")
                    .select()
                    .inFilter("user_id", friendIds.toList())
                    .gte(
                      "created_at",
                      activeChallengeStartUtc.toIso8601String(),
                    )
                    .order("created_at", ascending: false),
              )
              .where((photo) {
                final photoUserId = (photo['user_id'] ?? '').toString().trim();
                return !blockedUserIds.contains(photoUserId);
              })
              .toList(growable: false);

      if (allPhotos.isEmpty) {
        return [];
      }

      // Fetch challenge details for PvP posts (best effort)
      final Set<String> challengeIdsSet = {};
      for (final p in allPhotos) {
        final rawIsChallenge = p['is_challenge_photo'];
        final hasBoolFlag =
            rawIsChallenge == true ||
            rawIsChallenge == 1 ||
            rawIsChallenge == 'true' ||
            rawIsChallenge == 't';
        final hasChallengeId = p['challenge_id'] != null;
        // IMPORTANT: Do NOT treat meta fields as PvP markers.
        // Daily posts may also contain these, which would misclassify them.
        final isChallengePhoto = hasBoolFlag || hasChallengeId;
        if (isChallengePhoto && hasChallengeId) {
          challengeIdsSet.add(p['challenge_id'].toString());
        }
      }

      Map<String, Map<String, dynamic>> challengesById = {};
      if (challengeIdsSet.isNotEmpty) {
        try {
          List<dynamic> rows;
          try {
            // Preferred: fetch only the fields we need.
            rows = await client
                .from('challenges')
                .select(
                  'id, description, expires_at, completed_at, winner_id, challenger_id, challenged_id',
                )
                .inFilter('id', challengeIdsSet.toList());
          } catch (e) {
            // Fallback: if the select list fails for any reason, fetch the full row.
            rows = await client
                .from('challenges')
                .select()
                .inFilter('id', challengeIdsSet.toList());
          }

          challengesById = {
            for (final r in rows)
              r['id'].toString(): Map<String, dynamic>.from(r),
          };

          // If the bulk fetch returned nothing (or was blocked), try per-id.
          if (challengesById.isEmpty) {
            for (final id in challengeIdsSet) {
              try {
                final one = await client
                    .from('challenges')
                    .select()
                    .eq('id', id)
                    .maybeSingle();
                if (one != null) {
                  challengesById[id] = Map<String, dynamic>.from(one);
                }
              } catch (_) {
                // ignore, best-effort
              }
            }
          }
        } catch (e) {
          AppLogger.debug('Error loading challenge details for feed: $e');
        }
      }

      // Fetch profiles and collab history in parallel (both only need friendIds)
      final collabHistoryCutoffUtc = DateTime.now().toUtc().subtract(
        const Duration(days: 60),
      );
      final friendIdsList = friendIds.toList();

      final parallelResults = await Future.wait([
        // Profiles
        (() async {
          return await client
              .from("users_profile")
              .select("id, username, profile_picture, flames")
              .inFilter("id", friendIdsList);
        })(),
        // Collab history
        (() async {
          try {
            return await client
                .from('photos')
                .select('id, user_id, created_at, collab_base_photo_id')
                .eq('is_collab_extension', true)
                .inFilter('user_id', friendIdsList)
                .gte('created_at', collabHistoryCutoffUtc.toIso8601String())
                .order('created_at', ascending: false);
          } catch (e) {
            AppLogger.debug('Error loading combo streak history: $e');
            return <dynamic>[];
          }
        })(),
      ]);

      final List<dynamic> profiles = parallelResults[0];
      final Map<String, Map<String, dynamic>> profilesById = {
        for (final prof in profiles)
          (prof['id'] ?? '').toString(): Map<String, dynamic>.from(prof),
      };

      final collabHistoryExtensions = <Map<String, dynamic>>[];
      final collabBaseOwnerById = <String, String>{};
      final List<dynamic> collabRows = parallelResults[1];

      collabHistoryExtensions.addAll(
        collabRows.map((row) => Map<String, dynamic>.from(row)),
      );

      final baseIds = collabHistoryExtensions
          .map((row) => (row['collab_base_photo_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (baseIds.isNotEmpty) {
        try {
          final collabBases = await client
              .from('photos')
              .select('id, user_id')
              .inFilter('id', baseIds);

          for (final base in collabBases) {
            final baseId = (base['id'] ?? '').toString().trim();
            final ownerId = (base['user_id'] ?? '').toString().trim();
            if (baseId.isEmpty || ownerId.isEmpty) continue;
            collabBaseOwnerById[baseId] = ownerId;
          }
        } catch (e) {
          AppLogger.debug('Error loading collab bases: $e');
        }
      }

      final collabPairStreaks = _computeCollabPairStreaks(
        collabHistoryExtensions,
        collabBaseOwnerById,
      );

      // Hole Likes und Comments für alle Fotos
      final photoIds = allPhotos.map((p) => p['id'] as String).toList();

      List<dynamic> likes = [];
      List<dynamic> comments = [];
      List<dynamic> previewCommentLikes = [];

      // Fetch likes and comments in parallel for faster feed load
      final likesAndComments = await Future.wait([
        (() async {
          try {
            return await client
                .from("likes")
                .select('photo_id, user_id')
                .inFilter("photo_id", photoIds);
          } catch (e) {
            AppLogger.debug("Error loading likes: $e");
            return <dynamic>[];
          }
        })(),
        (() async {
          try {
            return await client
                .from("comments")
                .select(
                  "id, photo_id, user_id, message, created_at, users_profile(username, profile_picture)",
                )
                .inFilter("photo_id", photoIds)
                .order("created_at", ascending: true);
          } catch (e) {
            AppLogger.debug("Error loading comments: $e");
            return <dynamic>[];
          }
        })(),
      ]);
      likes = likesAndComments[0];
      comments = List<dynamic>.from(likesAndComments[1])
          .where((rawComment) {
            final comment = Map<String, dynamic>.from(rawComment as Map);
            final commentUserId = (comment['user_id'] ?? '').toString().trim();
            return !blockedUserIds.contains(commentUserId);
          })
          .toList(growable: false);

      final likeCountByPhotoId = <String, int>{
        for (final id in photoIds) id: 0,
      };
      final likedPhotoIds = <String>{};
      for (final rawLike in likes) {
        final like = Map<String, dynamic>.from(rawLike as Map);
        final photoId = (like['photo_id'] ?? '').toString();
        final likeUserId = (like['user_id'] ?? '').toString();
        if (photoId.isEmpty) continue;
        likeCountByPhotoId[photoId] = (likeCountByPhotoId[photoId] ?? 0) + 1;
        if (likeUserId == userId) {
          likedPhotoIds.add(photoId);
        }
      }

      final commentCountByPhotoId = <String, int>{
        for (final id in photoIds) id: 0,
      };
      final previewCommentsByPhotoId = <String, List<Map<String, dynamic>>>{};
      for (final rawComment in comments) {
        final comment = Map<String, dynamic>.from(rawComment as Map);
        final photoId = (comment['photo_id'] ?? '').toString();
        if (photoId.isEmpty) continue;
        commentCountByPhotoId[photoId] =
            (commentCountByPhotoId[photoId] ?? 0) + 1;
        final previews = previewCommentsByPhotoId.putIfAbsent(
          photoId,
          () => [],
        );
        if (previews.length < 2) {
          previews.add(comment);
        }
      }

      final previewCommentIds = previewCommentsByPhotoId.values
          .expand(
            (items) => items
                .map((comment) => (comment['id'] ?? '').toString())
                .where((id) => id.isNotEmpty),
          )
          .toSet()
          .toList(growable: false);
      try {
        if (previewCommentIds.isNotEmpty) {
          try {
            previewCommentLikes = await client
                .from("comment_likes")
                .select('comment_id, user_id')
                .inFilter("comment_id", previewCommentIds);
          } catch (tableError) {
            AppLogger.debug("comment_likes table might not exist: $tableError");
            // Tabelle existiert nicht - ignorieren und ohne Like-Infos weitermachen
            previewCommentLikes = [];
          }
        }
      } catch (e) {
        AppLogger.debug("Error processing comment likes: $e");
      }

      final previewCommentLikeCountById = <String, int>{};
      final likedPreviewCommentIds = <String>{};
      for (final rawCommentLike in previewCommentLikes) {
        final commentLike = Map<String, dynamic>.from(rawCommentLike as Map);
        final commentId = (commentLike['comment_id'] ?? '').toString();
        final likeUserId = (commentLike['user_id'] ?? '').toString();
        if (commentId.isEmpty) continue;
        previewCommentLikeCountById[commentId] =
            (previewCommentLikeCountById[commentId] ?? 0) + 1;
        if (likeUserId == userId) {
          likedPreviewCommentIds.add(commentId);
        }
      }

      // Merge Fotos mit Usernames, Profilbildern, Likes und Comments
      return allPhotos.map<Map<String, dynamic>>((p) {
        final photoId = (p['id'] ?? '').toString();
        final profile =
            profilesById[(p['user_id'] ?? '').toString()] ??
            {
              'username': 'Unknown',
              'profile_picture': null,
              'flames': 0,
            };

        final createdAtUtc = parseUtcTimestamp(p['created_at']);
        final rawIsChallenge = p['is_challenge_photo'];
        final hasBoolFlag =
            rawIsChallenge == true ||
            rawIsChallenge == 1 ||
            rawIsChallenge == 'true' ||
            rawIsChallenge == 't';
        final hasChallengeId = p['challenge_id'] != null;
        final photoChallengeDescription = p['challenge_description'];
        final photoChallengeExpiresAt = p['challenge_expires_at'];
        final isChallengePhoto = hasBoolFlag || hasChallengeId;

        final challengeId = p['challenge_id']?.toString();
        final challenge = (isChallengePhoto && challengeId != null)
            ? challengesById[challengeId]
            : null;
        final challengerId = challenge?['challenger_id']?.toString();
        final challengedId = challenge?['challenged_id']?.toString();
        final challengerProfile = challengerId != null
            ? profilesById[challengerId]
            : null;
        final challengedProfile = challengedId != null
            ? profilesById[challengedId]
            : null;
        bool isLate = p['is_late'] == true;
        // PvP challenge posts should never be treated as late
        if (isChallengePhoto) {
          isLate = false;
        } else if (createdAtUtc != null) {
          final createdAtLocal = createdAtUtc.toLocal();
          final end = challengeEndLocal(createdAtLocal);
          if (createdAtLocal.isAfter(end)) isLate = true;
        }

        final previewComments =
            (previewCommentsByPhotoId[photoId] ??
                    const <Map<String, dynamic>>[])
                .map((comment) {
                  final commentId = (comment['id'] ?? '').toString();
                  return {
                    ...comment,
                    'likes_count': previewCommentLikeCountById[commentId] ?? 0,
                    'is_liked': likedPreviewCommentIds.contains(commentId),
                  };
                })
                .toList(growable: false);
        final collabBaseId = (p['collab_base_photo_id'] ?? '')
            .toString()
            .trim();
        final collabBaseOwnerId = collabBaseOwnerById[collabBaseId] ?? '';
        final collabPairStreak =
            _isCollabExtensionPhoto(Map<String, dynamic>.from(p))
            ? collabPairStreaks[_collabPairKey(
                    collabBaseOwnerId,
                    (p['user_id'] ?? '').toString(),
                  )] ??
                  1
            : 0;

        return {
          ...p,
          'username': profile['username'],
          'profile_picture': profile['profile_picture'],
          'flames': profile['flames'] ?? 0,
          'collab_pair_streak': collabPairStreak,
          'likes_count': likeCountByPhotoId[photoId] ?? 0,
          'is_liked': likedPhotoIds.contains(photoId),
          'comments': previewComments,
          'comments_count': commentCountByPhotoId[photoId] ?? 0,
          'is_challenge_photo': isChallengePhoto,
          'is_late': isLate,
          // Prefer values already stored on the photo row (so the feed can show
          // PvP prompt even when challenges are not readable due to RLS).
          'challenge_description':
              ((photoChallengeDescription ?? '').toString().trim().isNotEmpty)
              ? photoChallengeDescription
              : challenge?['description'],
          'challenge_expires_at':
              ((photoChallengeExpiresAt ?? '').toString().trim().isNotEmpty)
              ? photoChallengeExpiresAt
              : challenge?['expires_at'],
          'challenge_winner_id': challenge?['winner_id'],
          'challenge_completed_at': challenge?['completed_at'],
          'challenge_challenger_id': challengerId,
          'challenge_challenger_username': challengerProfile?['username'],
          'challenge_challenger_profile_picture':
              challengerProfile?['profile_picture'],
          'challenge_challenged_id': challengedId,
          'challenge_challenged_username': challengedProfile?['username'],
          'challenge_challenged_profile_picture':
              challengedProfile?['profile_picture'],
        };
      }).toList();
    } catch (e, stackTrace) {
      AppLogger.error("Error loading today feed", e, stackTrace);
      if (surfaceErrors) {
        rethrow;
      }
      return [];
    }
  }

  bool _isNewerPhoto(
    Map<String, dynamic> candidate,
    Map<String, dynamic>? current,
  ) {
    if (current == null) return true;
    final candidateTs = (candidate['created_at'] ?? '').toString();
    final currentTs = (current['created_at'] ?? '').toString();
    return candidateTs.compareTo(currentTs) > 0;
  }

  List<Map<String, dynamic>> _buildPvpDuelItems(
    List<Map<String, dynamic>> pvpPhotos,
  ) {
    final duelsByChallenge = <String, Map<String, dynamic>>{};
    final orphanPhotos = <Map<String, dynamic>>[];

    for (final photo in pvpPhotos) {
      final challengeId = (photo['challenge_id'] ?? '').toString();
      if (challengeId.isEmpty) {
        orphanPhotos.add(photo);
        continue;
      }

      final challengerId = (photo['challenge_challenger_id'] ?? '').toString();
      final challengedId = (photo['challenge_challenged_id'] ?? '').toString();

      final duel = duelsByChallenge.putIfAbsent(challengeId, () {
        return {
          '_pvp_duel': true,
          'challenge_id': challengeId,
          'challenge_description': photo['challenge_description'],
          'challenge_winner_id': photo['challenge_winner_id'],
          'challenge_completed_at': photo['challenge_completed_at'],
          'challenger_id': challengerId,
          'challenger_username': photo['challenge_challenger_username'],
          'challenger_profile_picture':
              photo['challenge_challenger_profile_picture'],
          'challenged_id': challengedId,
          'challenged_username': photo['challenge_challenged_username'],
          'challenged_profile_picture':
              photo['challenge_challenged_profile_picture'],
          'challenger_photo': null,
          'challenged_photo': null,
          'sort_created_at': '',
        };
      });

      final photoUserId = (photo['user_id'] ?? '').toString();
      final posterName = (photo['username'] ?? '').toString();
      final posterPicture = photo['profile_picture'];
      if (photoUserId == challengerId && challengerId.isNotEmpty) {
        final existing = duel['challenger_photo'] as Map<String, dynamic>?;
        if (_isNewerPhoto(photo, existing)) {
          duel['challenger_photo'] = photo;
          if (((duel['challenger_username'] ?? '').toString()).isEmpty) {
            duel['challenger_username'] = posterName;
            duel['challenger_profile_picture'] = posterPicture;
          }
        }
      } else if (photoUserId == challengedId && challengedId.isNotEmpty) {
        final existing = duel['challenged_photo'] as Map<String, dynamic>?;
        if (_isNewerPhoto(photo, existing)) {
          duel['challenged_photo'] = photo;
          if (((duel['challenged_username'] ?? '').toString()).isEmpty) {
            duel['challenged_username'] = posterName;
            duel['challenged_profile_picture'] = posterPicture;
          }
        }
      } else {
        // Fallback for inconsistent data.
        if (duel['challenger_photo'] == null) {
          duel['challenger_photo'] = photo;
          if (((duel['challenger_username'] ?? '').toString()).isEmpty) {
            duel['challenger_username'] = posterName;
            duel['challenger_profile_picture'] = posterPicture;
          }
        } else if (duel['challenged_photo'] == null) {
          duel['challenged_photo'] = photo;
          if (((duel['challenged_username'] ?? '').toString()).isEmpty) {
            duel['challenged_username'] = posterName;
            duel['challenged_profile_picture'] = posterPicture;
          }
        } else {
          final challengerPhoto =
              duel['challenger_photo'] as Map<String, dynamic>?;
          if (_isNewerPhoto(photo, challengerPhoto)) {
            duel['challenger_photo'] = photo;
            if (((duel['challenger_username'] ?? '').toString()).isEmpty) {
              duel['challenger_username'] = posterName;
              duel['challenger_profile_picture'] = posterPicture;
            }
          }
        }
      }
    }

    final items = <Map<String, dynamic>>[];
    for (final duel in duelsByChallenge.values) {
      final challengerPhoto = duel['challenger_photo'] as Map<String, dynamic>?;
      final challengedPhoto = duel['challenged_photo'] as Map<String, dynamic>?;
      final challengerTs = (challengerPhoto?['created_at'] ?? '').toString();
      final challengedTs = (challengedPhoto?['created_at'] ?? '').toString();
      duel['sort_created_at'] = challengerTs.compareTo(challengedTs) >= 0
          ? challengerTs
          : challengedTs;
      items.add(duel);
    }

    for (final photo in orphanPhotos) {
      items.add({
        '_pvp_duel': false,
        'photo': photo,
        'sort_created_at': (photo['created_at'] ?? '').toString(),
      });
    }

    items.sort(
      (a, b) => (b['sort_created_at'] ?? '').toString().compareTo(
        (a['sort_created_at'] ?? '').toString(),
      ),
    );
    return items;
  }

  Widget _buildPvpParticipantTile({
    required String userId,
    required String username,
    required String? profilePicture,
    required Map<String, dynamic>? photo,
    required bool isWinner,
    required String currentUserId,
  }) {
    final displayName = userId == currentUserId
        ? '$username (${t('Du', 'You')})'
        : username;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF171717),
        border: Border.all(
          color: isWinner ? const Color(0xFF7CFF4D) : const Color(0xFF2E2E2E),
          width: isWinner ? 1.6 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: Colors.black,
                  backgroundImage:
                      (profilePicture != null &&
                          profilePicture.trim().isNotEmpty)
                      ? sideQuestCachedImageProvider(
                          profilePicture,
                          cacheWidth: sideQuestCacheWidth(context, 26),
                          cacheHeight: sideQuestCacheWidth(context, 26),
                        )
                      : null,
                  child:
                      (profilePicture == null || profilePicture.trim().isEmpty)
                      ? Text(
                          (displayName.trim().isNotEmpty
                                  ? displayName.trim()[0]
                                  : 'U')
                              .toUpperCase(),
                          style: _inter.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _inter.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (isWinner)
                  const Icon(
                    Icons.emoji_events,
                    size: 16,
                    color: Color(0xFF7CFF4D),
                  ),
              ],
            ),
          ),
          if (photo != null)
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LivePhotoFeedMedia(
                      stillUrl: (photo['url'] ?? '').toString(),
                      attachment: LivePhotoPostAttachment.fromPostMap(photo),
                      preloadVideo: false,
                      onTap: () =>
                          _openPhotoPreview((photo['url'] ?? '').toString()),
                      fit: BoxFit.cover,
                      cacheWidth: sideQuestCacheWidth(context, 300),
                      cacheHeight: sideQuestCacheWidth(context, 220),
                      filterQuality: FilterQuality.low,
                      errorWidget: Container(
                        color: const Color(0xFF121212),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.broken_image_outlined,
                          color: Color(0xFFAAAAAA),
                          size: 24,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: ListenableBuilder(
                        listenable: _likeRevision,
                        builder: (context, _) {
                          return GestureDetector(
                            onTap: () => toggleLike(
                              (photo['id'] ?? '').toString(),
                              photo['is_liked'] == true,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.58),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  LikeAnimation(
                                    isAnimating:
                                        _animatingLikePhotoId == photo['id'],
                                    child: Icon(
                                      (photo['is_liked'] ?? false)
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: (photo['is_liked'] ?? false)
                                          ? Colors.red
                                          : Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    (photo['likes_count'] ?? 0).toString(),
                                    style: _inter.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(14),
                  ),
                  color: Color(0xFF111111),
                ),
                alignment: Alignment.center,
                child: Text(
                  t('Kein Foto gepostet', 'No photo posted'),
                  textAlign: TextAlign.center,
                  style: _inter.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFAAAAAA),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPvpDuelCard(Map<String, dynamic> duel, String currentUserId) {
    final challengerId = (duel['challenger_id'] ?? '').toString();
    final challengedId = (duel['challenged_id'] ?? '').toString();
    final challengerName =
        (duel['challenger_username'] ?? t('Unbekannt', 'Unknown')).toString();
    final challengedName =
        (duel['challenged_username'] ?? t('Unbekannt', 'Unknown')).toString();
    final winnerId = (duel['challenge_winner_id'] ?? '').toString();
    final completedAt = (duel['challenge_completed_at'] ?? '')
        .toString()
        .trim();
    final challengerPhoto = duel['challenger_photo'] as Map<String, dynamic>?;
    final challengedPhoto = duel['challenged_photo'] as Map<String, dynamic>?;
    final isResolved = completedAt.isNotEmpty;
    final challengerPhotoId = (challengerPhoto?['id'] ?? '').toString();
    final challengedPhotoId = (challengedPhoto?['id'] ?? '').toString();
    final linkedPhotoIds = <String>[
      if (challengerPhotoId.isNotEmpty) challengerPhotoId,
      if (challengedPhotoId.isNotEmpty) challengedPhotoId,
    ];
    final postTargetPhotoId = challengerPhotoId.isNotEmpty
        ? challengerPhotoId
        : challengedPhotoId;
    final duelComments = <Map<String, dynamic>>[
      ...((challengerPhoto?['comments'] as List?) ?? const []).map(
        (c) => Map<String, dynamic>.from(c),
      ),
      ...((challengedPhoto?['comments'] as List?) ?? const []).map(
        (c) => Map<String, dynamic>.from(c),
      ),
    ];
    duelComments.sort(
      (a, b) => (a['created_at'] ?? '').toString().compareTo(
        (b['created_at'] ?? '').toString(),
      ),
    );

    String statusText;
    Color statusColor;
    if (!isResolved) {
      statusText = t(
        'Voting läuft bis zur nächsten Daily Quest',
        'Voting runs until the next Daily Quest',
      );
      statusColor = const Color(0xFFAAAAAA);
    } else if (winnerId.isEmpty) {
      statusText = t('Unentschieden', 'Draw');
      statusColor = Colors.orange.shade300;
    } else if (winnerId == challengerId) {
      statusText = t('Gewinner: $challengerName', 'Winner: $challengerName');
      statusColor = const Color(0xFF7CFF4D);
    } else {
      statusText = t('Gewinner: $challengedName', 'Winner: $challengedName');
      statusColor = const Color(0xFF7CFF4D);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 4,
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.orange, width: 1.1),
                  ),
                  child: Text(
                    t('Duell', 'Duel'),
                    style: _inter.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.orange.shade300,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _inter.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              (duel['challenge_description'] ?? '').toString(),
              style: _inter.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: Row(
                children: [
                  Expanded(
                    child: _buildPvpParticipantTile(
                      userId: challengerId,
                      username: challengerName,
                      profilePicture: duel['challenger_profile_picture']
                          ?.toString(),
                      photo: challengerPhoto,
                      isWinner: winnerId.isNotEmpty && winnerId == challengerId,
                      currentUserId: currentUserId,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildPvpParticipantTile(
                      userId: challengedId,
                      username: challengedName,
                      profilePicture: duel['challenged_profile_picture']
                          ?.toString(),
                      photo: challengedPhoto,
                      isWinner: winnerId.isNotEmpty && winnerId == challengedId,
                      currentUserId: currentUserId,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: linkedPhotoIds.isNotEmpty
                        ? () => showCommentsBottomSheet(
                            context,
                            postTargetPhotoId,
                            duelComments,
                            linkedPhotoIds: linkedPhotoIds,
                            postTargetPhotoId: postTargetPhotoId,
                          )
                        : null,
                    child: Row(
                      children: [
                        ThoughtBubbleIcon(
                          color: linkedPhotoIds.isNotEmpty
                              ? Colors.white70
                              : const Color(0xFF777777),
                          size: 28,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          duelComments.length.toString(),
                          style: _inter.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: linkedPhotoIds.isNotEmpty
                                ? Colors.white
                                : const Color(0xFF777777),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (duelComments.isNotEmpty)
              ListenableBuilder(
                listenable: _likeRevision,
                builder: (context, _) {
                  final previewComments = _previewCommentsForDuel(duel);
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ...List.generate(
                          previewComments.length > 2
                              ? 2
                              : previewComments.length,
                          (index) {
                            if (index < 0 || index >= previewComments.length) {
                              return const SizedBox.shrink();
                            }
                            final c = previewComments[index];

                            try {
                              final commenterName =
                                  c['users_profile']?['username'] ?? 'Unknown';
                              final commentText = c['message'] ?? '';
                              final commentId = c['id'] ?? '';
                              final commentPhotoId =
                                  (c['photo_id'] ?? postTargetPhotoId)
                                      .toString();
                              final commentLikesCount = c['likes_count'] ?? 0;
                              final isCommentLiked = c['is_liked'] ?? false;

                              if (commentId.toString().isEmpty) {
                                return const SizedBox.shrink(); // Broken row without id.
                              }

                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPress: () => _showCommentActions(
                                  Map<String, dynamic>.from(c as Map),
                                  photoId: commentPhotoId,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onDoubleTap: () {
                                            if (isCommentLiked != true) {
                                              toggleCommentLike(
                                                commentId.toString(),
                                                false,
                                              );
                                            }
                                          },
                                          child: RichText(
                                            text: TextSpan(
                                              children: [
                                                TextSpan(
                                                  text: '$commenterName: ',
                                                  style: _inter.copyWith(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                TextSpan(
                                                  text: commentText.toString(),
                                                  style: _inter.copyWith(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w400,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () => toggleCommentLike(
                                          commentId.toString(),
                                          isCommentLiked == true,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              isCommentLiked == true
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              color: isCommentLiked == true
                                                  ? Colors.red
                                                  : const Color(0xFFAAAAAA),
                                              size: 14,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              commentLikesCount.toString(),
                                              style: _inter.copyWith(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: const Color(0xFFAAAAAA),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (c['user_id'] == currentUserId) ...[
                                        const SizedBox(width: 8),
                                        GestureDetector(
                                          onTap: () {
                                            if (commentPhotoId.isNotEmpty) {
                                              deleteComment(
                                                commentId.toString(),
                                                commentPhotoId,
                                              );
                                            }
                                          },
                                          child: const Icon(
                                            Icons.delete_outline,
                                            size: 14,
                                            color: Color(0xFFAAAAAA),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            } catch (e) {
                              AppLogger.debug(
                                'Error rendering PvP comment: $e, Comment data: $c',
                              );
                              // Skip a broken comment instead of showing the raw error.
                              return const SizedBox.shrink();
                            }
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyCollabCard(
    Map<String, dynamic> entry,
    String currentUserId, {
    required Color cardDark,
    required Color textPrimary,
    required Color textSecondary,
    required Color accentGreen,
  }) {
    final baseRaw = entry['base_photo'];
    if (baseRaw is! Map) return const SizedBox.shrink();
    final basePhoto = baseRaw as Map<String, dynamic>;
    final baseId = (basePhoto['id'] ?? '').toString();
    if (baseId.isEmpty) return const SizedBox.shrink();

    final extensions = ((entry['extensions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final pageCount = 1 + extensions.length;

    var targetPage = _collabPageByBaseId[baseId] ?? 0;
    var clampedPage = false;
    if (targetPage < 0 || targetPage >= pageCount) {
      targetPage = 0;
      _collabPageByBaseId[baseId] = 0;
      clampedPage = true;
    }
    final pageController = _collabPageControllerFor(baseId, targetPage);
    if (clampedPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncCollabPageController(baseId, targetPage);
      });
    }
    final currentPage = pageController.hasClients
        ? ((pageController.page?.round() ?? targetPage)
              .clamp(0, pageCount - 1)
              .toInt())
        : targetPage;

    final activePost = currentPage == 0
        ? basePhoto
        : extensions[currentPage - 1];
    final activePostId = (activePost['id'] ?? '').toString();
    final activeComments = _previewCommentsForPost(activePost);

    final canContribute = _canContributeToBase(
      basePhoto,
      extensions,
      currentUserId,
    );
    final isUploadingThis = _collabUploadingBaseId == baseId;

    String timeTextFor(Map<String, dynamic> post) {
      final createdAtUtc = parseUtcTimestamp(post['created_at']);
      if (createdAtUtc == null) return '';
      return postTimeLabel(createdAtUtc, isLate: post['is_late'] == true);
    }

    Widget halfPhoto(
      Map<String, dynamic>? post, {
      required BorderRadius borderRadius,
    }) {
      final imageUrl = (post?['url'] ?? '').toString().trim();
      if (imageUrl.isEmpty) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: borderRadius,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.image_not_supported_outlined,
            color: Color(0xFF8A8A8A),
            size: 24,
          ),
        );
      }
      return LivePhotoFeedMedia(
        stillUrl: imageUrl,
        attachment: LivePhotoPostAttachment.fromPostMap(post ?? const {}),
        preloadVideo: false,
        onTap: () => _openPhotoPreview(imageUrl),
        borderRadius: borderRadius,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        cacheWidth: sideQuestCacheWidth(context, 240),
        cacheHeight: sideQuestCacheWidth(context, 240),
        filterQuality: FilterQuality.low,
        errorWidget: Container(
          color: const Color(0xFF171717),
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_outlined,
            color: Color(0xFF8A8A8A),
            size: 24,
          ),
        ),
      );
    }

    Widget baseLeftSplitHalf({required BorderRadius borderRadius}) {
      final imageUrl = (basePhoto['url'] ?? '').toString().trim();
      if (imageUrl.isEmpty) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: borderRadius,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.image_not_supported_outlined,
            color: Color(0xFF8A8A8A),
            size: 24,
          ),
        );
      }
      return GestureDetector(
        onTap: () => _openPhotoPreview(imageUrl),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              if (w <= 0 || h <= 0) {
                return Container(color: const Color(0xFF171717));
              }
              return ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: w * 2,
                  maxWidth: w * 2,
                  minHeight: h,
                  maxHeight: h,
                  child: sideQuestNetworkImage(
                    imageUrl: imageUrl,
                    width: w * 2,
                    height: h,
                    fit: BoxFit.cover,
                    alignment: Alignment.centerLeft,
                    filterQuality: FilterQuality.low,
                    cacheWidth: sideQuestCacheWidth(context, w * 2),
                    cacheHeight: sideQuestCacheWidth(context, h),
                    errorWidget: Container(
                      width: w * 2,
                      height: h,
                      color: const Color(0xFF171717),
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: w,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.broken_image_outlined,
                          color: Color(0xFF8A8A8A),
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    final activeUserId = (activePost['user_id'] ?? '').toString();
    final activeUsername = (activePost['username'] ?? 'Unknown').toString();
    final activePicture = activePost['profile_picture']?.toString();
    final baseUserId = (basePhoto['user_id'] ?? '').toString();
    final baseUsername = (basePhoto['username'] ?? 'Unknown').toString();
    final basePicture = basePhoto['profile_picture']?.toString();
    final isCreationView = currentPage > 0;

    String displayNameFor(String userId, String username) {
      final safeUsername = username.trim().isEmpty
          ? 'Unknown'
          : username.trim();
      if (userId == currentUserId) {
        return '$safeUsername (${t('Du', 'You')})';
      }
      return safeUsername;
    }

    Widget buildProfileAvatar(
      String? picture,
      String username, {
      required double radius,
      double fontSize = 14,
    }) {
      final safeUsername = username.trim().isEmpty
          ? 'Unknown'
          : username.trim();
      final initial = safeUsername[0].toUpperCase();
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.black,
        backgroundImage: (picture != null && picture.isNotEmpty)
            ? sideQuestCachedImageProvider(
                picture,
                cacheWidth: sideQuestCacheWidth(context, radius * 2),
                cacheHeight: sideQuestCacheWidth(context, radius * 2),
              )
            : null,
        child: (picture == null || picture.isEmpty)
            ? Text(
                initial,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: fontSize,
                ),
              )
            : null,
      );
    }

    Widget buildHeaderAvatar() {
      final activeAvatar = buildProfileAvatar(
        activePicture,
        activeUsername,
        radius: isCreationView ? 16 : 20,
        fontSize: isCreationView ? 12 : 16,
      );

      if (!isCreationView) {
        return activeAvatar;
      }

      return SizedBox(
        width: 52,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 3,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: 1.1,
                  ),
                ),
                child: buildProfileAvatar(
                  basePicture,
                  baseUsername,
                  radius: 16,
                  fontSize: 12,
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: cardDark,
                  shape: BoxShape.circle,
                ),
                child: activeAvatar,
              ),
            ),
          ],
        ),
      );
    }

    final headerTitle = isCreationView
        ? t(
            '${displayNameFor(baseUserId, baseUsername)} und ${displayNameFor(activeUserId, activeUsername)}',
            '${displayNameFor(baseUserId, baseUsername)} and ${displayNameFor(activeUserId, activeUsername)}',
          )
        : displayNameFor(activeUserId, activeUsername);
    final isOwnPost = activeUserId == currentUserId;
    final flamesValue =
        ((isOwnPost && currentUserProfile != null
                    ? currentUserProfile!['flames']
                    : activePost['flames']) as num? ??
                0)
            .toInt();
    final puzzleFlames =
        ((activePost['collab_pair_streak'] as num?)?.toInt() ?? 1).clamp(
          1,
          999,
        );

    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 4,
      color: cardDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (activeUserId.isNotEmpty) {
                      if (activeUserId == currentUserId) {
                        widget.onOpenOwnProfile?.call();
                        return;
                      }
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProfileScreen(userId: activeUserId),
                        ),
                      );
                      return;
                    }

                    showProfilePictureDialog(
                      context,
                      activePicture,
                      activeUsername,
                    );
                  },
                  child: buildHeaderAvatar(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _inter.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: textPrimary,
                        ),
                      ),
                      Text(
                        timeTextFor(activePost),
                        style: _inter.copyWith(
                          fontSize: 12,
                          color: activePost['is_late'] == true
                              ? Colors.orange.shade700
                              : textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<_PostActionMenuValue>(
                  color: cardDark,
                  icon: const Icon(Icons.more_vert, color: Color(0xFFAAAAAA)),
                  onSelected: (action) => _handlePostAction(
                    action,
                    photoId: activePostId,
                    reportedUserId: activeUserId,
                  ),
                  itemBuilder: (context) =>
                      _buildPostMenuItems(activeUserId == currentUserId),
                ),
              ],
            ),
          ),
          if (((activePost['post_description'] ?? '').toString().trim())
              .isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: 12.0,
                right: 12.0,
                bottom: 8,
              ),
              child: MentionText(
                text: (activePost['post_description'] ?? '').toString(),
                style: _inter.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: textPrimary,
                ),
                mentionStyle: _inter.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: appGreen,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                enableProfileNavigation: true,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 12.0, right: 12.0, bottom: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: accentGreen.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: accentGreen.withValues(alpha: 0.7),
                    ),
                  ),
                  child: Text(
                    currentPage == 0
                        ? t(
                            extensions.length >= 2
                                ? 'Kombi'
                                : 'Kombi offen ${extensions.length}/2',
                            extensions.length >= 2
                                ? 'Combo'
                                : 'Combo open ${extensions.length}/2',
                          )
                        : t(
                            'Kreation $currentPage/${pageCount - 1}',
                            'Creation $currentPage/${pageCount - 1}',
                          ),
                    style: _inter.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: accentGreen,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (currentPage > 0)
                  Expanded(
                    child: Text(
                      t(
                        'Ergänzt von ${displayNameFor(activeUserId, activeUsername)}',
                        'Completed by ${displayNameFor(activeUserId, activeUsername)}',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _inter.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12.0, right: 12.0, bottom: 8),
            child: Row(
              children: [
                if (isCreationView)
                  Text('🧩', style: _inter.copyWith(fontSize: 16))
                else
                  StreakFlameIcon(
                    flames: flamesValue,
                    size: 18,
                  ),
                const SizedBox(width: 6),
                Text(
                  isCreationView ? '$puzzleFlames' : '$flamesValue',
                  style: _inter.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 290,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Listener(
                      // Track press start/end for the friend-likes overlay
                      // without intercepting PageView swipes or photo taps.
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) {
                        if (activePostId.isNotEmpty) {
                          _photoPressNotifierFor(activePostId).value = true;
                        }
                      },
                      onPointerUp: (_) {
                        if (activePostId.isNotEmpty) {
                          _photoPressNotifierFor(activePostId).value = false;
                        }
                      },
                      onPointerCancel: (_) {
                        if (activePostId.isNotEmpty) {
                          _photoPressNotifierFor(activePostId).value = false;
                        }
                      },
                      child: PageView.builder(
                      controller: pageController,
                      itemCount: pageCount,
                      onPageChanged: (value) {
                        _setCollabPage(baseId, value, syncController: false);
                      },
                      itemBuilder: (context, pageIndex) {
                        if (pageIndex == 0) {
                          return KeyedSubtree(
                            key: ValueKey('daily_collab_${baseId}_base'),
                            child: halfPhoto(
                              basePhoto,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          );
                        }

                        final extension = extensions[pageIndex - 1];
                        final extensionId = (extension['id'] ?? '')
                            .toString()
                            .trim();
                        return KeyedSubtree(
                          key: ValueKey(
                            'daily_collab_${baseId}_${extensionId}_$pageIndex',
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: baseLeftSplitHalf(
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(20),
                                    bottomLeft: Radius.circular(20),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: halfPhoto(
                                  extension,
                                  borderRadius: const BorderRadius.only(
                                    topRight: Radius.circular(20),
                                    bottomRight: Radius.circular(20),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    ),
                  ),
                  // Friend-likes overlay — bottom-left so it doesn't collide
                  // with the page indicator dots (bottom-center) or the
                  // contribute button (bottom-right). Tappable: opens the
                  // full likers list.
                  if (activePostId.isNotEmpty)
                    Positioned(
                      left: 14,
                      bottom: 12,
                      child: FriendLikesPreview(
                        photoId: activePostId,
                        hiddenListenable: _photoPressNotifierFor(
                          activePostId,
                        ),
                      ),
                    ),
                  if (pageCount > 1)
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(pageCount, (dotIndex) {
                          final active = dotIndex == currentPage;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: active ? 18 : 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: active
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          );
                        }),
                      ),
                    ),
                  if (currentPage == 0 && canContribute)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: GestureDetector(
                        onTap: isUploadingThis
                            ? null
                            : () => _captureCollabExtension(
                                basePhoto,
                                extensions,
                              ),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: accentGreen,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: accentGreen.withValues(alpha: 0.45),
                                blurRadius: 14,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Center(
                            child: isUploadingThis
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: Colors.black,
                                    ),
                                  )
                                : const Icon(
                                    Icons.add,
                                    color: Colors.black,
                                    size: 28,
                                  ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                ListenableBuilder(
                  listenable: _likeRevision,
                  builder: (context, _) {
                    final likeCount =
                        (activePost['likes_count'] ?? 0) as int;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: activePostId.isEmpty
                              ? null
                              : () => toggleLike(
                                  activePostId,
                                  activePost['is_liked'] ?? false,
                                ),
                          child: LikeAnimation(
                            isAnimating: _animatingLikePhotoId == activePostId,
                            child: Icon(
                              (activePost['is_liked'] ?? false)
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: (activePost['is_liked'] ?? false)
                                  ? Colors.red
                                  : textPrimary,
                              size: 28,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: (activePostId.isEmpty || likeCount == 0)
                              ? null
                              : () => showLikersBottomSheet(
                                  context,
                                  activePostId,
                                  onOpenOwnProfile: widget.onOpenOwnProfile,
                                ),
                          child: Text(
                            likeCount.toString(),
                            style: _inter.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  onTap: activePostId.isEmpty
                      ? null
                      : () => showCommentsBottomSheet(
                          context,
                          activePostId,
                          activeComments,
                        ),
                  child: Row(
                    children: [
                      const ThoughtBubbleIcon(color: Colors.white70, size: 28),
                      const SizedBox(width: 6),
                      Text(
                        _commentCountForPost(activePost).toString(),
                        style: _inter.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (activeComments.isNotEmpty)
            ListenableBuilder(
              listenable: _likeRevision,
              builder: (context, _) {
                final previewComments = _previewCommentsForPost(activePost);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...List.generate(
                        previewComments.length > 2 ? 2 : previewComments.length,
                        (index) {
                          final c = previewComments[index];
                          try {
                            final commenterName =
                                c['users_profile']?['username'] ?? 'Unknown';
                            final commentText = c['message'] ?? '';
                            final commentId = (c['id'] ?? '').toString();
                            final commentLikesCount = c['likes_count'] ?? 0;
                            final isCommentLiked = c['is_liked'] ?? false;

                            if (commentId.isEmpty) {
                              return const SizedBox.shrink(); // Broken row without id.
                            }

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPress: () => _showCommentActions(
                                Map<String, dynamic>.from(c as Map),
                                photoId: activePostId,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onDoubleTap: () {
                                          if (isCommentLiked != true) {
                                            toggleCommentLike(commentId, false);
                                          }
                                        },
                                        child: RichText(
                                          text: TextSpan(
                                            children: [
                                              TextSpan(
                                                text: '$commenterName: ',
                                                style: _inter.copyWith(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: textPrimary,
                                                ),
                                              ),
                                              TextSpan(
                                                text: commentText.toString(),
                                                style: _inter.copyWith(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w400,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    GestureDetector(
                                      onTap: () => toggleCommentLike(
                                        commentId,
                                        isCommentLiked == true,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            isCommentLiked == true
                                                ? Icons.favorite
                                                : Icons.favorite_border,
                                            color: isCommentLiked == true
                                                ? Colors.red
                                                : textSecondary,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            commentLikesCount.toString(),
                                            style: _inter.copyWith(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (c['user_id'] == currentUserId) ...[
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () => deleteComment(
                                          commentId,
                                          activePostId,
                                        ),
                                        child: const Icon(
                                          Icons.delete_outline,
                                          size: 14,
                                          color: Color(0xFFAAAAAA),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          } catch (e) {
                            AppLogger.debug(
                              'Error rendering collab comment: $e, Comment data: $c',
                            );
                            // Skip a broken comment instead of showing the raw error.
                            return const SizedBox.shrink();
                          }
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> toggleLike(String photoId, bool isLiked) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      if (isLiked) {
        // Optimistic UI update: immediately reflect unlike.
        final photoIndex = cachedPhotos.indexWhere((p) => p['id'] == photoId);
        final previousCount = photoIndex != -1
            ? (cachedPhotos[photoIndex]['likes_count'] ?? 0) as int
            : null;

        if (photoIndex != -1) {
          cachedPhotos[photoIndex]['is_liked'] = false;
          final current = (cachedPhotos[photoIndex]['likes_count'] ?? 0) as int;
          cachedPhotos[photoIndex]['likes_count'] = current > 0
              ? current - 1
              : 0;
        }
        _likeRevision.value++;

        try {
          await client
              .from("likes")
              .delete()
              .eq("photo_id", photoId)
              .eq("user_id", userId);
        } catch (_) {
          if (mounted && photoIndex != -1 && previousCount != null) {
            cachedPhotos[photoIndex]['is_liked'] = true;
            cachedPhotos[photoIndex]['likes_count'] = previousCount;
            _likeRevision.value++;
          }
          rethrow;
        }
      } else {
        // Update UI immediately before sending request (optimistic update)
        _animatingLikePhotoId = photoId;
        final photoIndex = cachedPhotos.indexWhere((p) => p['id'] == photoId);
        if (photoIndex != -1) {
          cachedPhotos[photoIndex]['is_liked'] = true;
          cachedPhotos[photoIndex]['likes_count'] =
              (cachedPhotos[photoIndex]['likes_count'] ?? 0) + 1;
        }
        _likeRevision.value++;

        try {
          await client.from("likes").insert({
            "photo_id": photoId,
            "user_id": userId,
            "created_at": DateTime.now().toIso8601String(),
          });
        } catch (likeError) {
          // Ignore duplicate key errors – not a real failure.
        } finally {
          if (mounted) {
            _animatingLikePhotoId = null;
            _likeRevision.value++;
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.describe(
              e,
              whatDe: "Fehler beim Like",
              whatEn: "Error liking",
            )),
          ),
        );
      }
    }
  }

  Future<void> showCommentsBottomSheet(
    BuildContext context,
    String photoId,
    List<dynamic> comments, {
    List<String>? linkedPhotoIds,
    String? postTargetPhotoId,
    String? highlightCommentId,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (context, sheetScrollController) => CommentsBottomSheet(
          photoId: photoId,
          photoIds: linkedPhotoIds,
          postTargetPhotoId: postTargetPhotoId,
          scrollController: sheetScrollController,
          highlightCommentId: highlightCommentId,
          initialComments: comments
              .map((c) => Map<String, dynamic>.from(c))
              .toList(),
        ),
      ),
    );
  }

  Future<void> toggleCommentLike(String commentId, bool isLiked) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    if (commentId.isEmpty || !_commentLikeInFlightIds.add(commentId)) return;

    // Optimistic update: reflect in UI immediately
    _updateCommentLikeInFeed(commentId, isLiked);

    try {
      await sideQuestPersistCommentLike(
        client: client,
        commentId: commentId,
        userId: userId,
        shouldLike: !isLiked,
      );
    } catch (e) {
      // Revert optimistic update on failure
      if (mounted) {
        _updateCommentLikeInFeed(commentId, !isLiked);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
    } finally {
      _commentLikeInFlightIds.remove(commentId);
    }
  }

  /// Updates a comment's like state in the local feed data without server round-trip.
  void _updateCommentLikeInFeed(String commentId, bool wasLiked) {
    if (!mounted || commentId.isEmpty) return;

    var updated = false;
    setState(() {
      for (final photo in cachedPhotos) {
        if (_applyCommentLikeToPhoto(photo, commentId, wasLiked)) {
          updated = true;
          break;
        }
      }
      if (updated) {
        _storeFeedData(cachedPhotos);
      }
    });

    if (updated) {
      _likeRevision.value++;
    }
  }

  void _showFeedSnackBar(String de, String en) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t(de, en))));
  }

  Future<void> _confirmDeletePhoto(String photoId) async {
    if (photoId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Post löschen?', 'Delete post?')),
        content: Text(
          t('Dieser Post wird entfernt.', 'This post will be removed.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('Abbrechen', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('Löschen', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await deletePhoto(photoId);
    }
  }

  Future<bool> _confirmReportDialog({
    required String titleDe,
    required String titleEn,
    required String messageDe,
    required String messageEn,
  }) async {
    if (!mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t(titleDe, titleEn),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(messageDe, messageEn),
          style: _inter.copyWith(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: _inter.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t('Melden', 'Report'),
              style: _inter.copyWith(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _reportPhoto(String photoId, {String? reportedUserId}) async {
    if (photoId.isEmpty) return;
    final confirmed = await _confirmReportDialog(
      titleDe: 'Post melden?',
      titleEn: 'Report post?',
      messageDe: 'Bist du sicher, dass du diesen Post melden möchtest?',
      messageEn: 'Are you sure that you want to report this post?',
    );
    if (!confirmed) return;

    try {
      final result = await ReportService.submit(
        client: Supabase.instance.client,
        targetType: ReportTargetType.photo,
        photoId: photoId,
        reportedUserId: reportedUserId,
      );
      if (result == ReportSubmissionResult.alreadyReported) {
        _showFeedSnackBar(
          'Du hast diesen Post bereits gemeldet',
          'You already reported this post',
        );
      } else {
        _showFeedSnackBar('Post gemeldet', 'Post reported');
      }
    } catch (e) {
      AppLogger.debug('Error reporting photo: $e');
      _showFeedSnackBar(
        'Melden des Posts fehlgeschlagen',
        'Reporting the post failed',
      );
    }
  }

  Future<void> _reportComment(
    String commentId, {
    required String photoId,
    String? reportedUserId,
  }) async {
    if (commentId.isEmpty) return;
    final confirmed = await _confirmReportDialog(
      titleDe: 'Kommentar melden?',
      titleEn: 'Report comment?',
      messageDe: 'Bist du sicher, dass du diesen Kommentar melden möchtest?',
      messageEn: 'Are you sure that you want to report this comment?',
    );
    if (!confirmed) return;

    try {
      final result = await ReportService.submit(
        client: Supabase.instance.client,
        targetType: ReportTargetType.comment,
        photoId: photoId,
        commentId: commentId,
        reportedUserId: reportedUserId,
      );
      if (result == ReportSubmissionResult.alreadyReported) {
        _showFeedSnackBar(
          'Du hast diesen Kommentar bereits gemeldet',
          'You already reported this comment',
        );
      } else {
        _showFeedSnackBar('Kommentar gemeldet', 'Comment reported');
      }
    } catch (e) {
      AppLogger.debug('Error reporting comment: $e');
      _showFeedSnackBar(
        'Melden des Kommentars fehlgeschlagen',
        'Reporting the comment failed',
      );
    }
  }

  Future<void> _showCommentActions(
    Map<String, dynamic> comment, {
    required String photoId,
  }) async {
    final commentId = (comment['id'] ?? '').toString();
    if (commentId.isEmpty || !mounted) return;

    final isOwnComment =
        comment['user_id'] == Supabase.instance.client.auth.currentUser?.id;
    final action = await showModalBottomSheet<_CommentActionMenuValue>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: Colors.orangeAccent,
                ),
                title: Text(
                  t('Kommentar melden', 'Report comment'),
                  style: _inter.copyWith(color: Colors.white),
                ),
                onTap: () =>
                    Navigator.pop(sheetContext, _CommentActionMenuValue.report),
              ),
              if (isOwnComment)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    t('Kommentar löschen', 'Delete comment'),
                    style: _inter.copyWith(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _CommentActionMenuValue.delete,
                  ),
                ),
            ],
          ),
        );
      },
    );

    if (action == null || !mounted) return;
    if (action == _CommentActionMenuValue.delete) {
      await deleteComment(commentId, photoId);
      return;
    }
    await _reportComment(
      commentId,
      photoId: photoId,
      reportedUserId: (comment['user_id'] ?? '').toString(),
    );
  }

  List<PopupMenuEntry<_PostActionMenuValue>> _buildPostMenuItems(bool isOwn) {
    return [
      PopupMenuItem<_PostActionMenuValue>(
        value: _PostActionMenuValue.report,
        child: Row(
          children: [
            const Icon(Icons.flag_outlined, color: Colors.orangeAccent),
            const SizedBox(width: 10),
            Text(
              t('Melden', 'Report'),
              style: _inter.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
      if (isOwn)
        PopupMenuItem<_PostActionMenuValue>(
          value: _PostActionMenuValue.delete,
          child: Row(
            children: [
              const Icon(Icons.delete_outline, color: Colors.redAccent),
              const SizedBox(width: 10),
              Text(
                t('Löschen', 'Delete'),
                style: _inter.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
    ];
  }

  Future<void> _handlePostAction(
    _PostActionMenuValue action, {
    required String photoId,
    String? reportedUserId,
  }) async {
    if (action == _PostActionMenuValue.delete) {
      await _confirmDeletePhoto(photoId);
      return;
    }
    await _reportPhoto(photoId, reportedUserId: reportedUserId);
  }

  Future<void> deleteComment(String commentId, String photoId) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    if (commentId.isEmpty) return;

    try {
      await client
          .from("comments")
          .delete()
          .eq("id", commentId)
          .eq("user_id", userId);

      final updatedFeed = await loadTodayFeed();
      if (mounted) {
        setState(() {
          _storeFeedData(updatedFeed);
          _feedFuture = Future.value(updatedFeed);
        });
      }
    } catch (e) {
      AppLogger.debug("Error deleting comment: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t("Fehler beim Löschen", "Error deleting"))),
        );
      }
    }
  }

  Future<void> deletePhoto(String photoId) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || photoId.isEmpty) return;

    try {
      // Fetch photo first to confirm ownership and capture its files
      Map<String, dynamic>? photoRow;

      try {
        photoRow = await client
            .from('photos')
            .select(
              'url, thumb_url, live_photo_clip_path, is_challenge_photo, challenge_id',
            )
            .eq('id', photoId)
            .eq('user_id', userId)
            .maybeSingle();
      } catch (selectError) {
        // If is_challenge_photo or challenge_id columns don't exist, try without them
        AppLogger.debug(
          'Error selecting with challenge columns, trying without: $selectError',
        );
        photoRow = await client
            .from('photos')
            .select('url')
            .eq('id', photoId)
            .eq('user_id', userId)
            .maybeSingle();
      }

      if (photoRow == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t('Post nicht gefunden', 'Post not found'))),
          );
        }
        return;
      }

      // Image, thumbnail and live clip (the clip used to stay behind).
      final storagePaths = postStoragePaths(photoRow);

      // Clean up related data (best-effort)
      try {
        await client.from('comment_likes').delete().eq('photo_id', photoId);
      } catch (e) {
        AppLogger.debug('comment_likes cleanup failed: $e');
      }
      await client.from('comments').delete().eq('photo_id', photoId);
      await client.from('likes').delete().eq('photo_id', photoId);

      await client
          .from('photos')
          .delete()
          .eq('id', photoId)
          .eq('user_id', userId);

      // Remove from storage after DB delete
      if (storagePaths.isNotEmpty) {
        try {
          await client.storage.from('photos').remove(storagePaths);
        } catch (storageError) {
          AppLogger.debug('Fehler beim Löschen der Speicherdatei: $storageError');
        }
      }

      final updatedFeed = await loadTodayFeed();
      if (mounted) {
        setState(() {
          _storeFeedData(updatedFeed);
          _feedFuture = Future.value(updatedFeed);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Post gelöscht', 'Post deleted'))),
        );
      }
    } catch (e) {
      AppLogger.debug('Fehler beim Löschen des Fotos: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Löschen', 'Error deleting'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id ?? '';
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        centerTitle: false,
        titleSpacing: 20,
        title: Text(
          t("Heute", "Today"),
          style: _inter.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: NotificationInboxButton(iconColor: textPrimary),
          ),
        ],
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: feedFilter == 'daily'
                          ? accentGreen
                          : cardDark,
                      side: BorderSide(
                        color: feedFilter == 'daily'
                            ? accentGreen
                            : const Color(0xFF2A2A2A),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => setState(() {
                      feedFilter = 'daily';
                    }),
                    child: Text(
                      t('Daily Quest', 'Daily Quest'),
                      style: _inter.copyWith(
                        color: feedFilter == 'daily'
                            ? Colors.black
                            : textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: feedFilter == 'pvp'
                          ? accentGreen
                          : cardDark,
                      side: BorderSide(
                        color: feedFilter == 'pvp'
                            ? accentGreen
                            : const Color(0xFF2A2A2A),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => setState(() {
                      feedFilter = 'pvp';
                    }),
                    child: Text(
                      t('Duelle', 'Duels'),
                      style: _inter.copyWith(
                        color: feedFilter == 'pvp' ? Colors.black : textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshFeed,
              child: FutureBuilder(
                future: _feedFuture ??= loadTodayFeed(surfaceErrors: true),
                builder: (context, snapshot) {
                  Widget child;

                  // Match leaderboard behavior 1:1: show a loading state whenever the future is waiting.
                  // This makes pull-to-refresh feel "fresh" via AnimatedSwitcher.
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      (_showFullRefreshLoader || cachedPhotos.isEmpty)) {
                    final sw = MediaQuery.of(context).size.width;
                    child = ListView(
                      key: const ValueKey('feed_loading'),
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                      children: [
                        _feedSkeletonCard(sw),
                        _feedSkeletonCard(sw),
                        _feedSkeletonCard(sw),
                      ],
                    );
                  } else if (snapshot.hasError) {
                    child = ListView(
                      key: const ValueKey('feed_error'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 140),
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            t(
                              'Konnte nicht geladen werden – zum Aktualisieren nach unten ziehen.',
                              "Couldn't load – pull down to refresh.",
                            ),
                            textAlign: TextAlign.center,
                            style: _inter.copyWith(color: textSecondary),
                          ),
                        ),
                      ],
                    );
                  } else {
                    final displayItems = feedFilter == 'pvp'
                        ? _pvpFeedItems
                        : _dailyFeedItems;
                    _maybeApplyPendingPostFocusRequest(displayItems);
                    // All posts are in memory and the list builds lazily,
                    // so there is no paging (it rebuilt every built card
                    // every 6 posts while scrolling).
                    final visibleDisplayItems = displayItems;

                    final hasSuggestionsSlot = visibleDisplayItems.isNotEmpty;
                    // The mini-card only belongs in the daily feed — PvP is
                    // a separate game mode that doesn't share the daily quest
                    // prompt. Reserve slot 0 only when we'll actually render
                    // it; otherwise indices stay as they were.
                    final showMiniCard = feedFilter == 'daily';
                    final dailyQuestSlot = showMiniCard ? 1 : 0;
                    final suggestionsIndex =
                        (visibleDisplayItems.length >= 2 ? 2 : 1) +
                        dailyQuestSlot;

                    if (visibleDisplayItems.isEmpty) {
                      child = ListView(
                        key: const ValueKey('feed_empty'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                        children: [
                          if (showMiniCard) ...const [
                            RepaintBoundary(child: DailyQuestMiniCard()),
                            SizedBox(height: 44),
                          ],
                          Center(
                            child: Text(
                              feedFilter == 'daily'
                                  ? t(
                                      'Noch keine Daily-Fotos',
                                      'No daily photos yet',
                                    )
                                  : t(
                                      'Noch keine Duell-Fotos',
                                      'No duel photos yet',
                                    ),
                              style: _inter.copyWith(
                                fontSize: 16,
                                color: textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          FriendSuggestionsRail(
                            placement: 'feed_empty',
                            excludeUserIds: const {},
                            onOpenFriendsTab: widget.onOpenFriendsTab,
                            onOpenProfile: (userId) {
                              if (userId.isEmpty) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ProfileScreen(userId: userId),
                                ),
                              );
                            },
                          ),
                        ],
                      );
                    } else {
                      child = ScrollablePositionedList.builder(
                        key: const ValueKey('feed_list'),
                        itemScrollController: _feedItemScrollController,
                        itemPositionsListener: _feedItemPositionsListener,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                        itemCount:
                            dailyQuestSlot +
                            visibleDisplayItems.length +
                            (hasSuggestionsSlot ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (showMiniCard && i == 0) {
                            return const RepaintBoundary(
                              child: DailyQuestMiniCard(),
                            );
                          }
                          if (hasSuggestionsSlot && i == suggestionsIndex) {
                            return FriendSuggestionsRail(
                              placement: 'feed',
                              excludeUserIds: const {},
                              onOpenFriendsTab: widget.onOpenFriendsTab,
                              onOpenProfile: (userId) {
                                if (userId.isEmpty) return;
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ProfileScreen(userId: userId),
                                  ),
                                );
                              },
                            );
                          }

                          // Strip the leading mini-card slot, then strip the
                          // suggestions slot if it sits before this index.
                          final photoIndex =
                              hasSuggestionsSlot && i > suggestionsIndex
                              ? i - dailyQuestSlot - 1
                              : i - dailyQuestSlot;
                          final entry = visibleDisplayItems[photoIndex];

                          if (feedFilter == 'pvp' &&
                              (entry['_pvp_duel'] ?? false) == true) {
                            return FadeSlideIn(
                              key: ValueKey(_feedEntryKey(entry)),
                              duration: kDurationMedium,
                              curve: kCurveStandard,
                              offsetY: kSlideEntryOffset,
                              child: RepaintBoundary(
                                child: _buildPvpDuelCard(entry, currentUserId),
                              ),
                            );
                          }

                          if (feedFilter == 'daily' &&
                              (entry['_daily_collab'] ?? false) == true) {
                            return FadeSlideIn(
                              key: ValueKey(_feedEntryKey(entry)),
                              duration: kDurationMedium,
                              curve: kCurveStandard,
                              offsetY: kSlideEntryOffset,
                              child: RepaintBoundary(
                                child: _buildDailyCollabCard(
                                  entry,
                                  currentUserId,
                                  cardDark: cardDark,
                                  textPrimary: textPrimary,
                                  textSecondary: textSecondary,
                                  accentGreen: accentGreen,
                                ),
                              ),
                            );
                          }

                          final p = feedFilter == 'pvp'
                              ? ((entry['photo'] as Map<String, dynamic>?) ??
                                    entry)
                              : entry;

                          // Gestaffelte Einblend-Animation für flüssiges Erscheinen
                          return FadeSlideIn(
                            key: ValueKey(_feedEntryKey(entry)),
                            duration: kDurationMedium,
                            curve: kCurveStandard,
                            offsetY: kSlideEntryOffset,
                            child: RepaintBoundary(
                              child: Card(
                                margin: const EdgeInsets.only(bottom: 20),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                elevation: 4,
                                color: cardDark,
                                child: Column(
                                  // ...existing code...
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(12.0),
                                      child: Row(
                                        children: [
                                          GestureDetector(
                                            onTap: () {
                                              final userId = p['user_id']
                                                  ?.toString();
                                              if (userId != null &&
                                                  userId.isNotEmpty) {
                                                if (userId == currentUserId) {
                                                  widget.onOpenOwnProfile
                                                      ?.call();
                                                  return;
                                                }
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        ProfileScreen(
                                                          userId: userId,
                                                        ),
                                                  ),
                                                );
                                                return;
                                              }

                                              showProfilePictureDialog(
                                                context,
                                                p['profile_picture']
                                                    ?.toString(),
                                                p['username'] ?? 'Unknown',
                                              );
                                            },
                                            child: CircleAvatar(
                                              radius: 20,
                                              backgroundColor: Colors.black,
                                              backgroundImage:
                                                  p['profile_picture'] != null
                                                  ? sideQuestCachedImageProvider(
                                                      p['profile_picture'],
                                                      cacheWidth:
                                                          sideQuestCacheWidth(
                                                            context,
                                                            40,
                                                          ),
                                                      cacheHeight:
                                                          sideQuestCacheWidth(
                                                            context,
                                                            40,
                                                          ),
                                                    )
                                                  : null,
                                              child:
                                                  p['profile_picture'] == null
                                                  ? Text(
                                                      ((p['username'] ?? 'U')
                                                                  .toString()
                                                                  .trim()
                                                                  .isNotEmpty
                                                              ? (p['username'] ??
                                                                        'U')
                                                                    .toString()
                                                                    .trim()[0]
                                                              : 'U')
                                                          .toUpperCase(),
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    )
                                                  : null,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  p['user_id'] == currentUserId
                                                      ? '${p['username'] ?? 'Unknown'} (${t('Du', 'You')})'
                                                      : (p['username'] ??
                                                            'Unknown'),
                                                  style: _inter.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 16,
                                                    color: textPrimary,
                                                  ),
                                                ),
                                                Text(
                                                  () {
                                                    final createdAtUtc =
                                                        parseUtcTimestamp(
                                                          p['created_at'],
                                                        );
                                                    if (createdAtUtc == null) {
                                                      return '';
                                                    }
                                                    return postTimeLabel(
                                                      createdAtUtc,
                                                      isLate:
                                                          p['is_late'] == true,
                                                    );
                                                  }(),
                                                  style: _inter.copyWith(
                                                    fontSize: 12,
                                                    color: p['is_late'] == true
                                                        ? Colors.orange.shade700
                                                        : textSecondary,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const Spacer(),
                                          PopupMenuButton<_PostActionMenuValue>(
                                            color: cardDark,
                                            icon: const Icon(
                                              Icons.more_vert,
                                              color: Color(0xFFAAAAAA),
                                            ),
                                            onSelected: (action) =>
                                                _handlePostAction(
                                                  action,
                                                  photoId: (p['id'] ?? '')
                                                      .toString(),
                                                  reportedUserId:
                                                      (p['user_id'] ?? '')
                                                          .toString(),
                                                ),
                                            itemBuilder: (context) =>
                                                _buildPostMenuItems(
                                                  p['user_id'] == currentUserId,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 12.0,
                                        right: 12.0,
                                        bottom: 6,
                                      ),
                                      child: Builder(
                                        builder: (context) {
                                          final isOwnPost =
                                              p['user_id'] == currentUserId;
                                          final hasCurrentProfile =
                                              currentUserProfile != null;
                                          final flamesValue =
                                              ((isOwnPost && hasCurrentProfile
                                                              ? currentUserProfile!['flames']
                                                              : p['flames'])
                                                          as num? ??
                                                      0)
                                                  .toInt();

                                          return Row(
                                            children: [
                                              StreakFlameIcon(
                                                flames: flamesValue,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                '$flamesValue',
                                                style: _inter.copyWith(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: textPrimary,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                    if ((p['is_challenge_photo'] ?? false) ==
                                        true)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12.0,
                                          right: 12.0,
                                          bottom: 8,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.withValues(
                                              alpha: 0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: Colors.orange,
                                              width: 1.2,
                                            ),
                                          ),
                                          child: Text(
                                            t("Duell", "Duel"),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.orange.shade700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    if ((p['is_challenge_photo'] ?? false) ==
                                            true &&
                                        ((p['challenge_description'] ?? '')
                                            .toString()
                                            .trim()
                                            .isNotEmpty))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12.0,
                                          right: 12.0,
                                          bottom: 8,
                                        ),
                                        child: MentionText(
                                          text:
                                              (p['challenge_description'] ?? '')
                                                  .toString(),
                                          style: _inter.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: textPrimary,
                                          ),
                                          mentionStyle: _inter.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: appGreen,
                                          ),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          enableProfileNavigation: true,
                                        ),
                                      ),
                                    if (((p['post_description'] ?? '')
                                        .toString()
                                        .trim()
                                        .isNotEmpty))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12.0,
                                          right: 12.0,
                                          bottom: 8,
                                        ),
                                        child: MentionText(
                                          text: (p['post_description'] ?? '')
                                              .toString(),
                                          style: _inter.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: textPrimary,
                                          ),
                                          mentionStyle: _inter.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: appGreen,
                                          ),
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          enableProfileNavigation: true,
                                        ),
                                      ),
                                    if ((p['is_challenge_photo'] ?? false) ==
                                        true)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12.0,
                                          right: 12.0,
                                          bottom: 8,
                                        ),
                                        child: Builder(
                                          builder: (context) {
                                            try {
                                              final createdAtUtc =
                                                  parseUtcTimestamp(
                                                    p['created_at'],
                                                  );
                                              if (createdAtUtc == null) {
                                                return const SizedBox.shrink();
                                              }

                                              final expiresAtStr =
                                                  p['challenge_expires_at']
                                                      ?.toString();
                                              if (expiresAtStr == null ||
                                                  expiresAtStr.trim().isEmpty) {
                                                return const SizedBox.shrink();
                                              }
                                              final expiresAtUtc =
                                                  DateTime.parse(
                                                    expiresAtStr,
                                                  ).toUtc();
                                              final startUtc = expiresAtUtc
                                                  .subtract(
                                                    const Duration(minutes: 30),
                                                  );

                                              var minutes = createdAtUtc
                                                  .difference(startUtc)
                                                  .inMinutes;
                                              if (minutes < 0) minutes = 0;

                                              return Text(
                                                t(
                                                  'Nach $minutes Min. gepostet',
                                                  'Posted after $minutes min',
                                                ),
                                                style: _inter.copyWith(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: textSecondary,
                                                ),
                                              );
                                            } catch (_) {
                                              return const SizedBox.shrink();
                                            }
                                          },
                                        ),
                                      ),
                                    if ((p['is_late'] ?? false) == true)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12.0,
                                          right: 12.0,
                                          bottom: 8,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.red.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: Colors.red.shade600,
                                              width: 1.2,
                                            ),
                                          ),
                                          child: Text(
                                            t('Zu spät', 'Late'),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.red.shade700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    SizedBox(
                                      height: 290, // slightly taller card
                                      child: Builder(
                                        builder: (context) {
                                          final photoIdForOverlay =
                                              (p['id'] ?? '').toString();
                                          final pressNotifier =
                                              photoIdForOverlay.isEmpty
                                              ? null
                                              : _photoPressNotifierFor(
                                                  photoIdForOverlay,
                                                );
                                          final media = LivePhotoFeedMedia(
                                            stillUrl:
                                                p["url"]?.toString() ?? '',
                                            attachment:
                                                LivePhotoPostAttachment
                                                    .fromPostMap(p),
                                            preloadVideo: false,
                                            onTap: () => _openPhotoPreview(
                                              p["url"]?.toString(),
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            width:
                                                MediaQuery.of(
                                                  context,
                                                ).size.width -
                                                60,
                                            height: 260,
                                            fit: BoxFit.cover,
                                            alignment: const Alignment(0, 0),
                                            cacheWidth: sideQuestCacheWidth(
                                              context,
                                              MediaQuery.of(
                                                    context,
                                                  ).size.width -
                                                  60,
                                            ),
                                            cacheHeight: sideQuestCacheWidth(
                                              context,
                                              260,
                                            ),
                                            filterQuality: FilterQuality.low,
                                          );
                                          // Pointer listener tracks press
                                          // start/end without intercepting
                                          // the underlying tap/long-press, so
                                          // live-photo playback still works.
                                          final pressableMedia =
                                              pressNotifier == null
                                              ? media
                                              : Listener(
                                                  behavior:
                                                      HitTestBehavior
                                                          .translucent,
                                                  onPointerDown: (_) =>
                                                      pressNotifier.value =
                                                          true,
                                                  onPointerUp: (_) =>
                                                      pressNotifier.value =
                                                          false,
                                                  onPointerCancel: (_) =>
                                                      pressNotifier.value =
                                                          false,
                                                  child: media,
                                                );
                                          return Center(
                                            child: Stack(
                                              clipBehavior: Clip.none,
                                              children: [
                                                pressableMedia,
                                                if (photoIdForOverlay.isNotEmpty)
                                                  Positioned(
                                                    left: 14,
                                                    bottom: 8,
                                                    child: FriendLikesPreview(
                                                      photoId:
                                                          photoIdForOverlay,
                                                      hiddenListenable:
                                                          pressNotifier,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),

                                    // Likes und Comments
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          ListenableBuilder(
                                            listenable: _likeRevision,
                                            builder: (context, _) {
                                              return GestureDetector(
                                                onTap: () => toggleLike(
                                                  p['id'],
                                                  p['is_liked'] ?? false,
                                                ),
                                                child: LikeAnimation(
                                                  isAnimating:
                                                      _animatingLikePhotoId ==
                                                      p['id'],
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        (p['is_liked'] ?? false)
                                                            ? Icons.favorite
                                                            : Icons
                                                                  .favorite_border,
                                                        color:
                                                            (p['is_liked'] ??
                                                                false)
                                                            ? Colors.red
                                                            : textPrimary,
                                                        size: 28,
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Text(
                                                        (p['likes_count'] ?? 0)
                                                            .toString(),
                                                        style: _inter.copyWith(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: textPrimary,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                          const SizedBox(width: 20),
                                          GestureDetector(
                                            onTap: () =>
                                                showCommentsBottomSheet(
                                                  context,
                                                  p['id'],
                                                  _previewCommentsForPost(p),
                                                ),
                                            child: Row(
                                              children: [
                                                const ThoughtBubbleIcon(
                                                  color: Colors.white70,
                                                  size: 28,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _commentCountForPost(
                                                    p,
                                                  ).toString(),
                                                  style: _inter.copyWith(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: textPrimary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Zeige letzte Comments direkt an
                                    if (_previewCommentsForPost(p).isNotEmpty)
                                      ListenableBuilder(
                                        listenable: _likeRevision,
                                        builder: (context, _) {
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // Show up to first 2 comments (chronological order)
                                                ...List.generate(
                                                  (_previewCommentsForPost(
                                                            p,
                                                          ).length >
                                                          2
                                                      ? 2
                                                      : _previewCommentsForPost(
                                                          p,
                                                        ).length),
                                                  (index) {
                                                    final comments =
                                                        _previewCommentsForPost(
                                                          p,
                                                        );
                                                    if (index < 0 ||
                                                        index >=
                                                            comments.length) {
                                                      return const SizedBox.shrink();
                                                    }
                                                    final c = comments[index];

                                                    try {
                                                      final commenterName =
                                                          c['users_profile']?['username'] ??
                                                          'Unknown';
                                                      final commentText =
                                                          c['message'] ?? '';
                                                      final commentId =
                                                          c['id'] ?? '';
                                                      final commentLikesCount =
                                                          c['likes_count'] ?? 0;
                                                      final isCommentLiked =
                                                          c['is_liked'] ??
                                                          false;

                                                      if (commentId.isEmpty) {
                                                        return const SizedBox.shrink(); // Broken row without id.
                                                      }

                                                      return GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onLongPress: () =>
                                                            _showCommentActions(
                                                              Map<
                                                                String,
                                                                dynamic
                                                              >.from(c as Map),
                                                              photoId:
                                                                  (p['id'] ??
                                                                          '')
                                                                      .toString(),
                                                            ),
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                bottom: 6,
                                                              ),
                                                          child: Row(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Expanded(
                                                                child: GestureDetector(
                                                                  behavior:
                                                                      HitTestBehavior
                                                                          .opaque,
                                                                  onDoubleTap: () {
                                                                    if (!isCommentLiked) {
                                                                      toggleCommentLike(
                                                                        commentId,
                                                                        false,
                                                                      );
                                                                    }
                                                                  },
                                                                  child: Row(
                                                                    children: [
                                                                      Text(
                                                                        '$commenterName: ',
                                                                        style: _inter.copyWith(
                                                                          fontSize:
                                                                              12,
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                          color:
                                                                              textPrimary,
                                                                        ),
                                                                      ),
                                                                      Expanded(
                                                                        child: MentionText(
                                                                          text: commentText
                                                                              .toString(),
                                                                          style: _inter.copyWith(
                                                                            fontSize:
                                                                                12,
                                                                            fontWeight:
                                                                                FontWeight.w400,
                                                                            color:
                                                                                Colors.white70,
                                                                          ),
                                                                          mentionStyle: _inter.copyWith(
                                                                            fontSize:
                                                                                12,
                                                                            fontWeight:
                                                                                FontWeight.w700,
                                                                            color:
                                                                                appGreen,
                                                                          ),
                                                                          maxLines:
                                                                              1,
                                                                          overflow:
                                                                              TextOverflow.ellipsis,
                                                                          enableProfileNavigation:
                                                                              true,
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                width: 8,
                                                              ),
                                                              GestureDetector(
                                                                onTap: () =>
                                                                    toggleCommentLike(
                                                                      commentId,
                                                                      isCommentLiked,
                                                                    ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      isCommentLiked
                                                                          ? Icons.favorite
                                                                          : Icons.favorite_border,
                                                                      color:
                                                                          isCommentLiked
                                                                          ? Colors.red
                                                                          : textSecondary,
                                                                      size: 14,
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 3,
                                                                    ),
                                                                    Text(
                                                                      commentLikesCount
                                                                          .toString(),
                                                                      style: _inter.copyWith(
                                                                        fontSize:
                                                                            10,
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                        color:
                                                                            textSecondary,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                              if (c['user_id'] ==
                                                                  currentUserId) ...[
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                GestureDetector(
                                                                  onTap: () =>
                                                                      deleteComment(
                                                                        commentId,
                                                                        p['id'] ??
                                                                            '',
                                                                      ),
                                                                  child: const Icon(
                                                                    Icons
                                                                        .delete_outline,
                                                                    size: 14,
                                                                    color: Color(
                                                                      0xFFAAAAAA,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                        ),
                                                      );
                                                    } catch (e) {
                                                      AppLogger.debug(
                                                        "Error rendering comment: $e, Comment data: $c",
                                                      );
                                                      // Skip a broken comment instead of showing the raw error.
                                                      return const SizedBox.shrink();
                                                    }
                                                  },
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),

                                    const SizedBox(height: 8),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    }
                  }

                  final isFeedList = child.key == const ValueKey('feed_list');
                  if (isFeedList) return child;
                  return _feedAnimated(child);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== COMMENTS BOTTOM SHEET ====================
class CommentsBottomSheet extends StatefulWidget {
  final String photoId;
  final List<String>? photoIds;
  final String? postTargetPhotoId;
  final String? highlightCommentId;
  final List<Map<String, dynamic>> initialComments;
  final ScrollController? scrollController;

  const CommentsBottomSheet({
    super.key,
    required this.photoId,
    this.photoIds,
    this.postTargetPhotoId,
    this.highlightCommentId,
    required this.initialComments,
    this.scrollController,
  });

  @override
  State<CommentsBottomSheet> createState() => _CommentsBottomSheetState();
}

class _CommentsBottomSheetState extends State<CommentsBottomSheet> {
  final SupabaseClient client = Supabase.instance.client;
  final TextEditingController commentCtrl = TextEditingController();
  final Map<String, GlobalKey> _commentKeys = {};
  final Set<String> _commentLikeInFlightIds = <String>{};

  List<Map<String, dynamic>> comments = [];
  bool posting = false;
  bool _isLoadingComments = true;

  String get currentUserId => client.auth.currentUser?.id ?? '';
  List<String> get effectivePhotoIds {
    final ids = (widget.photoIds ?? const [])
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isNotEmpty) return ids;
    final single = widget.photoId.trim();
    if (single.isNotEmpty) return [single];
    return const [];
  }

  String get postPhotoId {
    final preferred = (widget.postTargetPhotoId ?? '').trim();
    if (preferred.isNotEmpty) return preferred;
    final single = widget.photoId.trim();
    if (single.isNotEmpty) return single;
    final ids = effectivePhotoIds;
    return ids.isNotEmpty ? ids.first : '';
  }

  @override
  void initState() {
    super.initState();
    // initial comments safely cast
    comments = widget.initialComments
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    _isLoadingComments = comments.isEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToHighlightedComment();
      _loadComments();
    });
  }

  @override
  void dispose() {
    commentCtrl.dispose();
    super.dispose();
  }

  GlobalKey _commentKeyFor(String commentId) {
    return _commentKeys.putIfAbsent(commentId, () => GlobalKey());
  }

  void _scrollToHighlightedComment() {
    final highlightedCommentId = (widget.highlightCommentId ?? '').trim();
    if (highlightedCommentId.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _commentKeys[highlightedCommentId]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
    });
  }

  String _commentModerationMessage(CommentModerationIssue? issue) {
    switch (issue) {
      case CommentModerationIssue.empty:
        return t('Bitte gib einen Kommentar ein', 'Please enter a comment');
      case CommentModerationIssue.tooLong:
        return t(
          'Kommentar ist zu lang (max. 280 Zeichen)',
          'Comment is too long (max 280 chars)',
        );
      case CommentModerationIssue.abusiveLanguage:
        return t(
          'Bitte keine beleidigende Sprache in Kommentaren',
          'Please avoid abusive language in comments',
        );
      case null:
        return t('Kommentar ist nicht erlaubt', 'Comment is not allowed');
    }
  }

  Future<void> _loadComments() async {
    if (!mounted) return;
    final showLoader = comments.isEmpty;
    if (showLoader) {
      setState(() => _isLoadingComments = true);
    }

    try {
      final loadedComments = await CommentThreadService.loadComments(
        client: client,
        photoIds: effectivePhotoIds,
      );
      if (!mounted) return;
      setState(() {
        comments = loadedComments;
        _isLoadingComments = false;
      });
      _scrollToHighlightedComment();
    } catch (e) {
      AppLogger.debug('Error loading comments in bottom sheet: $e');
      if (!mounted) return;
      setState(() => _isLoadingComments = false);
    }
  }

  Future<void> postComment() async {
    final moderation = CommentFilter.validate(commentCtrl.text);
    if (!moderation.isAllowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_commentModerationMessage(moderation.issue))),
        );
      }
      return;
    }

    setState(() => posting = true);

    try {
      final targetPhotoId = postPhotoId;
      if (targetPhotoId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Kommentar derzeit nicht möglich',
                  'Comment is not available right now',
                ),
              ),
            ),
          );
        }
        if (mounted) {
          setState(() => posting = false);
        }
        return;
      }

      final insertedComment = await client
          .from('comments')
          .insert({
            'photo_id': targetPhotoId,
            'user_id': currentUserId,
            'message': moderation.sanitized,
          })
          .select('id')
          .single();
      final insertedCommentId = (insertedComment['id'] ?? '').toString();

      await MentionService.createMentionNotifications(
        text: moderation.sanitized,
        entityKind: MentionEntityKind.comment,
        photoId: targetPhotoId,
        commentId: insertedCommentId,
      );

      commentCtrl.clear();
      await _loadComments();

      AppLogger.debug("Comment posted successfully");
    } catch (e) {
      AppLogger.debug("Error posting comment: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorMapper.describe(
                e,
                whatDe: "Fehler beim Kommentar",
                whatEn: "Error posting comment",
              ),
            ),
          ),
        );
      }
    }

    if (mounted) {
      setState(() => posting = false);
    }
  }

  Future<void> deleteComment(String commentId) async {
    final userId = client.auth.currentUser?.id ?? '';
    if (commentId.isEmpty || userId.isEmpty) return;

    try {
      await client
          .from('comments')
          .delete()
          .eq('id', commentId)
          .eq('user_id', userId);

      if (mounted) {
        setState(() {
          comments = comments.where((c) => c['id'] != commentId).toList();
        });
      }
    } catch (e) {
      AppLogger.debug('Error deleting comment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Löschen', 'Error deleting'))),
        );
      }
    }
  }

  Future<void> toggleCommentLikeLocal(String commentId, bool isLiked) async {
    final userId = client.auth.currentUser?.id ?? '';
    if (commentId.isEmpty ||
        userId.isEmpty ||
        !_commentLikeInFlightIds.add(commentId)) {
      return;
    }

    // Optimistic update: reflect in UI immediately
    if (mounted) {
      setState(() {
        final idx = comments.indexWhere((c) => c['id'] == commentId);
        if (idx != -1) {
          final c = Map<String, dynamic>.from(comments[idx]);
          final currentCount = (c['likes_count'] ?? 0) as int;
          c['likes_count'] = isLiked
              ? (currentCount > 0 ? currentCount - 1 : 0)
              : currentCount + 1;
          c['is_liked'] = !isLiked;
          comments[idx] = c;
        }
      });
    }

    try {
      await sideQuestPersistCommentLike(
        client: client,
        commentId: commentId,
        userId: userId,
        shouldLike: !isLiked,
      );
    } catch (e) {
      AppLogger.debug('Error toggling comment like (bottom sheet): $e');
      // Revert optimistic update and resync from server
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Fehler beim Liken des Kommentars', 'Error liking comment'),
            ),
          ),
        );
        _loadComments();
      }
    } finally {
      _commentLikeInFlightIds.remove(commentId);
    }
  }

  void _showCommentsSnackBar(String de, String en) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t(de, en))));
  }

  Future<bool> _confirmReportDialog({
    required String titleDe,
    required String titleEn,
    required String messageDe,
    required String messageEn,
  }) async {
    if (!mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t(titleDe, titleEn),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(messageDe, messageEn),
          style: _inter.copyWith(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: _inter.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t('Melden', 'Report'),
              style: _inter.copyWith(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _reportComment(String commentId, String reportedUserId) async {
    if (commentId.isEmpty) return;
    final confirmed = await _confirmReportDialog(
      titleDe: 'Kommentar melden?',
      titleEn: 'Report comment?',
      messageDe: 'Bist du sicher, dass du diesen Kommentar melden möchtest?',
      messageEn: 'Are you sure that you want to report this comment?',
    );
    if (!confirmed) return;

    try {
      final result = await ReportService.submit(
        client: client,
        targetType: ReportTargetType.comment,
        photoId: postPhotoId,
        commentId: commentId,
        reportedUserId: reportedUserId,
      );
      if (result == ReportSubmissionResult.alreadyReported) {
        _showCommentsSnackBar(
          'Du hast diesen Kommentar bereits gemeldet',
          'You already reported this comment',
        );
      } else {
        _showCommentsSnackBar('Kommentar gemeldet', 'Comment reported');
      }
    } catch (e) {
      AppLogger.debug('Error reporting comment from bottom sheet: $e');
      _showCommentsSnackBar(
        'Melden des Kommentars fehlgeschlagen',
        'Reporting the comment failed',
      );
    }
  }

  Future<void> _showCommentActions(Map<String, dynamic> comment) async {
    final commentId = (comment['id'] ?? '').toString();
    if (commentId.isEmpty) return;

    final isOwnComment = comment['user_id'] == currentUserId;
    final action = await showModalBottomSheet<_CommentActionMenuValue>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: Colors.orangeAccent,
                ),
                title: Text(
                  t('Kommentar melden', 'Report comment'),
                  style: _inter.copyWith(color: Colors.white),
                ),
                onTap: () =>
                    Navigator.pop(sheetContext, _CommentActionMenuValue.report),
              ),
              if (isOwnComment)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    t('Kommentar löschen', 'Delete comment'),
                    style: _inter.copyWith(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _CommentActionMenuValue.delete,
                  ),
                ),
            ],
          ),
        );
      },
    );

    if (action == null) return;
    if (action == _CommentActionMenuValue.delete) {
      await deleteComment(commentId);
      return;
    }
    await _reportComment(commentId, (comment['user_id'] ?? '').toString());
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Bottom inset of the home indicator. We DON'T let SafeArea wrap the
    // whole sheet — that creates a visible gap between the sheet background
    // and the screen bottom. Instead the sheet extends fully and only the
    // input row gets padded above the home indicator.
    final safeBottom = MediaQuery.of(context).padding.bottom;
    const sheetBg = Color(0xFF121212);
    const sheetCard = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: sheetBg,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 6),
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      t('Kommentare', 'Comments'),
                      style: _inter.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Color(0xFF2A2A2A)),
              // Comments List
              Expanded(
                child: _isLoadingComments && comments.isEmpty
                    ? Center(child: CircularProgressIndicator(color: appGreen))
                    : ListView.builder(
                        controller: widget.scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: comments.length,
                        itemBuilder: (context, i) {
                          try {
                            final comment = Map<String, dynamic>.from(
                              comments[i],
                            );
                            final profileData = comment['users_profile'];
                            final profile =
                                (profileData != null && profileData is Map)
                                ? Map<String, dynamic>.from(profileData)
                                : <String, dynamic>{};

                            final isOwnComment =
                                comment['user_id'] == currentUserId;
                            final isHighlighted =
                                (comment['id'] ?? '').toString() ==
                                (widget.highlightCommentId ?? '').trim();
                            final displayName = isOwnComment
                                ? '${profile['username'] ?? 'Unknown'} (${t('Du', 'you')})'
                                : (profile['username'] ?? 'Unknown');

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPress: () => _showCommentActions(comment),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Container(
                                  key: _commentKeyFor(
                                    (comment['id'] ?? '').toString(),
                                  ),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: isHighlighted
                                        ? const Color(0x33FFD54F)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(14),
                                    border: isHighlighted
                                        ? Border.all(
                                            color: const Color(0xFFFFD54F),
                                            width: 1.1,
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        // Tap on the comment avatar opens the
                                        // commenter's profile (consistent with
                                        // tapping their post in the feed).
                                        // Previously this opened a profile-
                                        // picture-zoom dialog, which the user
                                        // found unintuitive — they expected
                                        // navigation.
                                        onTap: () {
                                          final commentUserId =
                                              (comment['user_id'] ?? '')
                                                  .toString();
                                          if (commentUserId.isEmpty) return;
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ProfileScreen(
                                                userId: commentUserId,
                                              ),
                                            ),
                                          );
                                        },
                                        child: CircleAvatar(
                                          radius: 16,
                                          backgroundColor: Colors.black,
                                          backgroundImage:
                                              profile['profile_picture'] != null
                                              ? sideQuestCachedImageProvider(
                                                  profile['profile_picture'],
                                                  cacheWidth:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        32,
                                                      ),
                                                  cacheHeight:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        32,
                                                      ),
                                                )
                                              : null,
                                          child:
                                              profile['profile_picture'] == null
                                              ? Text(
                                                  (profile['username'] ??
                                                          'U')[0]
                                                      .toUpperCase(),
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onDoubleTap: () {
                                            if ((comment['is_liked'] ??
                                                    false) !=
                                                true) {
                                              toggleCommentLikeLocal(
                                                comment['id'] ?? '',
                                                false,
                                              );
                                            }
                                          },
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                displayName,
                                                style: _inter.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                  color: textPrimary,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              MentionText(
                                                text: (comment['message'] ?? '')
                                                    .toString(),
                                                style: _inter.copyWith(
                                                  fontSize: 13,
                                                  color: textSecondary,
                                                ),
                                                mentionStyle: _inter.copyWith(
                                                  fontSize: 13,
                                                  color: appGreen,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                                enableProfileNavigation: true,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              GestureDetector(
                                                onTap: () =>
                                                    toggleCommentLikeLocal(
                                                      comment['id'] ?? '',
                                                      comment['is_liked'] ??
                                                          false,
                                                    ),
                                                child: Icon(
                                                  (comment['is_liked'] ?? false)
                                                      ? Icons.favorite
                                                      : Icons.favorite_border,
                                                  color:
                                                      (comment['is_liked'] ??
                                                          false)
                                                      ? Colors.red
                                                      : textSecondary,
                                                  size: 18,
                                                ),
                                              ),
                                              if (isOwnComment) ...[
                                                const SizedBox(width: 6),
                                                GestureDetector(
                                                  onTap: () => deleteComment(
                                                    comment['id'] ?? '',
                                                  ),
                                                  child: const Icon(
                                                    Icons.delete_outline,
                                                    size: 18,
                                                    color: textSecondary,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            (comment['likes_count'] ?? 0)
                                                .toString(),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              color: textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          } catch (e) {
                            AppLogger.debug(
                              "Error rendering comment: $e, Data: ${comments[i]}",
                            );
                            // Skip a broken comment instead of showing the raw error.
                            return const SizedBox.shrink();
                          }
                        },
                      ),
              ),
              const Divider(color: Color(0xFF2A2A2A)),
              // Input Row — extra bottom padding keeps the input above the
              // home indicator while the sheet background extends to the
              // screen edge.
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + safeBottom),
                child: Row(
                  children: [
                    Expanded(
                      child: MentionAutocompleteField(
                        controller: commentCtrl,
                        style: _inter.copyWith(color: textPrimary),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: sheetCard,
                          hintText: t("Kommentar...", "Comment..."),
                          hintStyle: _inter.copyWith(color: textSecondary),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: appGreen,
                        padding: const EdgeInsets.all(12),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: posting ? null : postComment,
                      child: posting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.send,
                              color: Colors.white,
                              size: 20,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  }
}

// ==================== SIDEQUEST CAMERA SCREEN ====================
class CameraOverlay extends StatefulWidget {
  final XFile imageFile;
  final LivePhotoCaptureResult? livePhotoCapture;
  final void Function(bool isPublic, String postDescription) onConfirm;
  final VoidCallback onCancel;

  const CameraOverlay({
    super.key,
    required this.imageFile,
    this.livePhotoCapture,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<CameraOverlay> createState() => _CameraOverlayState();
}

class _CameraOverlayState extends State<CameraOverlay>
    with SingleTickerProviderStateMixin {
  bool isPublic = false;
  bool uploading = false;
  final TextEditingController _descriptionCtrl = TextEditingController();
  final FocusNode _descriptionFocusNode = FocusNode();
  late final AnimationController _introController;
  late final Animation<double> _fade;
  late final Animation<Offset> _panelSlide;
  late final Animation<Offset> _topSlide;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    final eased = CurvedAnimation(
      parent: _introController,
      curve: Curves.easeOutCubic,
    );
    _fade = eased;
    _panelSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(eased);
    _topSlide = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(eased);
    _introController.forward();
    _loadInitialOverlaySettings();
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _descriptionFocusNode.dispose();
    _introController.dispose();
    super.dispose();
  }

  void _setAudience(bool value) {
    if (uploading) return;
    setState(() => isPublic = value);
  }

  Future<void> _loadInitialOverlaySettings() async {
    final settings = await UserAppSettingsPrefs.load();
    if (!mounted) return;

    setState(() {
      isPublic = settings.defaultPostPublic;
    });
  }

  void _submit() {
    if (uploading) return;
    setState(() => uploading = true);
    widget.onConfirm(isPublic, _descriptionCtrl.text);
    Navigator.pop(context);
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.78,
      maxScale: 1.0,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(24 * scale),
      onTap: uploading ? null : onTap,
      child: Opacity(
        opacity: uploading ? 0.45 : 1,
        child: Container(
          width: 48 * scale,
          height: 48 * scale,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, color: Colors.white, size: 25 * scale),
        ),
      ),
    );
  }

  Widget _audienceChip({
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.78,
      maxScale: 1.0,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(28 * scale),
      onTap: uploading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 11 * scale,
        ),
        decoration: BoxDecoration(
          color: selected ? appGreen : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(28 * scale),
          border: Border.all(
            color: selected
                ? appGreen.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18 * scale,
              color: selected ? Colors.black : Colors.white70,
            ),
            SizedBox(width: 8 * scale),
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: _inter.copyWith(
                color: selected ? Colors.black : Colors.white70,
                fontSize: 13 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final actionLabel = isPublic
        ? t('\u00D6ffentlich posten', 'Post publicly')
        : t('An Freunde posten', 'Post to friends');
    final livePreviewCapture = widget.livePhotoCapture;
    final hasPlayableLivePreview =
        livePreviewCapture != null && livePreviewCapture.hasPlayableClip;
    final sheetScale = sideQuestResponsiveScale(
      context,
      minScale: 0.78,
      maxScale: 1.0,
    );

    return Dialog(
      backgroundColor: const Color(0xFF07090D),
      insetPadding: EdgeInsets.zero,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => FocusScope.of(context).unfocus(),
            child: FadeTransition(
              opacity: _fade,
              child: Column(
                children: [
                  SlideTransition(
                    position: _topSlide,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                      child: Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'SideQuest',
                              style: _inter.copyWith(
                                color: Colors.white,
                                fontSize: 32 * sheetScale,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.6,
                              ),
                            ),
                          ),
                          const Spacer(),
                          _circleButton(
                            icon: Icons.close_rounded,
                            onTap: widget.onCancel,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: SlideTransition(
                      position: _panelSlide,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 430),
                            child: AspectRatio(
                              aspectRatio: 3 / 4.35,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(30),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.14),
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (hasPlayableLivePreview)
                                      LivePhotoFeedMedia(
                                        stillUrl: '',
                                        attachment:
                                            const LivePhotoPostAttachment(
                                              isLivePhoto: true,
                                              mediaKind: 'live_photo',
                                              clipUrl: null,
                                              clipDurationMs: 0,
                                              preCaptureDurationMs: 0,
                                              liveMuted: false,
                                            ),
                                        localStillPath: widget.imageFile.path,
                                        localClipPath:
                                            livePreviewCapture.clipPath,
                                        preloadVideo: true,
                                        fit: BoxFit.cover,
                                        alignment: const Alignment(0, 0),
                                      )
                                    else
                                      Image.file(
                                        File(widget.imageFile.path),
                                        fit: BoxFit.cover,
                                      ),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.center,
                                              colors: [
                                                Colors.black.withValues(
                                                  alpha: 0.26,
                                                ),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (hasPlayableLivePreview)
                                      Positioned(
                                        left: 16,
                                        bottom: 16,
                                        child: IgnorePointer(
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 12 * sheetScale,
                                              vertical: 8 * sheetScale,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.44,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.14,
                                                ),
                                              ),
                                            ),
                                            child: Text(
                                              t(
                                                'Gedrückt halten für Live',
                                                'Hold to play live',
                                              ),
                                              style: _inter.copyWith(
                                                color: Colors.white,
                                                fontSize: 12 * sheetScale,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SlideTransition(
                    position: _panelSlide,
                    child: AnimatedPadding(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      padding: EdgeInsets.fromLTRB(
                        18,
                        0,
                        18,
                        keyboardInset > 0
                            ? keyboardInset + 12
                            : 52 + safeBottom,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 430),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.26),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _audienceChip(
                                      selected: !isPublic,
                                      icon: Icons.groups_rounded,
                                      label: t('Freunde', 'Friends'),
                                      onTap: () => _setAudience(false),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _audienceChip(
                                      selected: isPublic,
                                      icon: Icons.public_rounded,
                                      label: t('\u00D6ffentlich', 'Public'),
                                      onTap: () => _setAudience(true),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              MentionAutocompleteField(
                                controller: _descriptionCtrl,
                                focusNode: _descriptionFocusNode,
                                readOnly: uploading,
                                keyboardType: TextInputType.multiline,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _submit(),
                                maxLength: 180,
                                minLines: 1,
                                maxLines: 3,
                                scrollPadding: const EdgeInsets.only(
                                  bottom: 140,
                                ),
                                style: _inter.copyWith(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: t(
                                    'Beschreibung (optional)',
                                    'Description (optional)',
                                  ),
                                  hintStyle: _inter.copyWith(
                                    color: Colors.white54,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  counter: const SizedBox.shrink(),
                                  filled: true,
                                  fillColor: Colors.white.withValues(
                                    alpha: 0.1,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.18,
                                      ),
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.18,
                                      ),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: BorderSide(
                                      color: appGreen.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: appGreen,
                                    foregroundColor: Colors.black,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  onPressed: uploading ? null : _submit,
                                  child: uploading
                                      ? Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.3,
                                                color: Colors.black,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              t(
                                                'Wird gepostet...',
                                                'Posting...',
                                              ),
                                              style: _inter.copyWith(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              actionLabel,
                                              style: _inter.copyWith(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            const Icon(
                                              Icons.arrow_forward_rounded,
                                              size: 19,
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
