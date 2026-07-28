import 'package:ente_auth/models/code.dart';
import 'package:ente_auth/models/code_display.dart';
import 'package:ente_auth/services/autofill_service.dart';
import 'package:ente_auth/services/preference_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `AutoFillService.instance` talks to `CodeStore` (sqlite + a live account),
/// `LockScreenSettings` (secure storage + platform channels) and
/// `Platform.isIOS` (unfakeable from Dart), none of which a plain unit test
/// can stand up. `AutoFillService.forTesting` swaps all three for fakes, so
/// these tests exercise the class's own logic — filtering, dedup, the
/// enabled/disabled state machine — the same way `instance` does everywhere
/// else, just without a real device.
void main() {
  const channel = MethodChannel("io.ente.auth/autofill");

  late List<MethodCall> calls;
  late Map<String, dynamic> channelState;
  // Mutable so individual tests can steer the fakes after construction.
  late List<Code> codes;
  late bool requiresAuth;

  AutoFillService service({bool platformSupported = true}) {
    return AutoFillService.forTesting(
      isPlatformSupported: () => platformSupported,
      codesProvider: () async => codes,
      requiresAuthProvider: () async => requiresAuth,
    );
  }

  Code totpCode({
    String issuer = "GitHub",
    String account = "me@example.org",
    String secret = "JBSWY3DPEHPK3PXP",
    Type type = Type.totp,
    bool hasError = false,
    bool trashed = false,
    int? generatedID = 1,
    List<String> websites = const [],
  }) {
    final code = Code.fromAccountAndSecret(
      type,
      account,
      issuer,
      secret,
      CodeDisplay(trashed: trashed, websites: websites),
      Code.defaultDigits,
    );
    code.generatedID = generatedID;
    return hasError ? Code.withError(StateError("bad code"), code.rawData) : code;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // PreferenceService caches a live SharedPreferences instance in a `late
    // final` field, so this can only run once per process; setUp() resets
    // the one key these tests touch directly instead of re-initializing.
    await PreferenceService.instance.init();
  });

  setUp(() async {
    await PreferenceService.instance.setAutoFillEnabled(false);

    codes = const [];
    requiresAuth = false;
    calls = [];
    channelState = {"isSupported": true, "getState": true, "sync": true};

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case "isSupported":
          return channelState["isSupported"];
        case "getState":
          return channelState["getState"];
        case "sync":
          return channelState["sync"];
        case "clear":
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group("platform gating", () {
    test("never touches the channel below iOS", () async {
      final s = service(platformSupported: false);

      expect(await s.isSupported(), isFalse);
      expect(await s.isEnabledInSystemSettings(), isFalse);
      await s.refresh();
      await s.clear();

      expect(calls, isEmpty);
    });

    test("isSupported reflects and caches the channel's answer", () async {
      final s = service();

      expect(await s.isSupported(), isTrue);
      expect(await s.isSupported(), isTrue);

      expect(calls.where((c) => c.method == "isSupported"), hasLength(1));
    });
  });

  group("isEnabledInSystemSettings", () {
    test("mirrors getState once the platform check passes", () async {
      channelState["getState"] = false;
      final s = service();

      expect(await s.isEnabledInSystemSettings(), isFalse);

      channelState["getState"] = true;
      expect(await s.isEnabledInSystemSettings(), isTrue);
    });
  });

  group("refresh", () {
    test("clears rather than syncs while AutoFill is off in-app", () async {
      final s = service();
      codes = [totpCode()];

      await s.refresh();

      expect(calls.map((c) => c.method), ["isSupported", "clear"]);
    });

    test(
      "publishes only fillable codes once AutoFill is enabled",
      () async {
        await PreferenceService.instance.setAutoFillEnabled(true);
        codes = [
          totpCode(generatedID: 1, issuer: "GitHub"),
          // HOTP: excluded, its counter can't be synced by an extension.
          totpCode(generatedID: 2, type: Type.hotp),
          // Errored: excluded, nothing valid to fill.
          totpCode(generatedID: 3, hasError: true),
          // Trashed: excluded.
          totpCode(generatedID: 4, trashed: true),
        ];
        final s = service();

        await s.refresh();

        final sync = calls.singleWhere((c) => c.method == "sync");
        final entries = (sync.arguments as Map)["entries"] as List;
        expect(entries, hasLength(1));
        expect(entries.single["id"], "1");
        expect(entries.single["kind"], "totp");
      },
    );

    test("detects Steam by issuer as well as by type", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [
        totpCode(generatedID: 1, issuer: "Steam"),
        totpCode(generatedID: 2, issuer: "Anything", type: Type.steam),
      ];
      final s = service();

      await s.refresh();

      final sync = calls.singleWhere((c) => c.method == "sync");
      final entries = (sync.arguments as Map)["entries"] as List;
      expect(entries.map((e) => e["kind"]), ["steam", "steam"]);
    });

    test("carries the requiresAuth flag through to the payload", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [totpCode()];
      requiresAuth = true;
      final s = service();

      await s.refresh();

      final sync = calls.singleWhere((c) => c.method == "sync");
      expect((sync.arguments as Map)["requiresAuth"], isTrue);
    });

    test("drops an unchanged payload instead of re-syncing", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [totpCode()];
      final s = service();

      await s.refresh();
      await s.refresh();

      expect(calls.where((c) => c.method == "sync"), hasLength(1));
    });

    test("retries a payload iOS did not actually register", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [totpCode()];
      channelState["sync"] = false;
      final s = service();

      await s.refresh();
      await s.refresh();

      // Not cached as pushed until the identity store actually takes it, so
      // an unchanged set of codes must keep retrying rather than going quiet.
      expect(calls.where((c) => c.method == "sync"), hasLength(2));
    });

    test("re-syncs once codes change after a successful push", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [totpCode(generatedID: 1)];
      final s = service();
      await s.refresh();

      codes = [totpCode(generatedID: 1), totpCode(generatedID: 2)];
      await s.refresh();

      expect(calls.where((c) => c.method == "sync"), hasLength(2));
    });

    test("leaves the last snapshot alone when reading codes fails", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      final s = AutoFillService.forTesting(
        isPlatformSupported: () => true,
        codesProvider: () async => throw StateError("db unavailable"),
        requiresAuthProvider: () async => false,
      );

      await s.refresh();

      expect(calls.map((c) => c.method), ["isSupported"]);
    });
  });

  group("setEnabled", () {
    test("turning it on publishes immediately", () async {
      codes = [totpCode()];
      final s = service();

      await s.setEnabled(true);

      expect(PreferenceService.instance.isAutoFillEnabled(), isTrue);
      expect(calls.map((c) => c.method), contains("sync"));
    });

    test("turning it off clears the extension's data", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      final s = service();

      await s.setEnabled(false);

      expect(PreferenceService.instance.isAutoFillEnabled(), isFalse);
      expect(calls.map((c) => c.method), contains("clear"));
    });

    test(
      "re-enabling with the same codes re-syncs rather than staying silent",
      () async {
        codes = [totpCode()];
        final s = service();
        await s.setEnabled(true);
        await s.setEnabled(false);

        await s.setEnabled(true);

        expect(calls.where((c) => c.method == "sync"), hasLength(2));
      },
    );
  });

  group("clear", () {
    test("calls through and forgets the last pushed signature", () async {
      await PreferenceService.instance.setAutoFillEnabled(true);
      codes = [totpCode()];
      final s = service();
      await s.refresh();

      await s.clear();
      // A clear() must not be mistaken for "already published" on the next
      // refresh of the same codes.
      await s.refresh();

      expect(
        calls.map((c) => c.method).toList(),
        ["isSupported", "sync", "clear", "sync"],
      );
    });
  });
}
