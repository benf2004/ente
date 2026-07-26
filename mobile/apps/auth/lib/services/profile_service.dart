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
import 'package:ente_auth/utils/directory_utils.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/signed_in_event.dart';
import 'package:ente_network/network.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks the vaults the user has signed in to, and which one is active.
///
/// The profile list itself is app wide state, so it is stored under unprefixed
/// preference keys. Everything else an account owns lives under that profile's
/// [Profile.scope]; see [Configuration.scopedKey].
class ProfileService {
  /// The most vaults a user can keep signed in at once, counting offline ones.
  /// Each costs a database, a keychain entry and a row in the switcher.
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

  /// The profile to fall back to if an in progress add is abandoned.
  String? _pendingAddReturnScope;
  StreamSubscription<SignedInEvent>? _pendingAddSubscription;
  StreamSubscription<SignedInEvent>? _signedInSubscription;
  bool _rejectedDuplicateAdd = false;

  /// Whether the last add was rejected because that account was already
  /// signed in. Reading this clears it.
  bool consumeRejectedDuplicateAdd() {
    final rejected = _rejectedDuplicateAdd;
    _rejectedDuplicateAdd = false;
    return rejected;
  }

  List<Profile> get profiles => List.unmodifiable(_profiles);

  String get activeScope => _activeScope;

  bool get hasMultipleProfiles => _profiles.length > 1;

  bool get canAddProfile => _profiles.length < maxProfiles;

  Profile? get activeProfile =>
      _profiles.where((profile) => profile.scope == _activeScope).firstOrNull;

