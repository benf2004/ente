import AuthenticationServices
import LocalAuthentication
import SwiftUI
import UIKit

/// Serves Ente Auth's codes to the system one-time-code AutoFill flow.
///
/// The extension is a separate process with no Flutter engine, so it never
/// touches the Ente vault. Everything it knows comes from the encrypted
/// snapshot the app publishes into the shared App Group (`VaultStore`), and it
/// computes the OTP itself (`TOTP`).
class CredentialProviderViewController: ASCredentialProviderViewController {

  // MARK: - Zero-interaction fill

  /// Called when the user picks Ente from the QuickType bar and iOS thinks no
  /// UI is needed. Answering here is what makes the fill feel instant.
  override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
    AutoFillLog.info(
      "Fill requested without interaction, type \(credentialRequest.type.rawValue)")
    guard credentialRequest.type == .oneTimeCode else {
      cancel(.credentialIdentityNotFound)
      return
    }
    guard let vault = VaultStore.read() else {
      cancel(.credentialIdentityNotFound)
      return
    }
    // The Flutter app lock does not exist in this process, so honouring it here
    // is the only thing stopping AutoFill from being a way around it. Bouncing
    // to the interactive path makes iOS call
    // prepareInterfaceToProvideCredential, which authenticates.
    guard !vault.requiresAuth else {
      cancel(.userInteractionRequired)
      return
    }
    guard
      let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier,
      let entry = vault.entry(withID: recordIdentifier),
      let code = entry.code(atMillisecondsSinceEpoch: vault.nowMilliseconds)
    else {
      cancel(.credentialIdentityNotFound)
      return
    }
    complete(with: code)
  }

  // MARK: - Interactive fill

  /// The identity is already known; we only need whatever interaction
  /// provideCredentialWithoutUserInteraction declined to do.
  override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
    guard credentialRequest.type == .oneTimeCode,
      let vault = VaultStore.read(),
      let recordIdentifier = credentialRequest.credentialIdentity.recordIdentifier,
      let entry = vault.entry(withID: recordIdentifier)
    else {
      cancel(.credentialIdentityNotFound)
      return
    }

    authenticateIfNeeded(vault: vault) { [weak self] authenticated in
      guard let self else { return }
      guard authenticated else {
        self.cancel(.userCanceled)
        return
      }
      guard let code = entry.code(atMillisecondsSinceEpoch: vault.nowMilliseconds) else {
        self.cancel(.credentialIdentityNotFound)
        return
      }
      self.complete(with: code)
    }
  }

  // MARK: - Code list

  /// The fallback that keeps the feature useful when domain matching misses:
  /// every code, searchable, with the ones matching the current site first.
  override func prepareOneTimeCodeCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier]
  ) {
    guard let vault = VaultStore.read(), !vault.entries.isEmpty else {
      showHostedView(AnyView(CredentialEmptyView(onCancel: { [weak self] in
        self?.cancel(.userCanceled)
      })))
      return
    }

    authenticateIfNeeded(vault: vault) { [weak self] authenticated in
      guard let self else { return }
      guard authenticated else {
        self.cancel(.userCanceled)
        return
      }
      let list = CredentialListView(
        vault: vault,
        requestedHosts: serviceIdentifiers.map { Self.host(from: $0) },
        onSelect: { [weak self] code in self?.complete(with: code) },
        onCancel: { [weak self] in self?.cancel(.userCanceled) }
      )
      self.showHostedView(AnyView(list))
    }
  }

  // MARK: - Helpers

  /// Reduces a service identifier to a bare host so it can be compared with the
  /// domains stored against a code. iOS hands us a domain for native apps and
  /// a full URL for web pages.
  static func host(from identifier: ASCredentialServiceIdentifier) -> String {
    let raw = identifier.identifier.lowercased()
    let host: String
    if identifier.type == .URL, let parsed = URL(string: raw)?.host {
      host = parsed
    } else if let parsed = URL(string: "https://\(raw)")?.host {
      host = parsed
    } else {
      host = raw
    }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private func authenticateIfNeeded(vault: Vault, completion: @escaping (Bool) -> Void) {
    guard vault.requiresAuth else {
      completion(true)
      return
    }
    let context = LAContext()
    // .deviceOwnerAuthentication, not biometrics-only: a user whose Face ID
    // fails must still be able to fall back to the device passcode, the same
    // as the app's own lock screen.
    context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: NSLocalizedString(
        "Authenticate to fill your code", comment: "AutoFill biometric prompt")
    ) { success, _ in
      DispatchQueue.main.async { completion(success) }
    }
  }

  private func showHostedView(_ view: AnyView) {
    let hosting = UIHostingController(rootView: view)
    addChild(hosting)
    hosting.view.frame = self.view.bounds
    hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.view.addSubview(hosting.view)
    hosting.didMove(toParent: self)
  }

  private func complete(with code: String) {
    // Length only — never the code itself.
    AutoFillLog.info("Returning a \(code.count) character code")
    extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
  }

  private func cancel(_ code: ASExtensionError.Code) {
    AutoFillLog.error("Cancelling the AutoFill request: \(String(describing: code))")
    extensionContext.cancelRequest(
      withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
  }
}
