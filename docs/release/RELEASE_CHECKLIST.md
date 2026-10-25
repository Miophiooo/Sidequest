# SideQuest Release Checklist

## 1. Product identity
- Set Android `APP_ID` and `APP_NAME` in `android/gradle.properties`.
- Never ship the placeholder Android package id `com.example.nummwe3`.
- Set iOS `APP_BUNDLE_ID`, `APP_DISPLAY_NAME`, `APPLE_TEAM_ID` in `ios/Flutter/AppConfig.xcconfig`.
- Verify app name in both stores and on launcher/home screen.

## 2. Signing and provisioning
- Copy `android/key.properties.example` to `android/key.properties` and fill real values.
- Ensure keystore file exists at the configured `storeFile` path.
- Release builds must fail until real signing values are present; do not use debug signing as a fallback.
- In Xcode, configure Team, certificates, and provisioning profiles.

## 3. Firebase and push
- Replace `android/app/google-services.json` with the file matching the final Android package.
- Copy `ios/Runner/GoogleService-Info.plist.example` to `ios/Runner/GoogleService-Info.plist` and fill real values.
- Add `io.supabase.sidequest://login-callback/` to Supabase Auth -> Redirect URLs.
- Validate push notifications on physical Android and iOS devices.
- Confirm the release manifest does not include `AD_ID` or related ad service permissions unless ads are intentionally enabled and disclosed.

## 4. Privacy and legal
- Publish legal documents at durable URLs:
  - Terms: `TERMS_URL`
  - Privacy: `PRIVACY_URL`
- Publish a public account deletion page:
  - Delete account: `https://sidequest.app/delete-account.html`
- Verify support contact in app: `SUPPORT_EMAIL`.
- Complete Play Console Data Safety and App Store privacy labels.

## 5. Quality gates
- `flutter analyze` passes.
- `flutter test` passes.
- Android release smoke build passes.
- iOS release smoke build (`--no-codesign`) passes where available.

## 6. Go / No-Go thresholds
- No open P0 bugs.
- Crash-free sessions >= 99.5% over first 72h rollout cohort.
- Auth, upload, daily challenge, and notifications validated end-to-end.

## 7. Rollout plan
- Android staged rollout: 10% -> 25% -> 50% -> 100%.
- iOS: TestFlight internal -> TestFlight external -> App Store release.
- Keep hotfix branch ready for `1.0.1+2`.
