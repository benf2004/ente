import CryptoKit
import Foundation

/// One code, as the AutoFill extension sees it.
///
/// Deliberately a projection of `Code` rather than the whole thing: the
/// extension needs enough to compute an OTP and label a row, and nothing else.
/// HOTP entries never reach here — their counter would have to be written back
/// and synced, which an extension cannot do.
struct VaultEntry: Codable {
  /// Stable id, used as the credential identity's `recordIdentifier`. This is
  /// `Code.generatedID` stringified.
  let id: String
  let issuer: String
  let account: String
  let secret: String
  let algorithm: TOTP.Algorithm
  let digits: Int
  let period: Int
  let kind: TOTP.Kind
  /// Domains this code should be offered for, in the QuickType bar.
  let serviceIdentifiers: [String]

  /// What the row and the credential identity are labelled with. Mirrors
  /// `Code.issuerAccount`.
  var label: String {
    account.isEmpty ? issuer : "\(issuer) (\(account))"
  }

  func code(atMillisecondsSinceEpoch milliseconds: Int64) -> String? {
    TOTP.generate(
      secret: secret,
      algorithm: algorithm,
      digits: digits,
      period: period,
      kind: kind,
      atMillisecondsSinceEpoch: milliseconds
    )
  }
}

struct Vault: Codable {
  static let currentVersion = 1

  let version: Int
  let entries: [VaultEntry]
  /// Clock skew correction from `PreferenceService.timeOffsetInMilliSeconds()`.
  let timeOffsetMs: Int
  /// True when the app has a PIN/password lock set. The extension bypasses the
  /// Flutter lock screen entirely, so this flag is the only thing that keeps
  /// AutoFill from being a way around it.
  let requiresAuth: Bool

  var nowMilliseconds: Int64 {
    Int64(Date().timeIntervalSince1970 * 1000) + Int64(timeOffsetMs)
  }

  func entry(withID id: String) -> VaultEntry? {
    entries.first { $0.id == id }
  }
}

/// Reads and writes the encrypted snapshot in the shared App Group container.
///
/// Two layers of protection, because this is a second copy of the user's TOTP
/// secrets living outside the Ente vault: AES-GCM with a key that never leaves
/// the keychain, plus the container file itself excluded from backups and
/// marked `completeUntilFirstUserAuthentication`.
enum VaultStore {
  enum StoreError: Error {
    case appGroupUnavailable
    case keychainFailure(OSStatus)
  }

  // MARK: - Locations

  private static func containerURL() throws -> URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: AutoFillConstants.appGroupIdentifier)
    else {
      throw StoreError.appGroupUnavailable
    }
    return url
  }

  private static func vaultURL() throws -> URL {
    let directory = try containerURL().appendingPathComponent(
      AutoFillConstants.vaultDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return directory.appendingPathComponent(AutoFillConstants.vaultFileName)
  }

  // MARK: - Reading and writing

  static func read() -> Vault? {
    guard let url = try? vaultURL() else {
      AutoFillLog.error("No App Group container; check the entitlement")
      return nil
    }
    guard let ciphertext = try? Data(contentsOf: url) else {
      AutoFillLog.error("No snapshot on disk; the app has not published one")
      return nil
    }
    guard let key = ((try? existingKey()) ?? nil) else {
      AutoFillLog.error("Snapshot key unreadable; check keychain-access-groups")
      return nil
    }

    do {
      let box = try AES.GCM.SealedBox(combined: ciphertext)
      let plaintext = try AES.GCM.open(box, using: key)
      let vault = try JSONDecoder().decode(Vault.self, from: plaintext)
      // A snapshot written by a newer build may not mean what this one thinks
      // it means; offering nothing beats offering a wrong code.
      guard vault.version == Vault.currentVersion else {
        AutoFillLog.error("Snapshot version \(vault.version) is not readable")
        return nil
      }
      return vault
    } catch {
      AutoFillLog.error("Could not open the snapshot: \(error.localizedDescription)")
      return nil
    }
  }

  static func write(_ vault: Vault) throws {
    let key = try existingKey() ?? createKey()
    let plaintext = try JSONEncoder().encode(vault)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealed.combined else { return }

    let destination = try vaultURL()
    // Write to a sibling and swap, so an extension launching mid-write reads
    // either the old snapshot or the new one, never a truncated file.
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent("\(AutoFillConstants.vaultFileName).tmp")
    try? FileManager.default.removeItem(at: temporary)
    try combined.write(
      to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      // replaceItemAt requires an existing original, so the first write moves.
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
    try excludeFromBackup(destination)
  }

  /// Removes both halves. Called on sign out, profile removal, and when the
  /// user turns AutoFill off — leaving either half behind would leave a usable
  /// snapshot or a stale key.
  static func clear() {
    if let url = try? vaultURL() {
      try? FileManager.default.removeItem(at: url)
    }
    SecItemDelete(baseKeychainQuery() as CFDictionary)
  }

  private static func excludeFromBackup(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  // MARK: - Key management

  private static func baseKeychainQuery() -> [String: Any] {
    // No kSecAttrAccessGroup: see the note in AutoFillConstants.
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AutoFillConstants.keychainService,
      kSecAttrAccount as String: AutoFillConstants.keychainAccount,
    ]
  }

  private static func existingKey() throws -> SymmetricKey? {
    var query = baseKeychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, data.count == 32 else {
        // Something else wrote under our service/account, or the item is
        // truncated. Drop it so createKey() can add a fresh one instead of
        // failing with errSecDuplicateItem forever.
        SecItemDelete(baseKeychainQuery() as CFDictionary)
        return nil
      }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      return nil
    default:
      throw StoreError.keychainFailure(status)
    }
  }

  private static func createKey() throws -> SymmetricKey {
    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }

    var query = baseKeychainQuery()
    query[kSecValueData as String] = data
    // Same class the app already uses for its own secrets (see IOSOptions in
    // lib/core/configuration.dart): readable in the background after the first
    // unlock, never synced to another device or a backup.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw StoreError.keychainFailure(status)
    }
    return key
  }
}
