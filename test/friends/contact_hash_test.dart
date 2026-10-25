import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/friend_discovery.dart';

void main() {
  test('contact e-mail hash matches the server (internal.email_hash)', () {
    // Value computed by internal.email_hash('  Max.Müller@Example.com ').
    expect(
      FriendDiscoveryService.contactEmailHash('  Max.Müller@Example.com '),
      'f13114ed36c69254a63decd6d28acc79fb3784ccc0ec7404362e7a3ddc8bbd85',
    );
  });

  test('normalizes case and surrounding spaces', () {
    expect(
      FriendDiscoveryService.contactEmailHash('MAX@example.com'),
      FriendDiscoveryService.contactEmailHash(' max@example.com '),
    );
  });
}
