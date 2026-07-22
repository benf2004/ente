import 'dart:convert';

import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/models/profile.dart';
import 'package:ente_auth/services/profile_service.dart';
import 'package:ente_auth/store/authenticator_db.dart';
import 'package:ente_auth/store/offline_authenticator_db.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('key scoping', () {
    test('the legacy scope leaves keys untouched', () {
      final config = Configuration.instance;

      expect(config.scope, isEmpty);
      expect(config.scopedKey(BaseConfiguration.tokenKey), "token");
      expect(
        config.scopedKey(Configuration.authSecretKeyKey),
        "auth_secret_key",
      );
    });
  });

  group('database naming', () {
    test('the legacy scope keeps the original filenames', () {
      expect(AuthenticatorDB.databaseNameForScope(""), "ente.authenticator.db");
      expect(
        OfflineAuthenticatorDB.databaseNameForScope(""),
        "ente.offline_authenticator.db",
      );
    });

    test('each profile gets its own database files', () {
      expect(
        AuthenticatorDB.databaseNameForScope("acct_1."),
        "ente.acct_1.authenticator.db",
      );
      expect(
        OfflineAuthenticatorDB.databaseNameForScope("acct_1."),
        "ente.acct_1.offline_authenticator.db",
      );
      expect(
        AuthenticatorDB.databaseNameForScope("acct_1."),
        isNot(AuthenticatorDB.databaseNameForScope("acct_2.")),
      );
    });
  });

  group('seeding the profile list', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    test('a fresh install starts with no profiles', () async {
      SharedPreferences.setMockInitialValues({});

      await ProfileService.instance.init();

      expect(ProfileService.instance.profiles, isEmpty);
      expect(ProfileService.instance.activeScope, isEmpty);
      expect(ProfileService.instance.hasMultipleProfiles, isFalse);
    });

    test('an existing account becomes the legacy profile', () async {
      SharedPreferences.setMockInitialValues({
        BaseConfiguration.tokenKey: "a-token",
        BaseConfiguration.userIDKey: 7,
        BaseConfiguration.emailKey: "someone@example.org",
      });

      await ProfileService.instance.init();

      final profiles = ProfileService.instance.profiles;
      expect(profiles, hasLength(1));
      expect(profiles.single.scope, isEmpty);
      expect(profiles.single.kind, ProfileKind.online);
      expect(profiles.single.userID, 7);
      expect(profiles.single.email, "someone@example.org");
      expect(ProfileService.instance.activeScope, isEmpty);
    });

    test('an existing offline vault becomes the legacy profile', () async {
      SharedPreferences.setMockInitialValues({
        Configuration.hasOptedForOfflineModeKey: true,
      });

      await ProfileService.instance.init();

      final profiles = ProfileService.instance.profiles;
      expect(profiles, hasLength(1));
      expect(profiles.single.scope, isEmpty);
      expect(profiles.single.kind, ProfileKind.offline);
    });

    test('an already seeded list is not re-derived', () async {
      SharedPreferences.setMockInitialValues({});
      await ProfileService.instance.init();
      expect(ProfileService.instance.profiles, isEmpty);

      // A token showing up later is a sign in, not a legacy account, so the
      // empty list we already stored must win.
      SharedPreferences.setMockInitialValues({
        "profilesV1": <String>[],
        "profilesActiveScope": "",
        BaseConfiguration.tokenKey: "a-token",
      });
      await ProfileService.instance.init();

      expect(ProfileService.instance.profiles, isEmpty);
    });

    test('an unknown active scope falls back to the first profile', () async {
      SharedPreferences.setMockInitialValues({
        "profilesV1": [
          json.encode(
            const Profile(scope: "acct_1.", kind: ProfileKind.online).toMap(),
          ),
        ],
        "profilesActiveScope": "acct_9.",
      });

      await ProfileService.instance.init();

      expect(ProfileService.instance.activeScope, "acct_1.");
      expect(ProfileService.instance.activeProfile, isNotNull);
    });
  });

  group('Profile', () {
    test('survives a serialization round trip', () {
      const profile = Profile(
        scope: "acct_1.",
        kind: ProfileKind.online,
        userID: 42,
        email: "someone@example.org",
      );

      final restored = Profile.fromMap(profile.toMap());

      expect(restored.scope, profile.scope);
      expect(restored.kind, profile.kind);
      expect(restored.userID, profile.userID);
      expect(restored.email, profile.email);
    });

    test('the legacy profile is flagged as such', () {
      const legacy = Profile(scope: "", kind: ProfileKind.online);
      const added = Profile(scope: "acct_1.", kind: ProfileKind.offline);

      expect(legacy.isLegacy, isTrue);
      expect(added.isLegacy, isFalse);
      expect(added.isOffline, isTrue);
    });
  });
}
