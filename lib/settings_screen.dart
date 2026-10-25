import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'analytics_service.dart';
import 'app_bootstrap.dart';
import 'block_service.dart';
import 'core/analytics_consent.dart';
import 'core/error_mapper.dart';
import 'core/legal_texts.dart';
import 'core/app_environment.dart';
import 'features/invite/invite_share.dart';
import 'features/moderation/moderation_screen.dart';
import 'friend_discovery.dart';
import 'shared.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  String selectedLanguageCode = languageController.lang;
  bool notifyFriendsPosts = true;
  bool notifyChallengeEnding = true;
  bool notifyChallengeStart = true;
  bool notifyChallenged = true;
  bool notifyMessages = true;
  bool defaultPostPublic = false;
  bool allowContactDiscovery = true;
  bool loadingPrefs = true;
  bool _linkingContacts = false;
  bool _loadingBlockedUsers = true;
  List<BlockedUserItem> _blockedUsers = const [];
  final Set<String> _updatingBlockedUserIds = <String>{};
  String? _currentAccountAvatarUrl;
  String _currentAccountUsername = '';
  bool _isAdmin = false;
  String _appVersion = '';

  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadBlockedUsers();
    _loadAccountPreview();
    _loadAdminFlag();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = '${info.version} (${info.buildNumber})');
    } catch (_) {}
  }

  Future<void> _loadAdminFlag() async {
    final isAdmin = await ModerationService.isAdmin();
    if (!mounted || !isAdmin) return;
    setState(() => _isAdmin = true);
  }

  Future<void> _loadPrefs() async {
    final notificationPrefs = await NotificationPrefs.load();
    final appSettings = await UserAppSettingsPrefs.load();
    if (!mounted) return;
    setState(() {
      selectedLanguageCode = languageController.lang;
      notifyFriendsPosts = notificationPrefs.friendsPosts;
      notifyChallengeEnding = notificationPrefs.challengeEnding;
      notifyChallengeStart = notificationPrefs.challengeStart;
      notifyChallenged = notificationPrefs.challenged;
      notifyMessages = notificationPrefs.messages;
      defaultPostPublic = appSettings.defaultPostPublic;
      allowContactDiscovery = appSettings.allowContactDiscovery;
      loadingPrefs = false;
    });
  }

  Future<void> _loadBlockedUsers() async {
    final blockedUsers = await BlockService.loadBlockedUsers();
    if (!mounted) return;
    setState(() {
      _blockedUsers = blockedUsers;
      _loadingBlockedUsers = false;
    });
  }

  Future<void> _loadAccountPreview() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) return;

      final row = await client
          .from('users_profile')
          .select('username, profile_picture')
          .eq('id', userId)
          .maybeSingle();
      if (!mounted || row == null) return;

      setState(() {
        _currentAccountUsername = (row['username'] ?? '').toString().trim();
        _currentAccountAvatarUrl = (row['profile_picture'] ?? '')
            .toString()
            .trim();
      });
    } catch (_) {
      // Best-effort only. Missing profile data should not break settings.
    }
  }

  Future<void> _unblockUser(String userId) async {
    if (userId.isEmpty || _updatingBlockedUserIds.contains(userId)) return;

    setState(() => _updatingBlockedUserIds.add(userId));
    try {
      await BlockService.unblockUser(userId);
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      await _loadBlockedUsers();
      _showSettingsSnack(t('Nutzer entblockt.', 'User unblocked.'));
    } catch (e) {
      _showSettingsSnack(
        ErrorMapper.describe(
          e,
          whatDe: 'Entblocken fehlgeschlagen',
          whatEn: 'Unblocking failed',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _updatingBlockedUserIds.remove(userId));
      }
    }
  }

  String get _selectedLanguageLabel =>
      selectedLanguageCode == 'en' ? 'English' : 'Deutsch';

  String get _currentUserEmail =>
      (Supabase.instance.client.auth.currentUser?.email ?? '').trim();

  String get _currentAccountLabel {
    if (_currentAccountUsername.isNotEmpty) return _currentAccountUsername;
    final email = _currentUserEmail;
    if (email.isNotEmpty) {
      return email.split('@').first.trim();
    }
    return 'SideQuest';
  }

  String get _currentAccountInitial {
    final label = _currentAccountLabel.trim();
    return label.isEmpty ? 'S' : label.substring(0, 1).toUpperCase();
  }

  int get _activeNotificationCount {
    return [
      notifyFriendsPosts,
      notifyChallengeEnding,
      notifyChallengeStart,
      notifyChallenged,
      notifyMessages,
    ].where((value) => value).length;
  }

  String get _privacySummary {
    final audience = defaultPostPublic
        ? t('Standard: Öffentlich', 'Default: Public')
        : t('Standard: Freunde', 'Default: Friends');
    final contacts = allowContactDiscovery
        ? t('Kontakte an', 'Contacts on')
        : t('Kontakte aus', 'Contacts off');
    return '$audience · $contacts';
  }

  void _showSettingsSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  String _ratingStoreUrl() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppEnvironment.appleAppStoreUrl;
      case TargetPlatform.android:
        return AppEnvironment.googlePlayStoreUrl;
      default:
        return AppEnvironment.websiteUrl;
    }
  }

  Future<void> _launchExternalUrl(
    String url, {
    String? fallbackUrl,
    LaunchMode mode = LaunchMode.externalApplication,
  }) async {
    Future<bool> tryLaunch(String value) async {
      final uri = Uri.tryParse(value.trim());
      if (uri == null) return false;
      return launchUrl(uri, mode: mode);
    }

    final launched = await tryLaunch(url);
    if (launched) return;

    final fallback = (fallbackUrl ?? '').trim();
    if (fallback.isNotEmpty) {
      await tryLaunch(fallback);
    }
  }

  Future<void> _linkContactsNow() async {
    if (_linkingContacts) return;
    setState(() => _linkingContacts = true);

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        await FriendDiscoveryService.markContactsOnboardingSeen(userId);
      }

      final result = await FriendDiscoveryService.linkContactsForCurrentUser();
      if (!mounted) return;

      final message = switch (result.status) {
        ContactLinkStatus.linked when result.contactsProcessed > 0 => t(
          '${result.contactsProcessed} Kontakte verknüpft. Vorschläge wurden aktualisiert.',
          '${result.contactsProcessed} contacts linked. Suggestions were refreshed.',
        ),
        ContactLinkStatus.linked => t(
          'Keine Kontakte gefunden.',
          'No contacts found.',
        ),
        ContactLinkStatus.permissionDenied => t(
          'Kontaktzugriff nicht erlaubt. Bitte in den Systemeinstellungen aktivieren.',
          'Contacts permission denied. Please enable it in system settings.',
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

      _showSettingsSnack(message);
    } finally {
      if (mounted) {
        setState(() => _linkingContacts = false);
      }
    }
  }

  Future<void> _sendFeedback() async {
    await AnalyticsService.logSettingsGrowthAction(
      action: 'feedback',
      surface: 'settings_hero',
    );
    final subject = Uri.encodeComponent('SideQuest Feedback');
    final body = Uri.encodeComponent(
      t(
        'Hi SideQuest Team,\n\nich habe folgendes Feedback zu SideQuest:\n\n',
        'Hi SideQuest team,\n\nI have the following feedback for SideQuest:\n\n',
      ),
    );
    final uri = Uri.parse(
      'mailto:${AppEnvironment.supportEmail}?subject=$subject&body=$body',
    );
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSettingsSnack(
        t(
          'Feedback konnte nicht geöffnet werden.',
          'Could not open feedback composer.',
        ),
      );
    }
  }

  Future<void> _shareSideQuest() async {
    final shared = shareSideQuestInvite(surface: 'settings', context: context);
    await AnalyticsService.logSettingsGrowthAction(
      action: 'invite',
      surface: 'settings_hero',
    );
    // Personalized invite link (with @username), same as the friends tab
    // and onboarding entry points.
    await shared;
  }

  Future<void> _rateApp() async {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'other',
    };

    await AnalyticsService.logSettingsGrowthAction(
      action: 'rate',
      surface: 'settings_hero',
      platform: platform,
    );

    final storeUrl = _ratingStoreUrl();
    if (storeUrl.contains('com.example.nummwe3') ||
        storeUrl.contains('id0000000000')) {
      _showSettingsSnack(
        t(
          'Store-Link fehlt noch. Setze GOOGLE_PLAY_STORE_URL und APPLE_APP_STORE_URL per dart-define.',
          'Store link is still missing. Set GOOGLE_PLAY_STORE_URL and APPLE_APP_STORE_URL via dart-define.',
        ),
      );
      return;
    }
    await _launchExternalUrl(storeUrl, fallbackUrl: AppEnvironment.websiteUrl);
  }

  String _passwordValidationMessage(String password) {
    if (password.length < 8) {
      return t('Mindestens 8 Zeichen', 'At least 8 characters');
    }
    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      return t('Mindestens ein Großbuchstabe', 'At least one uppercase letter');
    }
    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return t('Mindestens eine Zahl', 'At least one digit');
    }
    return '';
  }

  String _authErrorMessage(Object error) {
    if (error is AuthException) {
      final mapped = ErrorMapper.auth(error);
      return t(mapped.de, mapped.en);
    }
    final mapped = ErrorMapper.generic(error);
    return t(mapped.de, mapped.en);
  }

  Future<void> _showChangeEmailDialog() async {
    final currentEmailController = TextEditingController(
      text: _currentUserEmail,
    );
    final currentPasswordController = TextEditingController();
    final newEmailController = TextEditingController();
    final verificationCodeController = TextEditingController();
    String? errorText;
    var obscureCurrentPassword = true;
    var isSaving = false;
    var codeSent = false;
    var pendingEmail = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          InputDecoration decoration({
            required String label,
            String? hintText,
            bool obscureText = false,
            VoidCallback? onToggle,
          }) {
            return InputDecoration(
              labelText: label,
              hintText: hintText,
              hintStyle: GoogleFonts.inter(color: const Color(0xFF7E7E7E)),
              labelStyle: GoogleFonts.inter(color: const Color(0xFFB8B8B8)),
              filled: true,
              fillColor: const Color(0xFF121212),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: appGreen),
              ),
              suffixIcon: onToggle == null
                  ? null
                  : IconButton(
                      onPressed: onToggle,
                      icon: Icon(
                        obscureText ? Icons.visibility_off : Icons.visibility,
                        color: const Color(0xFF9A9A9A),
                      ),
                    ),
            );
          }

          Future<void> sendCode() async {
            final enteredCurrentEmail = currentEmailController.text
                .trim()
                .toLowerCase();
            final currentEmail = _currentUserEmail.trim().toLowerCase();
            final currentPassword = currentPasswordController.text;
            final nextEmail = newEmailController.text.trim().toLowerCase();

            if (enteredCurrentEmail.isEmpty ||
                currentPassword.isEmpty ||
                nextEmail.isEmpty) {
              setModalState(() {
                errorText = t(
                  'Bitte fülle alle Felder aus.',
                  'Please fill out all fields.',
                );
              });
              return;
            }
            if (currentEmail.isEmpty) {
              setModalState(() {
                errorText = t(
                  'Für dieses Konto ist aktuell keine E-Mail hinterlegt.',
                  'No email is currently stored for this account.',
                );
              });
              return;
            }
            if (enteredCurrentEmail != currentEmail) {
              setModalState(() {
                errorText = t(
                  'Die aktuelle E-Mail stimmt nicht mit deinem Konto überein.',
                  'The current email does not match your account.',
                );
              });
              return;
            }
            if (!_emailPattern.hasMatch(nextEmail)) {
              setModalState(() {
                errorText = t(
                  'Bitte gib eine gültige neue E-Mail ein.',
                  'Please enter a valid new email.',
                );
              });
              return;
            }
            if (nextEmail == currentEmail) {
              setModalState(() {
                errorText = t(
                  'Das ist bereits deine aktuelle E-Mail.',
                  'This is already your current email.',
                );
              });
              return;
            }

            setModalState(() {
              isSaving = true;
              errorText = null;
            });

            try {
              await Supabase.instance.client.auth.signInWithPassword(
                email: currentEmail,
                password: currentPassword,
              );
              await Supabase.instance.client.auth.updateUser(
                UserAttributes(email: nextEmail),
              );
              setModalState(() {
                pendingEmail = nextEmail;
                codeSent = true;
                isSaving = false;
                errorText = null;
              });
            } catch (error) {
              setModalState(() {
                isSaving = false;
                errorText = _authErrorMessage(error);
              });
            }
          }

          Future<void> verifyCode() async {
            final code = verificationCodeController.text.trim();
            if (code.isEmpty) {
              setModalState(() {
                errorText = t(
                  'Bitte gib den Bestätigungscode ein.',
                  'Please enter the verification code.',
                );
              });
              return;
            }

            setModalState(() {
              isSaving = true;
              errorText = null;
            });

            try {
              await Supabase.instance.client.auth.verifyOTP(
                type: OtpType.emailChange,
                token: code,
                email: pendingEmail,
              );
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() {});
              _showSettingsSnack(
                t(
                  'Code bestätigt. Falls deine alte E-Mail ebenfalls eine Bestätigung verlangt, prüfe auch dieses Postfach.',
                  'Code confirmed. If your old email also requires confirmation, please check that inbox too.',
                ),
              );
            } catch (error) {
              setModalState(() {
                isSaving = false;
                errorText = _authErrorMessage(error);
              });
            }
          }

          Future<void> resendCode() async {
            if (pendingEmail.isEmpty) return;

            setModalState(() {
              isSaving = true;
              errorText = null;
            });

            try {
              await Supabase.instance.client.auth.resend(
                type: OtpType.emailChange,
                email: pendingEmail,
              );
              if (!mounted) return;
              _showSettingsSnack(
                t('Code erneut gesendet.', 'Code sent again.'),
              );
              setModalState(() {
                isSaving = false;
              });
            } catch (error) {
              setModalState(() {
                isSaving = false;
                errorText = _authErrorMessage(error);
              });
            }
          }

          Future<void> submit() async {
            if (!codeSent) {
              await sendCode();
              return;
            }

            await verifyCode();
          }

          final description = codeSent
              ? t(
                  'Gib jetzt den Code ein, der an deine neue E-Mail geschickt wurde.',
                  'Now enter the code that was sent to your new email.',
                )
              : t(
                  'Gib zuerst deine aktuelle E-Mail, dein aktuelles Passwort und danach die neue E-Mail ein.',
                  'First enter your current email, your current password, and then your new email.',
                );

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              t('E-Mail ändern', 'Change email'),
              style: GoogleFonts.inter(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: GoogleFonts.inter(
                    color: const Color(0xFFB8B8B8),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: currentEmailController,
                  enabled: !codeSent,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Aktuelle E-Mail', 'Current email'),
                    hintText: 'name@example.com',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: currentPasswordController,
                  enabled: !codeSent,
                  obscureText: obscureCurrentPassword,
                  autofillHints: const [AutofillHints.password],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Aktuelles Passwort', 'Current password'),
                    obscureText: obscureCurrentPassword,
                    onToggle: () => setModalState(() {
                      obscureCurrentPassword = !obscureCurrentPassword;
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: newEmailController,
                  enabled: !codeSent,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.newUsername],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Neue E-Mail', 'New email'),
                    hintText: 'name@example.com',
                  ),
                  onSubmitted: (_) => submit(),
                ),
                if (codeSent) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: verificationCodeController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.inter(color: Colors.white),
                    decoration: decoration(
                      label: t('Bestätigungscode', 'Verification code'),
                      hintText: '123456',
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: isSaving ? null : resendCode,
                      child: Text(
                        t('Code erneut senden', 'Resend code'),
                        style: GoogleFonts.inter(
                          color: appGreen,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                if (errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorText!,
                    style: GoogleFonts.inter(
                      color: const Color(0xFFFF8F8F),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.of(ctx).pop(),
                child: Text(
                  t('Abbrechen', 'Cancel'),
                  style: GoogleFonts.inter(color: Colors.white70),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: appGreen,
                  foregroundColor: Colors.black,
                ),
                onPressed: isSaving ? null : submit,
                child: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        codeSent
                            ? t('Bestätigen', 'Confirm')
                            : t('Code senden', 'Send code'),
                        style: GoogleFonts.inter(fontWeight: FontWeight.w700),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showChangePasswordDialog() async {
    final currentPasswordController = TextEditingController();
    final passwordController = TextEditingController();
    final repeatController = TextEditingController();
    String? errorText;
    var obscureCurrentPassword = true;
    var obscurePassword = true;
    var obscureRepeat = true;
    var isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> submit() async {
            final currentPassword = currentPasswordController.text;
            final nextPassword = passwordController.text;
            final repeatPassword = repeatController.text;
            final validationMessage = _passwordValidationMessage(nextPassword);
            final currentEmail = _currentUserEmail;

            if (currentPassword.isEmpty ||
                nextPassword.isEmpty ||
                repeatPassword.isEmpty) {
              setModalState(() {
                errorText = t(
                  'Bitte fülle alle Passwortfelder aus.',
                  'Please fill out all password fields.',
                );
              });
              return;
            }
            if (currentEmail.isEmpty) {
              setModalState(() {
                errorText = t(
                  'Für diese Kontomethode ist keine Passwort-Bestätigung verfügbar.',
                  'Password confirmation is not available for this account method.',
                );
              });
              return;
            }
            if (validationMessage.isNotEmpty) {
              setModalState(() {
                errorText = validationMessage;
              });
              return;
            }
            if (nextPassword != repeatPassword) {
              setModalState(() {
                errorText = t(
                  'Die Passwörter stimmen nicht überein.',
                  'Passwords do not match.',
                );
              });
              return;
            }

            setModalState(() {
              isSaving = true;
              errorText = null;
            });

            try {
              await Supabase.instance.client.auth.signInWithPassword(
                email: currentEmail,
                password: currentPassword,
              );
              await Supabase.instance.client.auth.updateUser(
                UserAttributes(password: nextPassword),
              );
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              _showSettingsSnack(
                t('Passwort aktualisiert.', 'Password updated.'),
              );
            } catch (error) {
              setModalState(() {
                isSaving = false;
                errorText = _authErrorMessage(error);
              });
            }
          }

          InputDecoration decoration({
            required String label,
            required bool obscureText,
            required VoidCallback onToggle,
          }) {
            return InputDecoration(
              labelText: label,
              labelStyle: GoogleFonts.inter(color: const Color(0xFFB8B8B8)),
              filled: true,
              fillColor: const Color(0xFF121212),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: appGreen),
              ),
              suffixIcon: IconButton(
                onPressed: onToggle,
                icon: Icon(
                  obscureText ? Icons.visibility_off : Icons.visibility,
                  color: const Color(0xFF9A9A9A),
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              t('Passwort ändern', 'Change password'),
              style: GoogleFonts.inter(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(
                    'Gib zuerst dein aktuelles Passwort ein. Das neue braucht mindestens 8 Zeichen, 1 Großbuchstaben und 1 Zahl.',
                    'Enter your current password first. The new one needs at least 8 characters, 1 uppercase letter, and 1 digit.',
                  ),
                  style: GoogleFonts.inter(
                    color: const Color(0xFFB8B8B8),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: currentPasswordController,
                  obscureText: obscureCurrentPassword,
                  autofillHints: const [AutofillHints.password],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Aktuelles Passwort', 'Current password'),
                    obscureText: obscureCurrentPassword,
                    onToggle: () => setModalState(() {
                      obscureCurrentPassword = !obscureCurrentPassword;
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  autofillHints: const [AutofillHints.newPassword],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Neues Passwort', 'New password'),
                    obscureText: obscurePassword,
                    onToggle: () => setModalState(() {
                      obscurePassword = !obscurePassword;
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: repeatController,
                  obscureText: obscureRepeat,
                  autofillHints: const [AutofillHints.newPassword],
                  style: GoogleFonts.inter(color: Colors.white),
                  decoration: decoration(
                    label: t('Passwort wiederholen', 'Repeat password'),
                    obscureText: obscureRepeat,
                    onToggle: () => setModalState(() {
                      obscureRepeat = !obscureRepeat;
                    }),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorText!,
                    style: GoogleFonts.inter(
                      color: const Color(0xFFFF8F8F),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.of(ctx).pop(),
                child: Text(
                  t('Abbrechen', 'Cancel'),
                  style: GoogleFonts.inter(color: Colors.white70),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: appGreen,
                  foregroundColor: Colors.black,
                ),
                onPressed: isSaving ? null : submit,
                child: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        t('Aktualisieren', 'Update'),
                        style: GoogleFonts.inter(fontWeight: FontWeight.w700),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          t('Konto endgültig löschen?', 'Delete account permanently?'),
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(
            'Alle deine Daten (Profil, Posts, Kommentare, Nachrichten) werden unwiderruflich gelöscht. Diese Aktion kann nicht rückgängig gemacht werden.',
            'All your data (profile, posts, comments, messages) will be permanently deleted. This action cannot be undone.',
          ),
          style: GoogleFonts.inter(color: const Color(0xFFCCCCCC), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: GoogleFonts.inter(
                color: appGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t('Konto löschen', 'Delete account'),
              style: GoogleFonts.inter(
                color: const Color(0xFFAA2F2F),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator(color: appGreen)),
      ),
    );
    var progressOpen = true;
    void closeProgress() {
      if (progressOpen && mounted) {
        progressOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    try {
      // The edge function removes the user's photos, clips and profile
      // picture from storage, then deletes all rows and the auth user
      // (public.delete_own_account).
      final client = Supabase.instance.client;
      await client.functions.invoke('delete-account');
      closeProgress();
      await signOutSideQuest();

      if (mounted) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      closeProgress();
      if (!mounted) return;
      _showSettingsSnack(
        t(
          'Kontolöschung fehlgeschlagen. Bitte kontaktiere support@sidequest.app',
          'Account deletion failed. Please contact support@sidequest.app',
        ),
      );
    }
  }

  void _showLegalSheet({required String title, required String body}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: 0.86,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF2A2A2A)),
                Expanded(
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: SelectableText(
                        body,
                        style: GoogleFonts.inter(
                          color: const Color(0xFFDDDDDD),
                          fontSize: 13,
                          height: 1.5,
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

  Widget _buildToggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool value) onChanged,
    String? enabledMessage,
    String? disabledMessage,
  }) {
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.82,
      maxScale: 1.0,
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                    fontSize: 15 * scale,
                    color: textPrimary,
                  ),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 12 * scale,
                    color: textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 12 * scale),
          Switch(
            value: value,
            onChanged: (nextValue) async {
              await onChanged(nextValue);
              if (!mounted) return;
              _showSettingsSnack(
                nextValue
                    ? (enabledMessage ??
                          t('Einstellung aktiviert.', 'Setting enabled.'))
                    : (disabledMessage ??
                          t('Einstellung deaktiviert.', 'Setting disabled.')),
              );
            },
            activeThumbColor: appGreen,
            activeTrackColor: appGreen.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required List<Widget> children,
    Color? iconColor,
    Widget? leading,
  }) {
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;
    final resolvedIconColor = iconColor ?? accentGreen;
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.82,
      maxScale: 1.0,
    );
    final cardBorderRadius = BorderRadius.circular(20 * scale);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1C1C1C), Color(0xFF161616)],
        ),
        borderRadius: cardBorderRadius,
        border: Border.all(color: const Color(0xFF2D2D2D)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.symmetric(
            horizontal: 18 * scale,
            vertical: 4 * scale,
          ),
          childrenPadding: EdgeInsets.fromLTRB(
            18 * scale,
            0,
            18 * scale,
            18 * scale,
          ),
          backgroundColor: Colors.transparent,
          collapsedBackgroundColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide.none,
          ),
          collapsedShape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide.none,
          ),
          iconColor: textSecondary,
          collapsedIconColor: textSecondary,
          leading:
              leading ?? Icon(icon, color: resolvedIconColor, size: 24 * scale),
          title: Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 16 * scale,
              fontWeight: FontWeight.w700,
              color: textPrimary,
            ),
          ),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12 * scale,
                    color: textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
          children: children,
        ),
      ),
    );
  }

  Widget _buildAccountHeaderAvatar() {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.82,
      maxScale: 1.0,
    );
    final imageProvider = sideQuestCachedImageProvider(
      _currentAccountAvatarUrl,
      cacheWidth: (84 * scale).round(),
      cacheHeight: (84 * scale).round(),
    );

    return Container(
      width: 34 * scale,
      height: 34 * scale,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFF9ED57C).withValues(alpha: 0.75),
          width: 1.4 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9ED57C).withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: CircleAvatar(
        radius: 17 * scale,
        backgroundColor: const Color(0xFF1A2217),
        backgroundImage: imageProvider,
        child: imageProvider == null
            ? Text(
                _currentAccountInitial,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14 * scale,
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    Color? iconColor,
    Color? textColor,
    IconData trailingIcon = Icons.chevron_right_rounded,
  }) {
    const defaultTextColor = Colors.white;
    const subtitleColor = Color(0xFFAAAAAA);
    final resolvedIconColor =
        iconColor ?? Theme.of(context).colorScheme.primary;
    final resolvedTextColor = textColor ?? defaultTextColor;
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.82,
      maxScale: 1.0,
    );

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: resolvedIconColor, size: 20 * scale),
      title: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 14 * scale,
          fontWeight: FontWeight.w700,
          color: resolvedTextColor,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12 * scale,
                color: subtitleColor,
                fontWeight: FontWeight.w600,
              ),
            ),
      trailing: Icon(
        trailingIcon,
        color: const Color(0xFFAAAAAA),
        size: 18 * scale,
      ),
      onTap: onTap,
    );
  }

  Widget _buildGrowthHeroCard() {
    const borderColor = Color(0xFF274135);
    final accentGreen = Theme.of(context).colorScheme.primary;
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.8,
      maxScale: 1.0,
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20 * scale),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101512), Color(0xFF1A231E)],
        ),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        16 * scale,
        14 * scale,
        16 * scale,
        14 * scale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28 * scale,
                height: 28 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFC34D), Color(0xFFFF6B57)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF8A4C).withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.rocket_launch_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 10 * scale),
              Expanded(
                child: Text(
                  t('Mach SideQuest größer', 'Grow SideQuest'),
                  style: GoogleFonts.inter(
                    fontSize: 16 * scale,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 4 * scale),
          Text(
            t(
              'Lade Leute ein, hol dir eine Bewertung oder schick direkt Feedback.',
              'Invite people, ask for a rating, or send feedback right away.',
            ),
            style: GoogleFonts.inter(
              fontSize: 12.5 * scale,
              height: 1.35,
              color: Colors.white.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 12 * scale),
          LayoutBuilder(
            builder: (context, constraints) {
              final buttons = <Widget>[
                _buildCompactGrowthButton(
                  icon: Icons.group_add_rounded,
                  label: t('Einladen', 'Invite'),
                  onTap: _shareSideQuest,
                  color: accentGreen,
                ),
                _buildCompactGrowthButton(
                  icon: Icons.star_rounded,
                  label: t('Bewerten', 'Rate'),
                  onTap: _rateApp,
                  color: Colors.white,
                  iconColor: const Color(0xFFFFC83D),
                ),
                _buildCompactGrowthButton(
                  icon: Icons.mark_chat_unread_rounded,
                  label: t('Feedback', 'Feedback'),
                  onTap: _sendFeedback,
                  color: Colors.white,
                  iconColor: const Color(0xFF6FD3FF),
                ),
              ];
              final spacing = 8 * scale;

              if (constraints.maxWidth < 345) {
                final buttonWidth = constraints.maxWidth < 280
                    ? constraints.maxWidth
                    : (constraints.maxWidth - spacing) / 2;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: buttons
                      .map(
                        (button) => SizedBox(width: buttonWidth, child: button),
                      )
                      .toList(),
                );
              }

              return Row(
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) SizedBox(width: spacing),
                    Expanded(child: buttons[i]),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCompactGrowthButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
    Color? iconColor,
  }) {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.8,
      maxScale: 1.0,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(12 * scale),
      onTap: onTap,
      child: Container(
        height: 42 * scale,
        padding: EdgeInsets.symmetric(horizontal: 10 * scale),
        decoration: BoxDecoration(
          color: color.withValues(alpha: color == Colors.white ? 0.06 : 0.14),
          borderRadius: BorderRadius.circular(12 * scale),
          border: Border.all(
            color: color.withValues(alpha: color == Colors.white ? 0.10 : 0.24),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18 * scale, color: iconColor ?? color),
            SizedBox(width: 6 * scale),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11.5 * scale,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const darkBg = Color(0xFF121212);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        toolbarHeight: 56,
        titleSpacing: 0,
        iconTheme: IconThemeData(color: accentGreen),
        title: Text(
          t('Einstellungen', 'Settings'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 23,
            fontWeight: FontWeight.w800,
            color: textPrimary,
          ),
        ),
        elevation: 0,
      ),
      body: loadingPrefs
          ? Center(child: CircularProgressIndicator(color: accentGreen))
          : Stack(
              children: [
                Positioned(
                  top: -130,
                  right: -90,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          accentGreen.withValues(alpha: 0.16),
                          accentGreen.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 220,
                  left: -120,
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.05),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                  children: [
                    _buildGrowthHeroCard(),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.person_outline_rounded,
                      title: t('Mein Konto', 'My account'),
                      subtitle: _currentUserEmail.isEmpty
                          ? t(
                              'E-Mail, Passwort und Kontolöschung',
                              'Email, password, and account deletion',
                            )
                          : _currentUserEmail,
                      leading: _buildAccountHeaderAvatar(),
                      children: [
                        _buildActionTile(
                          icon: Icons.alternate_email_rounded,
                          iconColor: const Color(0xFF7BC5FF),
                          title: t('E-Mail', 'Email'),
                          subtitle: _currentUserEmail.isEmpty
                              ? t(
                                  'Keine E-Mail verfügbar',
                                  'No email available',
                                )
                              : t(
                                  'Aktuell: $_currentUserEmail',
                                  'Current: $_currentUserEmail',
                                ),
                          onTap: _showChangeEmailDialog,
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        _buildActionTile(
                          icon: Icons.lock_outline_rounded,
                          iconColor: const Color(0xFFFFD166),
                          title: t('Passwort ändern', 'Change password'),
                          subtitle: t(
                            'Zum Ändern zuerst altes Passwort eingeben',
                            'Enter current password before changing it',
                          ),
                          onTap: _showChangePasswordDialog,
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        _buildActionTile(
                          icon: Icons.delete_forever_rounded,
                          iconColor: const Color(0xFFAA2F2F),
                          textColor: const Color(0xFFFFC3C3),
                          title: t('Konto löschen', 'Delete account'),
                          subtitle: t(
                            'Diese Aktion ist dauerhaft',
                            'This action is permanent',
                          ),
                          onTap: _confirmDeleteAccount,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.language_rounded,
                      title: t('Sprache', 'Language'),
                      subtitle: _selectedLanguageLabel,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Deutsch',
                            style: GoogleFonts.inter(color: textPrimary),
                          ),
                          trailing: selectedLanguageCode == 'de'
                              ? Icon(Icons.check_rounded, color: accentGreen)
                              : null,
                          onTap: () async {
                            if (selectedLanguageCode == 'de') return;
                            await languageController.setLanguage('de');
                            if (!mounted) return;
                            setState(() => selectedLanguageCode = 'de');
                            _showSettingsSnack(
                              t('Sprache gespeichert.', 'Language saved.'),
                            );
                          },
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'English',
                            style: GoogleFonts.inter(color: textPrimary),
                          ),
                          trailing: selectedLanguageCode == 'en'
                              ? Icon(Icons.check_rounded, color: accentGreen)
                              : null,
                          onTap: () async {
                            if (selectedLanguageCode == 'en') return;
                            await languageController.setLanguage('en');
                            if (!mounted) return;
                            setState(() => selectedLanguageCode = 'en');
                            _showSettingsSnack(
                              t('Sprache gespeichert.', 'Language saved.'),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.notifications_none_rounded,
                      title: t('Benachrichtigungen', 'Notifications'),
                      subtitle: t(
                        '$_activeNotificationCount aktiv',
                        '$_activeNotificationCount enabled',
                      ),
                      iconColor: const Color(0xFFFFD166),
                      children: [
                        _buildToggleTile(
                          title: t('Wenn Freunde posten', 'When friends post'),
                          subtitle: t(
                            'Updates, wenn deine Freunde etwas hochladen.',
                            'Updates when your friends post.',
                          ),
                          value: notifyFriendsPosts,
                          onChanged: (value) async {
                            await NotificationPrefs.setFriendsPosts(value);
                            if (!mounted) return;
                            setState(() => notifyFriendsPosts = value);
                          },
                        ),
                        _buildToggleTile(
                          title: t(
                            'Wenn die Quest gleich endet',
                            'When the quest is ending soon',
                          ),
                          subtitle: t(
                            'Erinnerung kurz vor Ablauf.',
                            'Reminder shortly before it ends.',
                          ),
                          value: notifyChallengeEnding,
                          onChanged: (value) async {
                            await NotificationPrefs.setChallengeEnding(value);
                            if (!mounted) return;
                            setState(() => notifyChallengeEnding = value);
                          },
                        ),
                        _buildToggleTile(
                          title: t(
                            'Wenn eine neue Quest startet',
                            'When a new quest starts',
                          ),
                          subtitle: t(
                            'Sofort-Info bei neuen Quests.',
                            'Instant heads-up for new quests.',
                          ),
                          value: notifyChallengeStart,
                          onChanged: (value) async {
                            await NotificationPrefs.setChallengeStart(value);
                            if (!mounted) return;
                            setState(() => notifyChallengeStart = value);
                          },
                        ),
                        _buildToggleTile(
                          title: t(
                            'Wenn dich jemand zum Duell herausfordert',
                            'When someone challenges you to a duel',
                          ),
                          subtitle: t(
                            'Benachrichtigung bei neuen Anfragen.',
                            'Notification for new requests.',
                          ),
                          value: notifyChallenged,
                          onChanged: (value) async {
                            await NotificationPrefs.setChallenged(value);
                            if (!mounted) return;
                            setState(() => notifyChallenged = value);
                          },
                        ),
                        _buildToggleTile(
                          title: t(
                            'Wenn dir jemand schreibt',
                            'When someone messages you',
                          ),
                          subtitle: t(
                            'Infos zu neuen Nachrichten.',
                            'Heads-up for new messages.',
                          ),
                          value: notifyMessages,
                          onChanged: (value) async {
                            await NotificationPrefs.setMessages(value);
                            if (!mounted) return;
                            setState(() => notifyMessages = value);
                          },
                        ),
                        // Developer tool: only in debug builds.
                        if (kDebugMode) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accentGreen,
                                foregroundColor: Colors.black,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(
                                Icons.notifications_active_rounded,
                              ),
                              label: Text(
                                t(
                                  'Test-Benachrichtigung senden',
                                  'Send test notification',
                                ),
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onPressed: () async {
                                await NotificationService.instance
                                    .showNotification(
                                      title: 'SideQuest',
                                      body: t(
                                        'Das ist eine Test-Benachrichtigung.',
                                        'This is a test notification.',
                                      ),
                                    );
                                _showSettingsSnack(t('Gesendet.', 'Sent.'));
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.privacy_tip_outlined,
                      title: t('Privatsphäre', 'Privacy'),
                      subtitle: _privacySummary,
                      iconColor: const Color(0xFF8FE388),
                      children: [
                        _buildToggleTile(
                          title: t(
                            'Posts standardmäßig öffentlich',
                            'Default posts to public',
                          ),
                          subtitle: t(
                            'Die Post-Vorschau startet mit Öffentlich statt Freunde.',
                            'The post preview starts with Public instead of Friends.',
                          ),
                          value: defaultPostPublic,
                          onChanged: (value) async {
                            await UserAppSettingsPrefs.setDefaultPostPublic(
                              value,
                            );
                            if (!mounted) return;
                            setState(() => defaultPostPublic = value);
                          },
                        ),
                        _buildToggleTile(
                          title: t(
                            'Über verknüpfte Kontakte auffindbar',
                            'Discoverable through linked contacts',
                          ),
                          subtitle: t(
                            'Dein Account taucht nur in Kontakt-Treffern auf, wenn das aktiviert ist. Suche und normale Vorschläge bleiben unverändert.',
                            'Your account only appears in contact matches when this is enabled. Search and regular suggestions stay unchanged.',
                          ),
                          value: allowContactDiscovery,
                          onChanged: (value) async {
                            await UserAppSettingsPrefs.setAllowContactDiscovery(
                              value,
                            );
                            if (!mounted) return;
                            setState(() => allowContactDiscovery = value);
                          },
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: accentGreen,
                              side: BorderSide(
                                color: accentGreen.withValues(alpha: 0.5),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _linkingContacts
                                ? null
                                : _linkContactsNow,
                            icon: _linkingContacts
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: accentGreen,
                                    ),
                                  )
                                : const Icon(Icons.contacts_rounded),
                            label: Text(
                              t(
                                'Kontakte jetzt verknüpfen',
                                'Link contacts now',
                              ),
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.block_outlined,
                      title: t('Blockierte Nutzer', 'Blocked users'),
                      subtitle: _loadingBlockedUsers
                          ? t('Wird geladen...', 'Loading...')
                          : _blockedUsers.isEmpty
                          ? t('Niemand blockiert', 'No blocked users')
                          : t(
                              '${_blockedUsers.length} blockiert',
                              '${_blockedUsers.length} blocked',
                            ),
                      iconColor: const Color(0xFFFF7A7A),
                      children: _loadingBlockedUsers
                          ? [
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ]
                          : _blockedUsers.isEmpty
                          ? [
                              Text(
                                t(
                                  'Du hast aktuell niemanden blockiert.',
                                  'You have not blocked anyone yet.',
                                ),
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: textSecondary,
                                ),
                              ),
                            ]
                          : _blockedUsers
                                .map((user) {
                                  final isBusy = _updatingBlockedUserIds
                                      .contains(user.id);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 22,
                                          backgroundColor: const Color(
                                            0xFF2A2A2A,
                                          ),
                                          backgroundImage:
                                              user.profilePicture != null
                                              ? sideQuestCachedImageProvider(
                                                  user.profilePicture!,
                                                  cacheWidth:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        44,
                                                      ),
                                                  cacheHeight:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        44,
                                                      ),
                                                )
                                              : null,
                                          child: user.profilePicture == null
                                              ? Text(
                                                  user.username.isNotEmpty
                                                      ? user.username[0]
                                                            .toUpperCase()
                                                      : 'U',
                                                  style: GoogleFonts.inter(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            user.username,
                                            style: GoogleFonts.inter(
                                              color: textPrimary,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: isBusy
                                              ? null
                                              : () => _unblockUser(user.id),
                                          child: isBusy
                                              ? SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: accentGreen,
                                                      ),
                                                )
                                              : Text(
                                                  t('Entblocken', 'Unblock'),
                                                  style: GoogleFonts.inter(
                                                    color: accentGreen,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  );
                                })
                                .toList(growable: false),
                    ),
                    if (_isAdmin) ...[
                      const SizedBox(height: 12),
                      _buildSectionCard(
                        icon: Icons.shield_outlined,
                        title: t('Moderation', 'Moderation'),
                        subtitle: t(
                          'Meldungen prüfen und bearbeiten',
                          'Review reports',
                        ),
                        iconColor: const Color(0xFFE5484D),
                        children: [
                          _buildActionTile(
                            icon: Icons.flag_outlined,
                            title: t('Meldungen öffnen', 'Open reports'),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ModerationScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.gavel_rounded,
                      title: t('Rechtliches', 'Legal'),
                      subtitle: t(
                        'Nutzungsbedingungen und Datenschutz',
                        'Terms and privacy',
                      ),
                      iconColor: const Color(0xFFFFB86B),
                      children: [
                        ValueListenableBuilder<bool?>(
                          valueListenable: AnalyticsConsent.granted,
                          builder: (context, granted, _) => _buildToggleTile(
                            title: t(
                              'Statistiken & Absturzberichte',
                              'Statistics & crash reports',
                            ),
                            subtitle: t(
                              'Firebase Analytics und Crashlytics, um die App zu verbessern.',
                              'Firebase Analytics and Crashlytics to improve the app.',
                            ),
                            value: granted == true,
                            onChanged: AnalyticsConsent.set,
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.description_outlined,
                            color: accentGreen,
                            size: 20,
                          ),
                          title: Text(
                            t('Nutzungsbedingungen', 'Terms of Use'),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFAAAAAA),
                          ),
                          onTap: () => _showLegalSheet(
                            title: t('Nutzungsbedingungen', 'Terms of Use'),
                            body: sideQuestTermsOfUseText(),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.privacy_tip_outlined,
                            color: accentGreen,
                            size: 20,
                          ),
                          title: Text(
                            t('Datenschutzerklärung', 'Privacy Policy'),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFAAAAAA),
                          ),
                          onTap: () => _showLegalSheet(
                            title: t('Datenschutzerklärung', 'Privacy Policy'),
                            body: sideQuestPrivacyPolicyText(),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.business_outlined,
                            color: accentGreen,
                            size: 20,
                          ),
                          title: Text(
                            t('Impressum', 'Legal Notice'),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.open_in_new_rounded,
                            color: Color(0xFFAAAAAA),
                            size: 18,
                          ),
                          onTap: () => launchUrl(
                            Uri.parse(AppEnvironment.imprintUrl),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFF2A2A2A)),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.groups_outlined,
                            color: accentGreen,
                            size: 20,
                          ),
                          title: Text(
                            t('Community-Richtlinien', 'Community Guidelines'),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.open_in_new_rounded,
                            color: Color(0xFFAAAAAA),
                            size: 18,
                          ),
                          onTap: () => launchUrl(
                            Uri.parse(AppEnvironment.guidelinesUrl),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSectionCard(
                      icon: Icons.info_outline_rounded,
                      title: t('Über SideQuest', 'About SideQuest'),
                      subtitle: _appVersion.isEmpty
                          ? null
                          : 'Version $_appVersion',
                      iconColor: const Color(0xFF8DBEFF),
                      children: [
                        Text(
                          t(
                            'SideQuest ist für tägliche Foto-Quests mit Freunden gemacht. Teile Momente, fordere Leute zum Duell heraus und halte deine Streak am Leben.',
                            'SideQuest is built for daily photo quests with friends. Share moments, challenge people to duels, and keep your streak alive.',
                          ),
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: textSecondary,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          AppEnvironment.websiteUrl,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: accentGreen,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFAA2F2F),
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: const Icon(Icons.logout, color: Colors.white),
                        label: Text(
                          t('Abmelden', 'Log out'),
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: () async {
                          await AnalyticsService.logLogout();
                          await signOutSideQuest();
                          if (context.mounted) {
                            Navigator.of(
                              context,
                              rootNavigator: true,
                            ).popUntil((route) => route.isFirst);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
