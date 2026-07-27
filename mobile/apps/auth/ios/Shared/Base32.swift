import Foundation

/// RFC 4648 base32 decoding for TOTP shared secrets.
///
/// Mirrors `getSanitizedSecret()` in `lib/utils/totp_util.dart`: secrets are
/// upper-cased and stripped of whitespace before decoding. Padding is optional
/// because plenty of issuers emit unpadded secrets, and `package:otp` accepts
/// them, so refusing them here would make AutoFill fail for codes that work
/// fine inside the app.
enum Base32 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  private static let decodeTable: [UInt8: UInt8] = {
    var table = [UInt8: UInt8]()
    for (index, character) in alphabet.enumerated() {
      table[character.asciiValue!] = UInt8(index)
    }
    return table
  }()

  /// Returns nil when the input contains a character outside the base32
  /// alphabet, so callers can skip a malformed entry rather than filling a
  /// wrong code.
  static func decode(_ input: String) -> Data? {
    let sanitized = input
      .uppercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
    let stripped = sanitized.prefix(while: { $0 != "=" })
    if stripped.isEmpty { return nil }

    var output = Data()
    var buffer: UInt32 = 0
    var bitsInBuffer: UInt32 = 0

    for character in stripped.utf8 {
      guard let value = decodeTable[character] else { return nil }
      buffer = (buffer << 5) | UInt32(value)
      bitsInBuffer += 5
      if bitsInBuffer >= 8 {
        bitsInBuffer -= 8
        output.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
      }
    }

    // Leftover bits are the padding remainder and are discarded, matching the
    // reference implementations.
    return output
  }
}
