import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:ente_accounts/services/user_service.dart';
import 'package:ente_auth/core/configuration.dart';
import 'package:ente_auth/models/profile.dart';
import 'package:ente_auth/services/authenticator_service.dart';
import 'package:ente_auth/services/billing_service.dart';
import 'package:ente_auth/services/local_backup_service.dart';
import 'package:ente_auth/store/authenticator_db.dart';
import 'package:ente_auth/store/offline_authenticator_db.dart';
import 'package:ente_auth/store/scoped_database.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/signed_in_event.dart';
import 'package:ente_events/models/user_details_changed_event.dart';
import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:ente_network/network.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The profile list is app wide state, so it is stored under unprefixed keys.
// Everything an account owns lives under its Profile.scope prefix.
class ProfileService {
  static const maxProfiles = 5;

  static const _profilesKey = "profilesV1";
  static const _activeScopeKey = "profilesActiveScope";
  static const _nextIdKey = "profilesNextId";

  final _logger = Logger((ProfileService).toString());

  ProfileService._privateConstructor();

  static final ProfileService instance = ProfileService._privateConstructor();

  late SharedPreferences _prefs;
  List<Profile> _profiles = const [];
  String _activeScope = "";

  String? _pendingAddReturnScope;
  // The scope beginAdd() is still tracking. Only that scope may be committed
  // or handed back; anything else is a late second call for an add that has
  // already been resolved.
  String? _pendingAddScope;
  StreamSubscription<SignedInEvent>? _pendingAddSubscription;
  StreamSubscription<SignedInEvent>? _signedInSubscription;
  StreamSubscription<UserDetailsChangedEvent>? _userDetailsSubscription;
  Future<Profile?>? _commitInFlight;
  bool _rejectedDuplicateAdd = false;

  // The registry is read at build time by the home app bar, the settings
  // header and the switcher, none of which are rebuilt by a change to a
  // profile's own details (an email change, a rename).
  final ValueNotifier<Profile?> activeProfileNotifier = ValueNotifier(null);

  bool consumeRejectedDuplicateAdd() {
    final rejected = _rejectedDuplicateAdd;
    _rejectedDuplicateAdd = false;
    return rejected;
  }

  List<Profile> get profiles => List.unmodifiable(_profiles);

  String get activeScope => _activeScope;

  bool get hasMultipleProfiles => _profiles.length > 1;

  // Whether no account other than [scope] is left for the app lock to guard.
  //
  // Not "is there a single profile": a profile being added is unregistered
  // until commitAdd, so during an add the sole registered profile is another
  // account that is still signed in, and reading that as the last sign out
  // would take the app lock down with the aborted add.
  bool isLastProfile(String scope) =>
      _profiles.every((profile) => profile.scope == scope);

  bool get canAddProfile => _profiles.length < maxProfiles;

  Profile? get activeProfile =>
      _profiles.where((profile) => profile.scope == _activeScope).firstOrNull;

