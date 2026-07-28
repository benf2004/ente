import Foundation

/// User-facing strings shared by more than one view in the extension.
///
/// Localized the same way as the rest of this file's siblings — `NSLocalizedString`
/// with the English text as the key, looked up in `Localizable.xcstrings` — so a
/// second occurrence of the same phrase (e.g. "Cancel" in both `CredentialListView`
/// and `CredentialEmptyView`) shares one catalog entry instead of two.
enum Strings {
  static var cancel: String {
    NSLocalizedString("Cancel", comment: "Dismisses the AutoFill sheet without filling a code")
  }

  static var suggested: String {
    NSLocalizedString(
      "Suggested", comment: "Section header in the AutoFill code list when iOS did not name a site")
  }

  static var yourCodes: String {
    NSLocalizedString(
      "Your codes",
      comment: "Section header listing every code, shown when none matched the requested site")
  }

  static var allCodes: String {
    NSLocalizedString(
      "All codes",
      comment: "Section header listing every code below the ones that matched the requested site")
  }

  static var invalid: String {
    NSLocalizedString(
      "Invalid", comment: "Shown in place of a code when TOTP generation failed for an entry")
  }
}
