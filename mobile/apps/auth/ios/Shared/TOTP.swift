import CryptoKit
import Foundation

/// Time-based one-time passwords, computed natively so the AutoFill extension
/// does not need Flutter.
///
/// This is a second implementation of what `lib/utils/totp_util.dart` does with
/// `package:otp`, and the two silently diverging is the main long-lived risk in
/// the AutoFill feature. Anything changed here needs a matching look at
/// `getOTP()`; `AutoFillTOTPTests` pins both against RFC 6238 vectors.
enum TOTP {
  enum Algorithm: String, Codable {
    case sha1
    case sha256
    case sha512
  }

  enum Kind: String, Codable {
    case totp
    case steam
  }

  /// Steam encodes the truncated value in its own 26-character alphabet rather
  /// than as decimal digits.
  private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
  private static let steamDigits = 5

  /// - Parameter date: milliseconds since epoch, already offset-corrected by the
  ///   caller. The app applies `PreferenceService.timeOffsetInMilliSeconds()`
  ///   for users whose device clock drifts from the server; the extension has
  ///   no access to that preference, so the offset travels in the snapshot.
  static func generate(
    secret: String,
    algorithm: Algorithm,
    digits: Int,
    period: Int,
    kind: Kind,
    atMillisecondsSinceEpoch milliseconds: Int64
  ) -> String? {
    guard let key = Base32.decode(secret), !key.isEmpty else { return nil }
    guard period > 0 else { return nil }

    let counter = UInt64(max(0, milliseconds / 1000) / Int64(period))
    let digest = hmac(key: key, counter: counter, algorithm: algorithm)
    let truncated = truncate(digest)

    switch kind {
    case .steam:
      return steamCode(from: truncated)
    case .totp:
      // Clamped at 9 because a 10-digit modulus overflows UInt32, and no issuer
      // emits more than 8.
      let width = min(max(digits, 1), 9)
      let modulus = UInt32(pow(10.0, Double(width)))
      let value = truncated % modulus
      return String(format: "%0\(width)u", value)
    }
  }

  /// Seconds remaining in the current step, for the countdown in the extension's
  /// code list.
  static func secondsRemaining(period: Int, atMillisecondsSinceEpoch milliseconds: Int64) -> Int {
    guard period > 0 else { return 0 }
    let seconds = max(0, milliseconds / 1000)
    return period - Int(seconds % Int64(period))
  }

  private static func hmac(key: Data, counter: UInt64, algorithm: Algorithm) -> Data {
    var bigEndianCounter = counter.bigEndian
    let message = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)
    let symmetricKey = SymmetricKey(data: key)

    switch algorithm {
    case .sha1:
      return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
    case .sha256:
      return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
    case .sha512:
      return Data(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
    }
  }

  /// RFC 4226 dynamic truncation.
  private static func truncate(_ digest: Data) -> UInt32 {
    let bytes = [UInt8](digest)
    let offset = Int(bytes[bytes.count - 1] & 0x0F)
    let value =
      (UInt32(bytes[offset] & 0x7F) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
    return value
  }

  private static func steamCode(from truncated: UInt32) -> String {
    var remainder = truncated
    var code = ""
    for _ in 0..<steamDigits {
      let index = Int(remainder % UInt32(steamAlphabet.count))
      code.append(steamAlphabet[index])
      remainder /= UInt32(steamAlphabet.count)
    }
    return code
  }
}
