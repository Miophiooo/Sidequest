import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/features/invite/invite_links.dart';

void main() {
  test('app-scheme invite link yields the username', () {
    expect(
      InviteLinks.usernameFrom(
        Uri.parse('io.supabase.sidequest://invite?u=moin'),
      ),
      'moin',
    );
    expect(
      InviteLinks.usernameFrom(
        Uri.parse('io.supabase.sidequest://invite?u=J%C3%B6rg_7'),
      ),
      'Jörg_7',
    );
  });

  test('the shared web link round-trips', () {
    final link = InviteLinks.linkFor('Jörg_7');
    expect(InviteLinks.usernameFrom(Uri.parse(link)), 'Jörg_7');
  });

  test('other links and bad usernames are ignored', () {
    // The auth callback uses the same scheme.
    expect(
      InviteLinks.usernameFrom(
        Uri.parse('io.supabase.sidequest://login-callback/?code=abc'),
      ),
      isNull,
    );
    expect(
      InviteLinks.usernameFrom(Uri.parse('io.supabase.sidequest://invite')),
      isNull,
    );
    expect(
      InviteLinks.usernameFrom(
        Uri.parse('io.supabase.sidequest://invite?u=%3Cscript%3E'),
      ),
      isNull,
    );
    expect(
      InviteLinks.usernameFrom(Uri.parse('https://evil.example/invite?u=a')),
      isNull,
    );
  });
}
