/// Runtime configuration sourced from compile-time `--dart-define` flags.
///
/// Default values are provided for development convenience only.
/// **IMPORTANT**: For production builds, always supply real values via
/// `--dart-define` or `--dart-define-from-file` and **never** commit
/// production secrets to version control.
class AppEnvironment {
  AppEnvironment._();

  static const String appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'SideQuest',
  );

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://cuvmtajkzgxroedmvfwu.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN1dm10YWpremd4cm9lZG12Znd1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ3NTY5NTAsImV4cCI6MjA4MDMzMjk1MH0.aITKP9GFlci3ULG5Igy_zY9S6kvAOcDW-MDPLWb1nis',
  );

  static const String webPushVapidKey = String.fromEnvironment(
    'WEB_PUSH_VAPID_KEY',
    defaultValue:
        'BJKxLiQDpkQvgPOmwS_3jA_qLHWfQyvGc9Pn14Q9fqB8Ef5C8I3G2sBmADjD9X6Jdbm_f1jd36pD3S3kBGxoqZ4',
  );

  static const String termsUrl = String.fromEnvironment(
    'TERMS_URL',
    defaultValue: 'https://sidequest.app/legal/terms',
  );

  static const String privacyUrl = String.fromEnvironment(
    'PRIVACY_URL',
    defaultValue: 'https://sidequest.app/legal/privacy',
  );

  static const String supportEmail = String.fromEnvironment(
    'SUPPORT_EMAIL',
    defaultValue: 'support@sidequest.app',
  );

  static const String websiteUrl = String.fromEnvironment(
    'WEBSITE_URL',
    defaultValue: 'https://sidequest.app',
  );

  /// Friend invite links: `<base>?u=<username>` (edge function `invite`).
  /// Switch to our own domain (e.g. https://sidequest.app/u) once it exists.
  static const String inviteLinkBase = String.fromEnvironment(
    'INVITE_LINK_BASE',
    defaultValue: 'https://cuvmtajkzgxroedmvfwu.supabase.co/functions/v1/invite',
  );

  static const String googlePlayStoreUrl = String.fromEnvironment(
    'GOOGLE_PLAY_STORE_URL',
    defaultValue: 'https://play.google.com/store/apps/details?id=app.sidequest',
  );

  static const String appleAppStoreUrl = String.fromEnvironment(
    'APPLE_APP_STORE_URL',
    defaultValue: 'https://apps.apple.com/search?term=SideQuest',
  );

  static const String imprintUrl = String.fromEnvironment(
    'IMPRINT_URL',
    defaultValue: 'https://sidequest.app/legal/imprint',
  );

  static const String guidelinesUrl = String.fromEnvironment(
    'GUIDELINES_URL',
    defaultValue: 'https://sidequest.app/legal/guidelines',
  );

  /// Custom deep-link callback used by Supabase mobile OAuth flows.
  static const String mobileAuthRedirectUrl = String.fromEnvironment(
    'MOBILE_AUTH_REDIRECT_URL',
    defaultValue: 'io.supabase.sidequest://login-callback/',
  );

  /// Google OAuth **Server** (Web) Client ID used by Supabase.
  /// This is the *web* client-id you entered in the Supabase Dashboard.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '892815395656-bo2nbd2tkr5lamj5t2s8etkt5djds4ak.apps.googleusercontent.com',
  );

  static const bool verboseLogs = bool.fromEnvironment(
    'VERBOSE_LOGS',
    defaultValue: false,
  );
}