  // Must run before Configuration.init(), which needs the active scope.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs.getStringList(_profilesKey);
    if (stored == null) {
      await _seedFromLegacyState();
    } else {
      _profiles = stored
          .map((e) => Profile.fromMap(json.decode(e) as Map<String, dynamic>))
          .toList();
      _activeScope = _prefs.getString(_activeScopeKey) ?? "";
      if (_profiles.isEmpty && _scopeHasAccountData("")) {
        _logger.warning("Unregistered legacy account found, re-seeding");
        await _seedFromLegacyState();
      }
      await reconcile();
      if (_profiles.isNotEmpty && activeProfile == null) {
        _logger.warning(
          "Active scope '$_activeScope' is unknown, falling back to the first "
          "profile",
        );
        _activeScope = _profiles.first.scope;
        await _persist();
      }
    }
    // Registers the account for a sign in outside the add flow, in particular
    // the first sign in on a fresh install.
    _signedInSubscription ??= Bus.instance.on<SignedInEvent>().listen((event) {
      unawaited(ensureActiveProfileRegistered());
    });
    // The account's own details can change while it is signed in, and the
    // profile keeps a copy of the email to show. Without this it would keep
    // showing the address the account was registered with.
    _userDetailsSubscription ??= Bus.instance
        .on<UserDetailsChangedEvent>()
        .listen((event) {
          unawaited(ensureActiveProfileRegistered());
        });
    _notifyActiveProfile();
    _logger.info(
      "Loaded ${_profiles.length} profile(s), active '$_activeScope'",
    );
  }

  // Whether [scope] still owns an account that can be opened; the legacy
  // profile passes the empty scope. The encrypted token counts: an account
  // waiting on password re-entry has one but no token yet, and reading it as
  // nothing would hide the account row (and with it the switcher) for good.
  //
  // Seeding and reconciliation share this so that they cannot disagree about
  // what counts, which would let one resurrect a profile the other drops.
  bool _scopeHasAccountData(String scope) {
    return _prefs.containsKey("$scope${BaseConfiguration.tokenKey}") ||
        _prefs.containsKey("$scope${BaseConfiguration.encryptedTokenKey}") ||
        (_prefs.getBool("$scope${Configuration.hasOptedForOfflineModeKey}") ??
            false);
  }

  // Drops records for vaults that have no data left to open. Every logout the
  // app knows about goes through completeLogout(), which removes the record
  // itself; this is the backstop for a path that clears an account without
  // knowing about profiles, so that such a record cannot outlive a restart.
  Future<void> reconcile() async {
    bool hasAccountData(Profile profile) => _scopeHasAccountData(profile.scope);

    final dead = _profiles
        .where((profile) => !hasAccountData(profile))
        .toList();
    if (dead.isEmpty) {
      return;
    }
    _logger.warning("Dropping ${dead.length} profile(s) with no data: $dead");
    _profiles = _profiles.where(hasAccountData).toList();
    if (_profiles.isEmpty) {
      _activeScope = "";
    } else if (activeProfile == null) {
      _activeScope = _profiles.first.scope;
    }
    await _persist();
  }

  // No-ops while an add is in flight: registering there would make commitAdd
  // take its early return and skip the duplicate account check.
  Future<void> ensureActiveProfileRegistered() async {
    if (_pendingAddSubscription != null) {
      return;
    }
    final config = Configuration.instance;
    await registerProfileSnapshot(
      scope: config.scope,
      userID: config.getUserID(),
      email: config.getEmail(),
      isOnline: config.isLoggedIn(),
    );
  }

  // isOnline must come from isLoggedIn(), not hasConfiguredAccount(): during
  // sign up the signed in event fires before the keys exist, and the stricter
  // check would misfile the account as an offline vault.
  Future<void> registerProfileSnapshot({
    required String scope,
    int? userID,
    String? email,
    required bool isOnline,
  }) async {
    final existing = _profiles
        .where((profile) => profile.scope == scope)
        .firstOrNull;
    final kind = isOnline ? ProfileKind.online : ProfileKind.offline;
    await upsert(
      existing?.copyWith(kind: kind, userID: userID, email: email) ??
          Profile(scope: scope, kind: kind, userID: userID, email: email),
    );
  }

  // The pre-existing account keeps the empty scope, so none of its
  // preferences, secure storage entries or database files need to move.
  Future<void> _seedFromLegacyState() async {
    _activeScope = "";
    // The encrypted token counts too; see _hasLegacyAccountData.
    final hasToken =
        _prefs.containsKey(BaseConfiguration.tokenKey) ||
        _prefs.containsKey(BaseConfiguration.encryptedTokenKey);
    final hasOfflineVault =
        _prefs.getBool(Configuration.hasOptedForOfflineModeKey) ?? false;
    if (hasToken) {
      _profiles = [
        Profile(
          scope: "",
          kind: ProfileKind.online,
          userID: _prefs.getInt(BaseConfiguration.userIDKey),
          email: _prefs.getString(BaseConfiguration.emailKey),
        ),
      ];
    } else if (hasOfflineVault) {
      _profiles = [const Profile(scope: "", kind: ProfileKind.offline)];
    } else {
      _profiles = const [];
    }
    await _persist();
    _logger.info("Seeded profiles from legacy state: $_profiles");
  }

  Future<void> _persist() async {
    await _prefs.setStringList(
      _profilesKey,
      _profiles.map((profile) => json.encode(profile.toMap())).toList(),
    );
    await _prefs.setString(_activeScopeKey, _activeScope);
    _notifyActiveProfile();
  }

  void _notifyActiveProfile() {
    activeProfileNotifier.value = activeProfile;
  }

  // Ids are never reused, so a removed profile's leftover keys can never be
  // picked up by a later one.
  Future<String> _allocateScope() async {
    final id = (_prefs.getInt(_nextIdKey) ?? 1);
    await _prefs.setInt(_nextIdKey, id + 1);
    return "acct_$id.";
  }

  Profile? profileForUser(int userID) =>
      _profiles.where((profile) => profile.userID == userID).firstOrNull;

  Future<void> rename(String scope, String label) async {
    final index = _profiles.indexWhere((profile) => profile.scope == scope);
    if (index == -1) {
      _logger.warning("Cannot rename unknown scope '$scope'");
      return;
    }
    final trimmed = label.trim();
    final updated = [..._profiles];
    updated[index] = updated[index].copyWith(
      label: trimmed,
      clearLabel: trimmed.isEmpty,
    );
    _profiles = updated;
    await _persist();
  }

  Future<void> upsert(Profile profile) async {
    final index = _profiles.indexWhere((other) => other.scope == profile.scope);
    final updated = [..._profiles];
    if (index == -1) {
      updated.add(profile);
    } else {
      updated[index] = profile;
    }
    _profiles = updated;
    await _persist();
  }

  Future<void> switchTo(String scope) async {
    if (scope == _activeScope) return;
    _logger.info("Switching to '$scope'");
    // Persist only once the services point at the new profile, so a failed
    // switch does not leave the stored scope disagreeing with what is read.
    // _applyScope re-points several singletons in turn, so a failure partway
    // has to be undone as well, or the registry would still name the old
    // profile while its databases were open on the new one.
    final previous = _activeScope;
    try {
      await _applyScope(scope);
    } catch (e, s) {
      _logger.severe("Failed to apply '$scope', restoring '$previous'", e, s);
      try {
        await _applyScope(previous);
      } catch (e2, s2) {
        _logger.severe("Failed to restore '$previous'", e2, s2);
      }
      rethrow;
    }
    _activeScope = scope;
    await _persist();
  }

  // Re-points the account scoped services at [scope]. App wide state (lock
  // screen, theme, locale, general preferences) is deliberately left alone.
  Future<void> _applyScope(String scope) async {
    // Stops a sync from writing the outgoing account's entities into the
    // incoming account's database.
    await AuthenticatorService.instance.suspendSync();
    try {
      await AuthenticatorDB.instance.setScope(scope);
      await OfflineAuthenticatorDB.instance.setScope(scope);
      await Configuration.instance.setScope(scope);
      // Billing plans are per account, and the endpoint may differ.
      BillingService.instance.clearCache();
      await Network.instance.init(Configuration.instance);
      await AuthenticatorService.instance.init();
      await LocalBackupService.instance.init(
        hasOptedForOfflineMode: Configuration.instance.hasOptedForOfflineMode(),
      );
      // Process wide, and otherwise only written by the sign in flow, so
      // without this it keeps showing the previous profile's email.
      UserService.instance.emailValueNotifier.value = Configuration.instance
          .getEmail();
    } finally {
      AuthenticatorService.instance.resumeSync();
    }
  }

  // Returns the scope the sign in flow should run against. The caller must
  // follow up with commitAdd() or abortAdd(); until then the new scope is
  // active but unregistered, so an interrupted sign in leaves nothing behind.
  Future<String> beginAdd() async {
    if (!canAddProfile) {
      throw StateError("At most $maxProfiles profiles are supported");
    }
    _rejectedDuplicateAdd = false;
    final scope = await _allocateScope();
    _logger.info("Beginning add of a profile at '$scope'");
    _pendingAddReturnScope = _activeScope;
    _pendingAddScope = scope;
    // Undone on failure for the same reason as in switchTo(): a half applied
    // scope leaves the registry naming one profile while the databases are
    // open on another, and nothing here has been registered to abort against.
    try {
      await _applyScope(scope);
    } catch (e, s) {
      _logger.severe(
        "Failed to apply '$scope', restoring '$_activeScope'",
        e,
        s,
      );
      _pendingAddReturnScope = null;
      _pendingAddScope = null;
      try {
        await _applyScope(_activeScope);
      } catch (e2, s2) {
        _logger.severe("Failed to restore '$_activeScope'", e2, s2);
      }
      rethrow;
    }
    // The sign in flow navigates on its own across several pages, so watch for
    // it completing rather than awaiting it.
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = Bus.instance.on<SignedInEvent>().listen((event) {
      unawaited(_pendingAddSubscription?.cancel());
      _pendingAddSubscription = null;
      unawaited(commitAdd(scope));
    });
    return scope;
  }

  // Returns the profile already signed in as this user, if any, in which case
  // nothing is added and the caller should switch to it instead.
  //
  // The sign in listener in beginAdd() and the add page both commit, and the
  // page's "is it registered yet" check can run while the listener's commit is
  // still mid flight. Sharing the one future keeps the two from each running
  // the duplicate check against a registry that does not hold the scope yet,
  // which would abort the account just added.
  Future<Profile?> commitAdd(String scope) {
    // Only an add still being tracked, or one already registered, may commit.
    // A late call for a scope that was handed back is neither, and letting it
    // through would re-run the duplicate check below: the configuration points
    // at the restored profile by then, so the check would match that profile
    // against itself and end its live session.
    final isRegistered = _profiles.any((profile) => profile.scope == scope);
    if (_pendingAddScope != scope && !isRegistered) {
      _logger.info("Ignoring commit of '$scope', which is no longer pending");
      return Future.value(null);
    }
    return _commitInFlight ??= _commitAdd(
      scope,
    ).whenComplete(() => _commitInFlight = null);
  }

  Future<Profile?> _commitAdd(String scope) async {
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = null;
    // Idempotent: the online path commits from the sign in listener and the
    // offline path from the caller, and both can be live at once. A second
    // call must not re-run the duplicate check against the profile just added.
    if (_profiles.any((profile) => profile.scope == scope)) {
      _pendingAddReturnScope = null;
      _pendingAddScope = null;
      if (_activeScope != scope) {
        _activeScope = scope;
        await _persist();
      }
      return null;
    }
    final config = Configuration.instance;
    final userID = config.getUserID();
    final existing = userID == null ? null : profileForUser(userID);
    if (existing != null) {
      _logger.info("$existing is already signed in, discarding '$scope'");
      _rejectedDuplicateAdd = true;
      // The sign in that got us here was a real one, so the server issued a
      // session for it. Throwing the token away locally would leave that
      // session live and listed under the account's active sessions.
      await _endSessionForRejectedAdd();
      await abortAdd(scope);
      return existing;
    }
    await upsert(
      Profile(
        scope: scope,
        kind: config.isLoggedIn() ? ProfileKind.online : ProfileKind.offline,
        userID: userID,
        email: config.getEmail(),
      ),
    );
    _pendingAddReturnScope = null;
    _pendingAddScope = null;
    _activeScope = scope;
    await _persist();
    return null;
  }

  // Best effort: the account is unreachable from the app either way, so a
  // failure here must not stop the scope from being handed back.
  Future<void> _endSessionForRejectedAdd() async {
    try {
      await Network.instance.enteDio.post("/users/logout");
    } catch (e, s) {
      _logger.warning("Failed to end the rejected add's session", e, s);
    }
  }

  Future<void> abortAdd(String scope) async {
    // Only the add still being tracked may be handed back. Aborting one that
    // was already resolved would fall through to the empty scope below and
    // drop the user onto a legacy profile that need not even exist.
    if (_pendingAddScope != scope) {
      _logger.info("Ignoring abort of '$scope', which is no longer pending");
      return;
    }
    _logger.info("Aborting add of '$scope'");
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = null;
    // The active scope is only advanced once an add commits, so while one is
    // pending it still names the profile to go back to.
    final returnScope = _pendingAddReturnScope ?? _activeScope;
    _pendingAddReturnScope = null;
    _pendingAddScope = null;
    // Re-point everything at the surviving profile first, as switchTo() does:
    // persisting ahead of it would leave the stored scope naming a profile the
    // services are not on, and erasing ahead of it would delete the data the
    // app is still live on. A failure here leaves the aborted scope active but
    // unregistered, which init() falls back from and the orphan sweep clears.
    await _applyScope(returnScope);
    _profiles = _profiles.where((profile) => profile.scope != scope).toList();
    _activeScope = returnScope;
    await _persist();
    // Only now: the databases are singletons, so deleting first leaves a
    // window where a sync or a page load reopens the file that was just
    // removed.
    await discard(scope);
  }

  // Returns false when that was the last profile, so the caller knows to send
  // the user back to onboarding.
  Future<bool> removeActive() async {
    final scope = _activeScope;
    // From the profile record, not the configuration: a logout has usually
    // cleared the token by now, so hasConfiguredAccount() would report every
    // profile as an offline one.
    if (activeProfile?.isOffline ?? false) {
      await Configuration.instance.clearOfflineAccount();
      // Removing a vault fires no SignedOutEvent, so the listener that
      // normally clears this never runs. discard() would cover a prefixed
      // scope, but the legacy scope's keys carry no prefix to match on, so it
      // would otherwise be inherited by the next account at that scope.
      await Configuration.instance.clearBackupPassword();
      if (scope.isEmpty) {
        // discard() cannot delete the legacy scope's database files, since a
        // future account at the same scope would reuse those names, so empty
        // the codes out instead of leaving them for it to find.
        await OfflineAuthenticatorDB.instance.clearTable();
      }
    }
    final remaining = _profiles
        .where((profile) => profile.scope != scope)
        .toList();
    final nextScope = remaining.isEmpty ? "" : remaining.first.scope;
    // Re-point before touching the registry or erasing; see the note in
    // abortAdd. A failure here leaves the profile registered and its data
    // intact, which is recoverable, rather than erasing the scope the app is
    // still running on.
    await _applyScope(nextScope);
    _profiles = remaining;
    _activeScope = nextScope;
    await _persist();
    if (_profiles.isEmpty) {
      // The lock guards the app, so it only goes once nothing is left to
      // guard. Idempotent for an online logout, where the SignedOutEvent
      // listener has already done this; the offline path has no such event.
      await LockScreenSettings.instance.clearAppLockOnSignOut();
    }
    await discard(scope);
    return _profiles.isNotEmpty;
  }

  // A sign out that cleared the account without going through
  // completeLogout(), namely the sign in flow's own "change email" paths.
  // Drops the record for the scope that was cleared, so the registry cannot
  // outlive the account's data.
  //
  // Deliberately not removeActive(): the caller is a sign in flow that means
  // to carry on and sign in again, and switching to a surviving profile would
  // drop the user into someone else's vault instead of the email screen they
  // asked for. The scope stays active but unregistered, exactly as during an
  // add, so signing back in lands here and re-registers it; backing out
  // instead leaves an unknown active scope, which init() falls back from.
  //
  // Configuration.logout() has already erased this scope's preferences, keys
  // and entities, so there is nothing further to discard.
  Future<void> handleExternalLogout() async {
    final scope = Configuration.instance.scope;
    // An unregistered scope is a profile mid add: the add flow hands it back
    // through abortAdd, and dropping a record here would target the wrong
    // profile since _activeScope still names the one the user was on.
    if (scope != _activeScope ||
        !_profiles.any((profile) => profile.scope == scope)) {
      return;
    }
    _logger.info("Dropping '$scope' after a sign out taken outside the app");
    _profiles = _profiles.where((profile) => profile.scope != scope).toList();
    await _persist();
  }

  // Scopes that own data on disk but no profile record. reconcile() covers the
  // opposite case only, so without this an add that never reached commitAdd —
  // the app killed between the sign in and the registry write — leaves that
  // account's token, keychain entries and encrypted codes on the device with
  // nothing able to reach or remove them.
  //
  // Runs after Configuration.init(), which owns the secure storage discard()
  // needs, and before any add can be pending, so every unregistered acct_
  // scope found here is genuinely abandoned.
  Future<void> sweepOrphanedScopes() async {
    final registered = _profiles.map((profile) => profile.scope).toSet();
    final orphans = _prefs
        .getKeys()
        .map((key) => _allocatedScopePattern.matchAsPrefix(key)?.group(0))
        .whereType<String>()
        .toSet()
        .where((scope) => scope != _activeScope && !registered.contains(scope))
        .toList();
    if (orphans.isEmpty) {
      return;
    }
    _logger.warning("Discarding ${orphans.length} orphaned scope(s): $orphans");
    for (final scope in orphans) {
      await discard(scope);
    }
  }

  // Mirrors the shape _allocateScope() hands out.
  static final _allocatedScopePattern = RegExp(r'acct_\d+\.');

  // Erases the preferences, keychain entries and database files [scope] owns.
  // Callers must already have made a different profile active.
  Future<void> discard(String scope) async {
    if (_profiles.any((profile) => profile.scope == scope)) {
      _profiles = _profiles.where((profile) => profile.scope != scope).toList();
      await _persist();
    }
    if (scope.isEmpty) {
      // Its keys carry no prefix, so they cannot be matched on. Clear them by
      // exclusion instead, exactly as Configuration.logout() does: an online
      // profile has been through that already and this is a no-op, but the
      // offline removal path never calls logout(), and leaving 'endpoint',
      // 'lastBackupDay' and the sync cursor behind would hand them to whatever
      // account lands on the legacy scope next.
      _logger.info("Clearing the legacy scope's account owned keys");
      final legacyKeys = BaseConfiguration.keysToClearOnLogout(
        _prefs.getKeys(),
        Configuration.instance.logoutPreservedKeyPrefixes,
      );
      for (final key in legacyKeys) {
        await _prefs.remove(key);
      }
      // Its entities are not touched here: by the time discard() runs the
      // databases have been re-pointed at the surviving profile, so clearing
      // through the singletons would empty that profile's codes instead. The
      // legacy tables are emptied before the switch, by Configuration.logout()
      // for an online profile and by removeActive() for an offline one.
      return;
    }
    for (final key in _prefs.getKeys().where((key) => key.startsWith(scope))) {
      await _prefs.remove(key);
    }
    await Configuration.instance.clearSecureStorageForScope(scope);
    await _deleteDatabases(scope);
  }

  Future<void> _deleteDatabases(String scope) async {
    // A switch leaves the outgoing handle open on purpose (see ScopedDatabase),
    // so release this scope's before unlinking its files, or the delete fails
    // on Windows and elsewhere leaves the handle writing to an unlinked file.
    await AuthenticatorDB.instance.closeScope(scope);
    await OfflineAuthenticatorDB.instance.closeScope(scope);
    final names = [
      AuthenticatorDB.databaseNameForScope(scope),
      OfflineAuthenticatorDB.databaseNameForScope(scope),
    ];
    for (final name in names) {
      try {
        final String path = await databasePathForName(name);
        for (final suffix in const ["", "-wal", "-shm"]) {
          final file = File("$path$suffix");
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (e, s) {
        _logger.severe("Failed to delete database $name", e, s);
      }
    }
  }
}
