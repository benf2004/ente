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

  group('the profile cap', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    test('allows adding until the maximum is reached', () async {
      SharedPreferences.setMockInitialValues({
        "profilesV1": List.generate(
          ProfileService.maxProfiles - 1,
          (i) => json.encode(
            Profile(scope: "acct_$i.", kind: ProfileKind.online).toMap(),
          ),
        ),
        "profilesActiveScope": "acct_0.",
      });
      await ProfileService.instance.init();

      expect(ProfileService.instance.canAddProfile, isTrue);
    });

    test('refuses to begin an add once full', () async {
      SharedPreferences.setMockInitialValues({
        "profilesV1": List.generate(
          ProfileService.maxProfiles,
          (i) => json.encode(
            Profile(scope: "acct_$i.", kind: ProfileKind.online).toMap(),
          ),
        ),
        "profilesActiveScope": "acct_0.",
      });
      await ProfileService.instance.init();

      expect(ProfileService.instance.canAddProfile, isFalse);
      expect(ProfileService.instance.beginAdd(), throwsStateError);
      // The rejected attempt must not have consumed a scope or a profile slot.
      expect(
        ProfileService.instance.profiles,
        hasLength(ProfileService.maxProfiles),
      );
    });
  });

  group('committing an add', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({
        "profilesV1": <String>[],
        "profilesActiveScope": "",
      });
      await ProfileService.instance.init();
    });

    test('renaming a vault persists and can be cleared', () async {
      await ProfileService.instance.upsert(
        const Profile(scope: "acct_1.", kind: ProfileKind.offline),
      );

      await ProfileService.instance.rename("acct_1.", "  Work laptop  ");
      expect(ProfileService.instance.profiles.single.label, "Work laptop");

      await ProfileService.instance.rename("acct_1.", "   ");
      expect(ProfileService.instance.profiles.single.label, isNull);
    });

    test('is idempotent for the same scope', () async {
      // The online path commits from the sign in listener and the offline path
      // commits from the caller. A second call must not re-run duplicate
      // detection and discard the vault it just registered.
      await ProfileService.instance.upsert(
        const Profile(scope: "acct_1.", kind: ProfileKind.offline),
      );

      final result = await ProfileService.instance.commitAdd("acct_1.");

      expect(result, isNull);
      expect(ProfileService.instance.profiles, hasLength(1));
      expect(ProfileService.instance.profiles.single.scope, "acct_1.");
      expect(ProfileService.instance.activeScope, "acct_1.");
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

    test('falls back through label, email, then the offline name', () {
      const named = Profile(
        scope: "acct_1.",
        kind: ProfileKind.offline,
        label: "Work laptop",
      );
      const online = Profile(
        scope: "acct_2.",
        kind: ProfileKind.online,
        email: "someone@example.org",
      );
      const bare = Profile(scope: "acct_3.", kind: ProfileKind.offline);
      const blank = Profile(
        scope: "acct_4.",
        kind: ProfileKind.offline,
        label: "   ",
      );

      expect(named.displayName("Offline vault"), "Work laptop");
      expect(online.displayName("Offline vault"), "someone@example.org");
      expect(bare.displayName("Offline vault"), "Offline vault");
      expect(blank.displayName("Offline vault"), "Offline vault");
    });

    test('a label survives a serialization round trip', () {
      const profile = Profile(
        scope: "acct_1.",
        kind: ProfileKind.offline,
        label: "Work laptop",
      );

      expect(Profile.fromMap(profile.toMap()).label, "Work laptop");
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
