import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ente_auth/events/codes_updated_event.dart';
import 'package:ente_auth/models/code.dart';
import 'package:ente_auth/services/preference_service.dart';
import 'package:ente_auth/store/code_store.dart';
import 'package:ente_auth/utils/autofill_domain_util.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Publishes the active profile's codes to the iOS AutoFill extension.
///
/// The extension is a separate process with no Flutter engine, so it cannot
/// read the Ente vault. Instead this pushes a projection of the codes — enough
/// to compute an OTP and label a row — over a MethodChannel, and the native
/// side encrypts it into the shared App Group container and registers the
/// matching credential identities.
///
/// Only the active profile is published. Every other profile's data key is
/// unavailable while it is not active, and publishing across profiles would
/// mean offering one account's codes while the user is signed in as another.
class AutoFillService {
  AutoFillService._privateConstructor();
  static final AutoFillService instance = AutoFillService._privateConstructor();

  static const _channel = MethodChannel("io.ente.auth/autofill");

  final _logger = Logger("AutoFillService");

  StreamSubscription<CodesUpdatedEvent>? _codesUpdatedSubscription;
  bool? _isSupported;
  /// Signature of the last payload actually pushed. Codes change far less
  /// often than CodesUpdatedEvent fires — every sync tick fires one — so this
  /// keeps the common case down to a database read.
  String? _lastPushed;
  Future<void>? _inFlight;

  Future<void> init() async {
    if (!_isPlatformSupported) return;
    _codesUpdatedSubscription ??= Bus.instance.on<CodesUpdatedEvent>().listen((
      _,
    ) {
      refresh().ignore();
    });
    await refresh();
  }

  bool get _isPlatformSupported => Platform.isIOS;

  /// True only on iOS 18 and up, where third-party providers may serve
  /// one-time codes. The settings entry is hidden entirely below that rather
  /// than offering a switch that does nothing.
  Future<bool> isSupported() async {
    if (!_isPlatformSupported) return false;
    if (_isSupported != null) return _isSupported!;
    try {
      _isSupported = await _channel.invokeMethod<bool>("isSupported") ?? false;
    } catch (e, s) {
      _logger.warning("Could not determine AutoFill support", e, s);
      _isSupported = false;
    }
    return _isSupported!;
  }

  /// Whether the user has enabled Ente under Settings → General → AutoFill &
  /// Passwords. Codes are published regardless, but until this is true iOS
  /// will not offer them.
  Future<bool> isEnabledInSystemSettings() async {
    if (!await isSupported()) return false;
    try {
      return await _channel.invokeMethod<bool>("getState") ?? false;
    } catch (e, s) {
      _logger.warning("Could not read the credential identity store", e, s);
      return false;
    }
  }

  /// Republishes the snapshot. Safe to call often: identical payloads are
  /// dropped, and calls made while one is in flight wait on it.
  Future<void> refresh() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _refresh().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _refresh() async {
    if (!await isSupported()) return;
    if (!PreferenceService.instance.isAutoFillEnabled()) {
      await clear();
      return;
    }

    final List<Code> codes;
    try {
      codes = await CodeStore.instance.getAllCodes();
    } catch (e, s) {
      // A transient read failure must not wipe what the extension already has;
      // the user would silently lose AutoFill until the next code change.
      _logger.warning("Could not read codes for AutoFill", e, s);
      return;
    }

    final entries = codes.where(_isFillable).map(_toEntry).toList();
    final payload = {
      "entries": entries,
      "timeOffsetMs": PreferenceService.instance.timeOffsetInMilliSeconds(),
      // The extension bypasses the Flutter lock screen by construction, so
      // this flag is what stops AutoFill being a way around it. Re-read on
      // every refresh, since the app lock can be set or cleared at any time.
      "requiresAuth": await LockScreenSettings.instance.shouldShowLockScreen(),
    };

    final signature = jsonEncode(payload);
    if (signature == _lastPushed) return;

    try {
      final registered =
          await _channel.invokeMethod<bool>("sync", payload) ?? false;
      // Only remember the payload once iOS actually took the identities.
      // Before the user enables Ente under Settings → AutoFill & Passwords the
      // identity store rejects them, and caching the signature here would mean
      // never retrying for an unchanged set of codes.
      _lastPushed = registered ? signature : null;
      _logger.info(
        registered
            ? "Published ${entries.length} code(s) to AutoFill"
            : "Wrote ${entries.length} code(s); AutoFill is off in iOS Settings",
      );
    } catch (e, s) {
      _lastPushed = null;
      _logger.severe("Failed to publish codes to AutoFill", e, s);
    }
  }

  /// Removes the snapshot and every registered identity. Called on sign out,
  /// profile removal, and when the feature is switched off.
  Future<void> clear() async {
    if (!_isPlatformSupported) return;
    try {
      await _channel.invokeMethod("clear");
    } catch (e, s) {
      _logger.severe("Failed to clear AutoFill data", e, s);
    }
    _lastPushed = null;
  }

  Future<void> setEnabled(bool enabled) async {
    await PreferenceService.instance.setAutoFillEnabled(enabled);
    if (enabled) {
      // A stale signature must not suppress the first push after enabling.
      _lastPushed = null;
      await refresh();
    } else {
      await clear();
    }
  }

  /// HOTP is excluded: its counter would have to be incremented and synced,
  /// which an extension cannot do, so filling one would desync the account.
  bool _isFillable(Code code) =>
      !code.hasError &&
      !code.isTrashed &&
      code.generatedID != null &&
      code.secret.isNotEmpty &&
      code.type.isTOTPCompatible;

  Map<String, dynamic> _toEntry(Code code) {
    // Mirrors getOTP(), which treats a 'steam' issuer as Steam whatever the
    // otpauth type says.
    final isSteam =
        code.type == Type.steam || code.issuer.toLowerCase() == 'steam';
    return {
      "id": code.generatedID.toString(),
      "issuer": code.issuer,
      "account": code.account,
      "secret": code.secret,
      "algorithm": code.algorithm.name,
      "digits": code.digits,
      "period": code.period,
      "kind": isSteam ? "steam" : "totp",
      "serviceIdentifiers": serviceIdentifiersFor(code),
    };
  }
}
