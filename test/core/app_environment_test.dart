import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/core/app_environment.dart';

void main() {
  test('default environment values are set', () {
    expect(AppEnvironment.appName, isNotEmpty);
    expect(AppEnvironment.supabaseUrl, startsWith('https://'));
    expect(AppEnvironment.supabaseAnonKey, isNotEmpty);
    expect(AppEnvironment.supportEmail, contains('@'));
  });

  test('legal urls are parseable', () {
    final terms = Uri.tryParse(AppEnvironment.termsUrl);
    final privacy = Uri.tryParse(AppEnvironment.privacyUrl);

    expect(terms, isNotNull);
    expect(privacy, isNotNull);
    expect(terms!.hasAbsolutePath, isTrue);
    expect(privacy!.hasAbsolutePath, isTrue);
  });
}