  /// Loads the profile list, seeding it from pre multi-account state on the
  /// first run after upgrade.
  ///
  /// Must run before [Configuration.init], which needs the active scope.
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
      if (_profiles.isEmpty && _hasLegacyAccountData()) {
        // An account exists but was never registered — a sign in that predates
        // profile registration, or a registry lost to an older bug. Heal it,
        // or the account becomes unreachable the moment another one is added.
        _logger.warning("Unregistered legacy account found, re-seeding");
        await _seedFromLegacyState();
      }
      await _reconcile();
      if (_profiles.isNotEmpty && activeProfile == null) {
        _logger.warning(
          "Active scope '$_activeScope' is unknown, falling back to the first "
          "profile",
        );
        _activeScope = _profiles.first.scope;
        await _persist();
      }
    }
    // Registers the account for a sign in that happens outside the add flow —
    // most importantly the very first sign in on a fresh install, which
    // otherwise would never appear in the switcher.
    _signedInSubscription ??= Bus.instance.on<SignedInEvent>().listen((event) {
      unawaited(ensureActiveProfileRegistered());
    });
    _logger.info(
      "Loaded ${_profiles.length} profile(s), active '$_activeScope'",
    );
  }

  bool _hasLegacyAccountData() {
    return _prefs.containsKey(BaseConfiguration.tokenKey) ||
        (_prefs.getBool(Configuration.hasOptedForOfflineModeKey) ?? false);
  }

  /// Drops profiles whose account data no longer exists.
  ///
  /// Some logout paths cannot know about profiles — the lock screen's
  /// too-many-attempts logout and the revoked-session logout both live in
  /// shared packages — so they clear the account's data but leave its record
  /// behind. Without this, those records show up as vaults that can never be
  /// opened.
  Future<void> _reconcile() async {
    bool hasAccountData(Profile profile) {
      final scope = profile.scope;
      return _prefs.containsKey("$scope${BaseConfiguration.tokenKey}") ||
          _prefs.containsKey("$scope${BaseConfiguration.encryptedTokenKey}") ||
          (_prefs.getBool("$scope${Configuration.hasOptedForOfflineModeKey}") ??
              false);
    }

    final dead = _profiles.where((p) => !hasAccountData(p)).toList();
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

  /// Ensures the account the configuration currently points at has a profile
  /// record, creating or refreshing one.
  ///
  /// No-ops while an add is in flight: the add flow owns registration there,
  /// and a plain upsert running first would make [commitAdd] take its
  /// idempotent early return, bypassing the duplicate account check.
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

  /// Registers or refreshes the profile for [scope], preserving any label the
  /// user has given it.
  ///
  /// [isOnline] must be derived from the token alone (isLoggedIn), not from
  /// hasConfiguredAccount: during sign up the signed in event fires before the
  /// keys exist, and the stricter check would misfile the account as an
  /// offline vault.
  Future<void> registerProfileSnapshot({
    required String scope,
    int? userID,
    String? email,
    required bool isOnline,
  }) async {
    final existing = _profiles
        .where((profile) => profile.scope == scope)
        .firstOrNull;
    await upsert(
      Profile(
        scope: scope,
        kind: isOnline ? ProfileKind.online : ProfileKind.offline,
        userID: userID ?? existing?.userID,
        email: email ?? existing?.email,
        label: existing?.label,
      ),
    );
  }

  /// Derives the initial profile list from the single account that existed
  /// before profiles were introduced.
  ///
  /// The legacy account keeps the empty scope, so none of its preferences,
  /// secure storage entries or database files need to move.
  Future<void> _seedFromLegacyState() async {
    _activeScope = "";
    final hasToken = _prefs.containsKey(BaseConfiguration.tokenKey);
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
  }

  /// Allocates a scope for a new profile. Ids are never reused, so a removed
  /// profile's leftover keys can never be picked up by a later one.
  Future<String> _allocateScope() async {
    final id = (_prefs.getInt(_nextIdKey) ?? 1);
    await _prefs.setInt(_nextIdKey, id + 1);
    return "acct_$id.";
  }

  Profile? profileForUser(int userID) =>
      _profiles.where((profile) => profile.userID == userID).firstOrNull;

  /// Renames a vault. An empty name clears it, falling back to the email or to
  /// the generic offline label.
  Future<void> rename(String scope, String label) async {
    final index = _profiles.indexWhere((profile) => profile.scope == scope);
    if (index == -1) {
      _logger.warning("Cannot rename unknown scope '$scope'");
      return;
    }
    final trimmed = label.trim();
    final updated = [..._profiles];
    final existing = updated[index];
    updated[index] = Profile(
      scope: existing.scope,
      kind: existing.kind,
      userID: existing.userID,
      email: existing.email,
      label: trimmed.isEmpty ? null : trimmed,
    );
    _profiles = updated;
    await _persist();
  }

  /// Registers a profile, or updates it if [scope] is already known.
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

  /// Makes [scope] the active profile and re-points every account scoped
  /// service at it.
  Future<void> switchTo(String scope) async {
    if (scope == _activeScope) return;
    _logger.info("Switching to '$scope'");
    // Persist only once the services are actually pointing at the new profile,
    // so a failed switch does not leave the stored active scope disagreeing
    // with what the app is reading.
    await _applyScope(scope);
    _activeScope = scope;
    await _persist();
  }

  /// Re-points the account scoped services at [scope].
  ///
  /// App wide services — the lock screen, theme, locale and general
  /// preferences — are deliberately left alone: they guard the app rather than
  /// any one vault.
  Future<void> _applyScope(String scope) async {
    // Suspend syncing while the services change hands: the sync already in
    // flight is awaited, and no new one can start and write the outgoing
    // account's entities into the incoming account's database. Any sync
    // requested meanwhile runs when syncing resumes — pointed at the new
    // profile, which is the one it would be syncing anyway.
    await AuthenticatorService.instance.suspendSync();
    try {
      await AuthenticatorDB.instance.setScope(scope);
      await OfflineAuthenticatorDB.instance.setScope(scope);
      await Configuration.instance.setScope(scope);
      // Billing plans are per account, and the endpoint may differ between
      // profiles, so both caches have to be rebuilt.
      BillingService.instance.clearCache();
      await Network.instance.init(Configuration.instance);
      await AuthenticatorService.instance.init();
      await LocalBackupService.instance.init(
        hasOptedForOfflineMode: Configuration.instance.hasOptedForOfflineMode(),
      );
      // This notifier is process wide and is otherwise only written when the
      // sign in flow records a typed address, so without this it keeps showing
      // the previous profile's email — or one that was typed and abandoned.
      UserService.instance.emailValueNotifier.value = Configuration.instance
          .getEmail();
    } finally {
      AuthenticatorService.instance.resumeSync();
    }
  }

  /// Starts adding a profile, returning the scope the sign in flow should run
  /// against.
  ///
  /// The caller must follow up with either [commitAdd] or [abortAdd]; until
  /// then the new scope is active but unregistered, so an interrupted sign in
  /// leaves nothing behind in the profile list.
  Future<String> beginAdd() async {
    if (!canAddProfile) {
      throw StateError("At most $maxProfiles profiles are supported");
    }
    // A rejection left over from an earlier add must not be reported against
    // this one.
    _rejectedDuplicateAdd = false;
    final scope = await _allocateScope();
    _logger.info("Beginning add of a profile at '$scope'");
    _pendingAddReturnScope = _activeScope;
    await _applyScope(scope);
    // The sign in flow navigates on its own and spans several pages, so we
    // watch for it completing rather than trying to await it. By the time this
    // fires the user id and email are always on the configuration: UserService
    // saves those before it sets the token.
    //
    // Registered whatever kind the caller has in mind, because the user picks
    // between signing in and an offline vault inside the flow itself. Whichever
    // path they take, commitAdd works out the kind.
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = Bus.instance.on<SignedInEvent>().listen((event) {
      unawaited(_pendingAddSubscription?.cancel());
      _pendingAddSubscription = null;
      unawaited(commitAdd(scope));
    });
    return scope;
  }

  /// Records the signed in account against [scope] and makes it active.
  ///
  /// Returns the profile already signed in as this user, if any, in which case
  /// nothing is added — the caller should switch to it instead.
  Future<Profile?> commitAdd(String scope) async {
    // The add's sign in listener has served its purpose whichever branch runs
    // below; a live one left behind would mis-drive the next sign in.
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = null;
    // Idempotent: the online path commits from the sign in listener while the
    // offline path commits from the caller, and both can be live at once. A
    // second call must not re-run the duplicate check, which would match the
    // profile just added and erase a perfectly good vault.
    if (_profiles.any((profile) => profile.scope == scope)) {
      _pendingAddReturnScope = null;
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
      await abortAdd(scope);
      return existing;
    }
    await upsert(
      Profile(
        scope: scope,
        // From the token alone: during sign up this runs before the keys
        // exist, and hasConfiguredAccount() would misfile the account as an
        // offline vault.
        kind: config.isLoggedIn() ? ProfileKind.online : ProfileKind.offline,
        userID: userID,
        email: config.getEmail(),
      ),
    );
    _pendingAddReturnScope = null;
    _activeScope = scope;
    await _persist();
    return null;
  }

  /// Abandons an in progress add, erasing whatever the sign in flow wrote and
  /// returning to the profile that was active before it started.
  Future<void> abortAdd(String scope) async {
    _logger.info("Aborting add of '$scope'");
    await _pendingAddSubscription?.cancel();
    _pendingAddSubscription = null;
    final returnScope = _pendingAddReturnScope ?? "";
    _pendingAddReturnScope = null;
    _profiles = _profiles.where((profile) => profile.scope != scope).toList();
    _activeScope = returnScope;
    await _persist();
    // Re-point everything at the surviving profile before erasing the
    // abandoned one. The databases are singletons holding the active scope, so
    // deleting first leaves a window where a sync or a page load reopens the
    // file that was just removed.
    await _applyScope(returnScope);
    await discard(scope);
  }

  /// Removes the active profile and switches to whichever remains.
  ///
  /// Returns false when that was the last profile, so the caller knows to send
  /// the user back to onboarding.
  Future<bool> removeActive() async {
    final scope = _activeScope;
    // Decided from the profile record rather than from the configuration: by
    // the time we get here a logout has usually already cleared the token, so
    // hasConfiguredAccount() would report every profile as an offline one.
    if (activeProfile?.isOffline ?? false) {
      await Configuration.instance.clearOfflineAccount();
    }
    _profiles = _profiles.where((profile) => profile.scope != scope).toList();
    _activeScope = _profiles.isEmpty ? "" : _profiles.first.scope;
    await _persist();
    // Re-point the services before erasing, so nothing can reopen the database
    // files we are about to delete. See the note in abortAdd.
    await _applyScope(_activeScope);
    await discard(scope);
    return _profiles.isNotEmpty;
  }

  /// Erases everything [scope] owns: its preferences and its database files.
  ///
  /// Callers must already have made a different profile active, so that no
  /// service is still holding the databases this deletes.
  Future<void> discard(String scope) async {
    if (_profiles.any((profile) => profile.scope == scope)) {
      _profiles = _profiles.where((profile) => profile.scope != scope).toList();
      await _persist();
    }
    if (scope.isEmpty) {
      // The legacy profile's keys carry no prefix, so there is nothing we can
      // safely match on. Configuration.logout() already clears them wholesale,
      // and clears its databases via EnteBaseDatabase.clearTable().
      _logger.info("Skipping key cleanup for the legacy scope");
      return;
    }
    for (final key in _prefs.getKeys().where((key) => key.startsWith(scope))) {
      await _prefs.remove(key);
    }
    // Scopes are never reused, but the keychain entries of a half signed-in,
    // abandoned add would otherwise linger forever.
    await Configuration.instance.clearSecureStorageForScope(scope);
    await _deleteDatabases(scope);
  }

  Future<void> _deleteDatabases(String scope) async {
    final names = [
      AuthenticatorDB.databaseNameForScope(scope),
      OfflineAuthenticatorDB.databaseNameForScope(scope),
    ];
    for (final name in names) {
      try {
        final String path;
        if (Platform.isWindows || Platform.isLinux) {
          path = await DirectoryUtils.getDatabasePath(name);
        } else {
          final directory = Platform.isMacOS
              ? await getApplicationSupportDirectory()
              : await getApplicationDocumentsDirectory();
          path = p.join(directory.path, name);
        }
        // sqlite keeps its write ahead log alongside the database file.
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
