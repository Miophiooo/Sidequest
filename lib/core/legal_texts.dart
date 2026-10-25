import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../shared.dart';

/// Single source for the legal texts shown at signup, in the consent gate
/// and in the settings. docs/legal/*.md must stay identical.
///
/// Bump [kRequiredLegalVersion] in main.dart on material changes so every
/// user confirms the new version once.

String sideQuestTermsOfUseText() {
  return t(
    '''
Stand: 24. Oktober 2026

1. Geltungsbereich
Diese Nutzungsbedingungen gelten für die Nutzung der SideQuest App. Mit der Registrierung oder Nutzung akzeptierst du diese Bedingungen.

2. Beschreibung des Dienstes
SideQuest ist eine Social-Media-App für tägliche Foto-Quests mit Freunden.

3. Registrierung und Kontosicherheit
- Mindestalter: 13 Jahre.
- Du bist für dein Konto und dein Passwort verantwortlich.
- Keine falschen Identitäten oder Impersonation.
- Nur ein Konto pro Person.

4. Verhaltensregeln
Nicht gestattet sind:
- Hassrede, Beleidigungen, Bedrohungen, Diskriminierung, Mobbing
- Sexuell explizite Inhalte oder Nacktheit
- Gewaltverherrlichung
- Spam, automatisierte Aktionen, Manipulation
- Umgehung von Sicherheits- oder Moderationsfunktionen
- Doxxing (Veröffentlichung personenbezogener Daten Dritter)
- Illegale Inhalte jeglicher Art

5. Inhalte der Nutzer
- Du behältst alle Rechte an deinen Inhalten.
- Du räumst SideQuest ein nicht-exklusives, widerrufliches Recht ein, Inhalte innerhalb der App anzuzeigen.

6. Moderation und Null Toleranz
Für anstößige Inhalte und missbräuchliches Verhalten gilt null Toleranz. Du kannst Posts, Kommentare und Nachrichten jederzeit melden und Nutzer blockieren. Meldungen prüfen wir in der Regel innerhalb von 24 Stunden. Verstöße entfernen wir, und die verantwortlichen Konten können gesperrt werden – bei schweren oder wiederholten Verstößen dauerhaft.

7. Kontolöschung
Du kannst dein Konto jederzeit in den Einstellungen löschen.

8. Haftungsausschluss
SideQuest wird „wie besehen" bereitgestellt. Keine Gewähr für ununterbrochene Verfügbarkeit.

9. Änderungen
Wesentliche Änderungen werden in der App bekanntgegeben.

10. Kontakt
support@sidequest.app
''',
    '''
Effective date: October 24, 2026

1. Scope
These Terms of Use govern your use of the SideQuest app. By registering or using the app, you accept these terms.

2. Description of service
SideQuest is a social media app for daily photo quests with friends.

3. Registration and account security
- Minimum age: 13 years.
- You are responsible for your account and password.
- No fake identities or impersonation.
- One account per person only.

4. Code of conduct
The following is prohibited:
- Hate speech, abuse, threats, discrimination, bullying
- Sexually explicit content or nudity
- Glorification of violence
- Spam, automated actions, manipulation
- Circumventing security or moderation features
- Doxxing (publishing others' personal data)
- Any illegal content

5. User content
- You retain all rights to your content.
- You grant SideQuest a non-exclusive, revocable license to display content within the app.

6. Moderation and zero tolerance
There is zero tolerance for objectionable content and abusive behavior. You can report posts, comments and messages and block users at any time. We usually review reports within 24 hours. We remove violating content and may suspend the responsible accounts – permanently for serious or repeated violations.

7. Account deletion
You can delete your account at any time in the app settings.

8. Disclaimer
SideQuest is provided "as is." No guarantee of uninterrupted availability.

9. Changes
Material updates are announced in the app.

10. Contact
support@sidequest.app
''',
  );
}

