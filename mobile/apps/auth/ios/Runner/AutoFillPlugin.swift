import AuthenticationServices
import Flutter
import Foundation

/// Bridges the Flutter app to the AutoFill snapshot and the system credential
/// identity store.
///
/// Registration is done from the app process rather than the extension: it is
/// allowed, and it means the extension only ever wakes up to actually serve a
/// code.
final class AutoFillPlugin: NSObject, FlutterPlugin {

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: AutoFillConstants.methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AutoFillPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported)
    case "getState":
      getState(result: result)
    case "sync":
      sync(call: call, result: result)
    case "clear":
      clear(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// One-time-code AutoFill for third-party providers is iOS 18 and up. Below
  /// that the app hides the whole feature rather than offering a toggle that
  /// does nothing.
  private var isSupported: Bool {
    if #available(iOS 18.0, *) { return true }
    return false
  }

  /// Whether the user has actually enabled Ente under Settings → General →
  /// AutoFill & Passwords. Registering identities is a no-op until they do, so
  /// the settings screen uses this to tell them what is still missing.
  private func getState(result: @escaping FlutterResult) {
    guard isSupported else {
      result(false)
      return
    }
    ASCredentialIdentityStore.shared.getState { state in
      result(state.isEnabled)
    }
  }

  private func sync(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard isSupported else {
      result(false)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let rawEntries = arguments["entries"] as? [[String: Any]]
    else {
      result(
        FlutterError(code: "bad_arguments", message: "Expected entries", details: nil))
      return
    }

    let entries = rawEntries.compactMap(Self.entry(from:))
    let vault = Vault(
      version: Vault.currentVersion,
      entries: entries,
      timeOffsetMs: arguments["timeOffsetMs"] as? Int ?? 0,
      requiresAuth: arguments["requiresAuth"] as? Bool ?? false
    )

    do {
      try VaultStore.write(vault)
    } catch {
      result(
        FlutterError(
          code: "vault_write_failed", message: error.localizedDescription, details: nil))
      return
    }

    replaceIdentities(for: entries) { outcome in
      switch outcome {
      case .registered:
        result(true)
      case .storeDisabled:
        // The vault is written and valid; iOS just will not hold identities
        // until the user enables Ente under Settings → AutoFill & Passwords.
        // Reported rather than thrown so the app knows to register again once
        // they do.
        result(false)
      case .failed(let error):
        result(
          FlutterError(
            code: "identity_store_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func clear(result: @escaping FlutterResult) {
    VaultStore.clear()
    guard isSupported else {
      result(true)
      return
    }
    ASCredentialIdentityStore.shared.removeAllCredentialIdentities { _, _ in
      result(true)
    }
  }

  // MARK: - Identity store

  @available(iOS 18.0, *)
  private func identities(for entries: [VaultEntry]) -> [ASOneTimeCodeCredentialIdentity] {
    entries.flatMap { entry in
      // One identity per domain: ASCredentialServiceIdentifier holds a single
      // service, so a code used on several sites needs several identities. They
      // share a recordIdentifier, which is what the fill path looks up.
      entry.serviceIdentifiers.map { domain in
        ASOneTimeCodeCredentialIdentity(
          serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
          label: entry.label,
          recordIdentifier: entry.id
        )
      }
    }
  }

  private enum IdentityOutcome {
    case registered
    case storeDisabled
    case failed(Error)
  }

  private func replaceIdentities(
    for entries: [VaultEntry], completion: @escaping (IdentityOutcome) -> Void
  ) {
    guard #available(iOS 18.0, *) else {
      completion(.storeDisabled)
      return
    }
    let identities = self.identities(for: entries)
    // replaceCredentialIdentities rather than save: deletions, renames and
    // profile switches then converge without the app tracking a diff.
    ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { success, error in
      if success {
        completion(.registered)
      } else if let error,
        (error as NSError).domain == ASCredentialIdentityStoreErrorDomain,
        (error as NSError).code == ASCredentialIdentityStoreError.storeDisabled.rawValue
      {
        completion(.storeDisabled)
      } else if let error {
        completion(.failed(error))
      } else {
        completion(.storeDisabled)
      }
    }
  }

  // MARK: - Decoding

  private static func entry(from json: [String: Any]) -> VaultEntry? {
    guard
      let id = json["id"] as? String,
      let secret = json["secret"] as? String,
      !secret.isEmpty
    else { return nil }

    return VaultEntry(
      id: id,
      issuer: json["issuer"] as? String ?? "",
      account: json["account"] as? String ?? "",
      secret: secret,
      algorithm: TOTP.Algorithm(rawValue: json["algorithm"] as? String ?? "sha1") ?? .sha1,
      digits: json["digits"] as? Int ?? 6,
      period: json["period"] as? Int ?? 30,
      kind: TOTP.Kind(rawValue: json["kind"] as? String ?? "totp") ?? .totp,
      serviceIdentifiers: json["serviceIdentifiers"] as? [String] ?? []
    )
  }
}
