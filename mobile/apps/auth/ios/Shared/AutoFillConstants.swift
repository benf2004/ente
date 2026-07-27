import Foundation
import os

/// Shared log. The extension has no console of its own and cancelling a fill
/// looks identical to nothing happening, so every bail-out path says why here.
/// Never log secrets, codes, issuers or account names.
///
/// os_log rather than Logger: this file is also compiled into Runner, whose
/// deployment target is iOS 13.
enum AutoFillLog {
  private static let handle = OSLog(subsystem: "io.ente.auth", category: "autofill")

  static func info(_ message: String) {
    os_log("%{public}@", log: handle, type: .info, message)
  }

  static func error(_ message: String) {
    os_log("%{public}@", log: handle, type: .error, message)
  }
}

/// Identifiers shared by the host app and the AutoFill credential provider
/// extension. Both processes have to agree on every one of these, so they live
/// in a single file that is a member of both targets rather than being repeated
/// as string literals on either side.
enum AutoFillConstants {
  /// App Group container holding the encrypted snapshot. Must match the
  /// `com.apple.security.application-groups` entitlement on both targets.
  static let appGroupIdentifier = "group.io.ente.auth"

  /// Keychain item holding the snapshot key.
  ///
  /// Deliberately queried *without* `kSecAttrAccessGroup`. Naming a group
  /// explicitly would mean hardcoding the team prefix that
  /// `$(AppIdentifierPrefix)` expands to, which differs per signing team. When
  /// the attribute is omitted, keychain services uses the first entry of the
  /// target's `keychain-access-groups` entitlement — so both Runner and the
  /// extension list `$(AppIdentifierPrefix)io.ente.auth` as their only entry
  /// and land in the same group. Adding entries ahead of it in either
  /// entitlement file would silently split the two processes apart.
  ///
  /// That first entry also matches the group Runner already defaulted to
  /// before the entitlement existed, so items written by flutter_secure_storage
  /// stay where they are.
  static let keychainService = "io.ente.auth.autofill"
  static let keychainAccount = "vaultKey"

  /// Directory and file, relative to the App Group container.
  static let vaultDirectoryName = "autofill"
  static let vaultFileName = "vault.bin"

  /// Flutter MethodChannel used by the host app to publish snapshots.
  static let methodChannelName = "io.ente.auth/autofill"
}