String sideQuestPrivacyPolicyText() {
  return t(
    '''
Stand: 22. Oktober 2026

1. Verantwortlicher
[VOR- UND NACHNAME]
[STRASSE HAUSNUMMER]
[PLZ ORT], Deutschland
E-Mail: support@sidequest.app

2. Verarbeitete Daten
- Kontodaten: E-Mail, Passwort-Hash, Nutzername; bei Anmeldung mit Apple oder Google die von dort übermittelte Kennung und E-Mail (Art. 6 Abs. 1 lit. b DSGVO)
- Profildaten: Profilbild, optional (Art. 6 Abs. 1 lit. b)
- Inhalte: Posts, Kommentare, Likes, Nachrichten, Duelle, Einladungscodes (Art. 6 Abs. 1 lit. b)
- Ortsangabe: ein von dir eingegebener Ort zu einem Post, optional (Art. 6 Abs. 1 lit. a)
- Kontakte: werden nur auf deinem Gerät mit Nutzernamen abgeglichen und nicht hochgeladen, optional (Art. 6 Abs. 1 lit. a)
- Push-Token und Geräteplattform für Benachrichtigungen (Art. 6 Abs. 1 lit. b)
- Meldungen und Moderation: gemeldete Inhalte, Meldende, getroffene Maßnahmen (Art. 6 Abs. 1 lit. c und f, Pflichten nach dem Digital Services Act)
- Nutzungsstatistiken und Absturzberichte: nur mit deiner Einwilligung (Art. 6 Abs. 1 lit. a DSGVO, § 25 Abs. 1 TDDDG)

3. Zweck
- Betrieb der App (Quests, Duelle, Posts, Chat)
- Missbrauchsprävention, Moderation und Sicherheit
- Benachrichtigungen und Quest-Erinnerungen (Erinnerungen werden teils lokal auf dem Gerät geplant)
- Verbesserung der App und Fehlerbehebung (nur mit Einwilligung)

4. Einwilligung und Widerruf
Beim ersten Start fragen wir, ob wir Nutzungsstatistiken (Google Firebase Analytics) und Absturzberichte (Google Firebase Crashlytics) erheben dürfen. Ohne Zustimmung wird nichts davon gesendet. Du kannst die Einwilligung jederzeit unter Einstellungen > Rechtliches > Statistiken & Absturzberichte widerrufen. Werbe-IDs werden nicht erhoben, und wir zeigen keine Werbung.

5. Dienstleister
- Supabase (Datenbank, Anmeldung, Speicher): Server in der EU (Frankfurt)
- Google Firebase (Push-Benachrichtigungen; Analytics und Crashlytics nur mit Einwilligung): Google Ireland Ltd.; eine Übermittlung in die USA ist möglich, abgesichert durch das EU-US Data Privacy Framework und EU-Standardvertragsklauseln
- Apple und Google, wenn du dich mit deren Konto anmeldest
Schriftarten sind in die App eingebettet; dafür werden keine Daten an Google Fonts gesendet.

6. Speicherdauer
- Kontodaten und Inhalte: bis zur Löschung durch dich oder bis zur Kontolöschung
- Meldungen und Moderationsprotokoll: max. 12 Monate nach Bearbeitung
- Absturzberichte: max. 90 Tage
- Nutzungsstatistiken: max. 14 Monate
- Technische Server-Logs: max. 90 Tage

7. Deine Rechte (Art. 15–21 DSGVO)
- Auskunft über gespeicherte Daten
- Berichtigung unrichtiger Daten
- Löschung (inkl. Kontolöschung in den Einstellungen)
- Einschränkung der Verarbeitung
- Datenübertragbarkeit
- Widerspruch gegen Verarbeitung
- Widerruf erteilter Einwilligungen mit Wirkung für die Zukunft
- Beschwerde bei einer Datenschutz-Aufsichtsbehörde

Anfragen an: support@sidequest.app

8. Kein Verkauf von Daten
Wir verkaufen keine personenbezogenen Daten.

9. Datensicherheit
Alle Übertragungen sind verschlüsselt (TLS). Der Zugriff auf Daten ist durch Row-Level-Security beschränkt; Fotos liegen in einem privaten Speicher.

10. Änderungen
Wesentliche Änderungen werden in der App bekanntgegeben.
''',
    '''
Effective date: October 22, 2026

1. Data controller
[FULL NAME]
[STREET AND NUMBER]
[POSTCODE CITY], Germany
Email: support@sidequest.app

2. Data we process
- Account data: email, password hash, username; when signing in with Apple or Google, the identifier and email they provide (Art. 6(1)(b) GDPR)
- Profile data: profile picture, optional (Art. 6(1)(b))
- Content: posts, comments, likes, messages, duels, invite codes (Art. 6(1)(b))
- Place: a place name you enter for a post, optional (Art. 6(1)(a))
- Contacts: matched with usernames on your device only and never uploaded, optional (Art. 6(1)(a))
- Push token and device platform for notifications (Art. 6(1)(b))
- Reports and moderation: reported content, reporters, actions taken (Art. 6(1)(c) and (f), Digital Services Act obligations)
- Usage statistics and crash reports: only with your consent (Art. 6(1)(a) GDPR, Section 25(1) TDDDG)

3. Purpose
- Operating the app (quests, duels, posts, chat)
- Abuse prevention, moderation and security
- Notifications and quest reminders (some reminders are scheduled locally on the device)
- Improving the app and fixing errors (only with consent)

4. Consent and withdrawal
On first launch we ask whether we may collect usage statistics (Google Firebase Analytics) and crash reports (Google Firebase Crashlytics). Nothing of this is sent without your consent. You can withdraw it any time under Settings > Legal > Statistics & crash reports. We do not collect advertising IDs and show no ads.

5. Service providers
- Supabase (database, sign-in, storage): servers in the EU (Frankfurt)
- Google Firebase (push notifications; Analytics and Crashlytics only with consent): Google Ireland Ltd.; data may be transferred to the USA under the EU-US Data Privacy Framework and EU Standard Contractual Clauses
- Apple and Google, if you sign in with their account
Fonts are bundled with the app; no data is sent to Google Fonts.

6. Retention
- Account data and content: until you delete them or your account
- Reports and moderation log: max. 12 months after review
- Crash reports: max. 90 days
- Usage statistics: max. 14 months
- Technical server logs: max. 90 days

7. Your rights (Art. 15–21 GDPR)
- Access your stored data
- Rectification of inaccurate data
- Erasure (including account deletion in settings)
- Restriction of processing
- Data portability
- Object to processing
- Withdraw consent at any time with effect for the future
- Lodge a complaint with a data protection authority

Requests to: support@sidequest.app

8. No sale of data
We do not sell personal data to third parties.

9. Data security
All transmissions are encrypted (TLS). Data access is restricted through row-level security; photos are kept in private storage.

10. Changes
Material changes will be announced in the app.
''',
  );
}

/// Shows a legal text in a scrollable bottom sheet (light style, used by
/// the consent gate).
Future<void> showSideQuestLegalSheet(
  BuildContext context, {
  required String title,
  required String body,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
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
                      style: GoogleFonts.inter(
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
                    style: GoogleFonts.inter(
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
    ),
  );
}
