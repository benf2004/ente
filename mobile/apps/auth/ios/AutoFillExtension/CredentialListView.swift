import SwiftUI

/// The picker shown when iOS asks Ente for a one-time code but has not already
/// settled on one identity — either because nothing matched the site, or
/// because the user tapped through to see everything.
struct CredentialListView: View {
  let vault: Vault
  /// Hosts iOS says the request is for, already normalised.
  let requestedHosts: [String]
  let onSelect: (String) -> Void
  let onCancel: () -> Void

  @State private var searchText = ""
  @State private var now = Date()

  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack {
      List {
        if !matching.isEmpty {
          Section(sectionTitle) {
            ForEach(matching, id: \.id) { row($0) }
          }
        }
        if !others.isEmpty {
          Section(matching.isEmpty ? "Your codes" : "All codes") {
            ForEach(others, id: \.id) { row($0) }
          }
        }
        if matching.isEmpty && others.isEmpty {
          Text("No codes match “\(searchText)”")
            .foregroundStyle(.secondary)
        }
      }
      .listStyle(.insetGrouped)
      .searchable(text: $searchText, prompt: "Search codes")
      .navigationTitle("Ente Auth")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
    .onReceive(ticker) { now = $0 }
  }

  // MARK: - Rows

  @ViewBuilder
  private func row(_ entry: VaultEntry) -> some View {
    let code = entry.code(atMillisecondsSinceEpoch: milliseconds)
    Button {
      // Recomputed on tap rather than reusing the rendered value: a tap landing
      // just after a period boundary must fill the code that is valid now.
      if let fresh = entry.code(atMillisecondsSinceEpoch: vault.nowMilliseconds) {
        onSelect(fresh)
      }
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.issuer.isEmpty ? entry.account : entry.issuer)
            .font(.body)
            .foregroundStyle(.primary)
          if !entry.account.isEmpty && !entry.issuer.isEmpty {
            Text(entry.account)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if let code {
          Text(grouped(code))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.primary)
          Text("\(TOTP.secondsRemaining(period: entry.period, atMillisecondsSinceEpoch: milliseconds))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, alignment: .trailing)
        } else {
          Text("Invalid")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .disabled(code == nil)
  }

  /// Splits the code down the middle, the way the app and most authenticators
  /// render it, so it stays scannable at a glance.
  private func grouped(_ code: String) -> String {
    guard code.count > 4 else { return code }
    let middle = code.index(code.startIndex, offsetBy: code.count / 2)
    return "\(code[code.startIndex..<middle]) \(code[middle...])"
  }

  // MARK: - Filtering

  /// Driven by `now` so the whole list re-renders every second.
  private var milliseconds: Int64 {
    Int64(now.timeIntervalSince1970 * 1000) + Int64(vault.timeOffsetMs)
  }

  private var sectionTitle: String {
    requestedHosts.first.map { "For \($0)" } ?? "Suggested"
  }

  private var searched: [VaultEntry] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return vault.entries }
    return vault.entries.filter {
      $0.issuer.lowercased().contains(query) || $0.account.lowercased().contains(query)
    }
  }

  private var matching: [VaultEntry] {
    guard !requestedHosts.isEmpty else { return [] }
    return searched.filter { entry in
      entry.serviceIdentifiers.contains { stored in
        requestedHosts.contains { Self.hostsMatch(stored: stored, requested: $0) }
      }
    }
  }

  private var others: [VaultEntry] {
    let matchedIDs = Set(matching.map(\.id))
    return searched.filter { !matchedIDs.contains($0.id) }
  }

  /// `accounts.google.com` should match a code stored against `google.com`, but
  /// `notgoogle.com` should not — hence the leading dot on the suffix test.
  static func hostsMatch(stored: String, requested: String) -> Bool {
    if stored == requested { return true }
    return requested.hasSuffix(".\(stored)") || stored.hasSuffix(".\(requested)")
  }
}

/// Shown when the app has not published a snapshot yet — most often because
/// AutoFill was enabled in iOS Settings before it was turned on in Ente.
struct CredentialEmptyView: View {
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Image(systemName: "lock.rectangle.stack")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("No codes available")
          .font(.headline)
        Text("Open Ente Auth and turn on AutoFill in Settings → General.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
  }
}
