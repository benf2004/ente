import 'package:ente_auth/models/profile.dart';
import 'package:ente_auth/ui/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// The settings header used to read straight from UserService's process wide
/// email notifier, which the sign in flow writes as soon as an address is
/// typed and which nothing repoints when the active profile changes. That
/// showed the previous account's email after a switch, and a typed-then-
/// abandoned address before any sign in had happened.
void main() {
  const stale = "typed-but-never-signed-in@example.org";

  test('prefers the active profile over the notifier', () {
    final subtitle = settingsSubtitle(
      profile: const Profile(
        scope: "acct_1.",
        kind: ProfileKind.online,
        email: "active@example.org",
      ),
      email: stale,
      hasLoggedIn: true,
      offlineFallback: "Offline vault",
    );

    expect(subtitle, "active@example.org");
  });

  test('shows a named vault by its name', () {
    final subtitle = settingsSubtitle(
      profile: const Profile(
        scope: "acct_2.",
        kind: ProfileKind.offline,
        label: "Work laptop",
      ),
      email: stale,
      hasLoggedIn: false,
      offlineFallback: "Offline vault",
    );

    expect(subtitle, "Work laptop");
  });

  test('falls back to the generic name for an unnamed offline vault', () {
    final subtitle = settingsSubtitle(
      profile: const Profile(scope: "acct_3.", kind: ProfileKind.offline),
      email: stale,
      hasLoggedIn: false,
      offlineFallback: "Offline vault",
    );

    expect(subtitle, "Offline vault");
  });

  test('shows nothing when signed out with no profile', () {
    final subtitle = settingsSubtitle(
      profile: null,
      email: stale,
      hasLoggedIn: false,
      offlineFallback: "Offline vault",
    );

    expect(subtitle, isNull);
  });

  test('uses the notifier only when there is no profile yet', () {
    final subtitle = settingsSubtitle(
      profile: null,
      email: "someone@example.org",
      hasLoggedIn: true,
      offlineFallback: "Offline vault",
    );

    expect(subtitle, "someone@example.org");
  });
}
