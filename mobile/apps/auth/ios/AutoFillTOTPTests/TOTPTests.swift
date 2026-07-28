import XCTest

/// Pins `TOTP.swift` (and `Base32.swift`) against published RFC 6238 test
/// vectors and a known-good Steam vector, so that a change to either file is
/// caught here rather than surfacing as a wrong code in the AutoFill
/// extension. See the note atop `TOTP.swift`: this is a second, independent
/// implementation of what `lib/utils/totp_util.dart` does with `package:otp`
/// and `package:steam_totp`, and the two silently diverging is the main
/// long-lived risk in the AutoFill feature.
///
/// The RFC 6238 seeds and expected codes below are Appendix B of the RFC,
/// reproduced (and independently re-derived from the RFC's own HMAC-based
/// algorithm) rather than typed from memory. The Steam vector is the one
/// `package:steam_totp` itself ships as `steam_totp_test.dart`, so a Steam
/// code computed here and one computed by the Dart app are pinned to the same
/// known-good value.
final class TOTPTests: XCTestCase {

  // MARK: - RFC 6238 Appendix B

  /// ASCII "12345678901234567890", repeated/truncated per algorithm and
  /// base32 encoded, exactly as RFC 6238 Appendix B specifies.
  private let seedSHA1 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
  private let seedSHA256 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA===="
  private let seedSHA512 =
    "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA="

  private struct Vector {
    let seconds: Int64
    let sha1: String
    let sha256: String
    let sha512: String
  }

  /// Every row of RFC 6238 Appendix B's table, 8 digits, 30 second step.
  private let vectors: [Vector] = [
    Vector(seconds: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
    Vector(seconds: 1_111_111_109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
    Vector(seconds: 1_111_111_111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
    Vector(seconds: 1_234_567_890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
    Vector(seconds: 2_000_000_000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
    Vector(seconds: 20_000_000_000, sha1: "65353130", sha256: "77737706", sha512: "47863826"),
  ]

  func testRFC6238Vectors() {
    for vector in vectors {
      let milliseconds = vector.seconds * 1000
      XCTAssertEqual(
        TOTP.generate(
          secret: seedSHA1, algorithm: .sha1, digits: 8, period: 30, kind: .totp,
          atMillisecondsSinceEpoch: milliseconds),
        vector.sha1, "SHA1 mismatch at T=\(vector.seconds)")
      XCTAssertEqual(
        TOTP.generate(
          secret: seedSHA256, algorithm: .sha256, digits: 8, period: 30, kind: .totp,
          atMillisecondsSinceEpoch: milliseconds),
        vector.sha256, "SHA256 mismatch at T=\(vector.seconds)")
      XCTAssertEqual(
        TOTP.generate(
          secret: seedSHA512, algorithm: .sha512, digits: 8, period: 30, kind: .totp,
          atMillisecondsSinceEpoch: milliseconds),
        vector.sha512, "SHA512 mismatch at T=\(vector.seconds)")
    }
  }

  /// A 6 digit, 30 second SHA1 code — the common case for the issuers users
  /// actually add — independently re-derived from the RFC's algorithm rather
  /// than the 8 digit Appendix B table, and checked either side of a period
  /// boundary (29s -> 30s) to pin the truncation, not just the digest.
  func test6DigitCommonCase() {
    let secret = "JBSWY3DPEHPK3PXP"
    XCTAssertEqual(
      TOTP.generate(
        secret: secret, algorithm: .sha1, digits: 6, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 29_000),
      "282760")
    XCTAssertEqual(
      TOTP.generate(
        secret: secret, algorithm: .sha1, digits: 6, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 30_000),
      "996554")
    XCTAssertEqual(
      TOTP.generate(
        secret: secret, algorithm: .sha1, digits: 6, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 1_111_111_111_000),
      "358462")
  }

  /// Width is clamped to 9 (see the comment in `TOTP.swift`); asserts the
  /// clamp lands on the correct digits rather than merely not crashing, by
  /// checking against the 9 digit reduction of the same RFC vector above.
  func testDigitsClampedToNine() {
    XCTAssertEqual(
      TOTP.generate(
        secret: seedSHA1, algorithm: .sha1, digits: 10, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 59_000),
      "094287082")
  }

  // MARK: - Steam

  /// `SteamTOTP(secret: 'AA').generate(42)` in `steam_totp_test.dart` — the
  /// Dart package's own pinned vector, reused here so a Swift/Dart divergence
  /// in Steam codes would fail one or the other test suite.
  func testSteamVector() {
    XCTAssertEqual(
      TOTP.generate(
        secret: "AA", algorithm: .sha1, digits: 5, period: 30, kind: .steam,
        atMillisecondsSinceEpoch: 42_000),
      "DR2DK")
  }

  // MARK: - Edge cases

  func testInvalidSecretReturnsNil() {
    XCTAssertNil(
      TOTP.generate(
        secret: "not valid base32!!", algorithm: .sha1, digits: 6, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 0))
  }

  func testEmptySecretReturnsNil() {
    XCTAssertNil(
      TOTP.generate(
        secret: "", algorithm: .sha1, digits: 6, period: 30, kind: .totp,
        atMillisecondsSinceEpoch: 0))
  }

  func testNonPositivePeriodReturnsNil() {
    XCTAssertNil(
      TOTP.generate(
        secret: seedSHA1, algorithm: .sha1, digits: 6, period: 0, kind: .totp,
        atMillisecondsSinceEpoch: 0))
    XCTAssertNil(
      TOTP.generate(
        secret: seedSHA1, algorithm: .sha1, digits: 6, period: -30, kind: .totp,
        atMillisecondsSinceEpoch: 0))
  }

  func testSecondsRemaining() {
    XCTAssertEqual(TOTP.secondsRemaining(period: 30, atMillisecondsSinceEpoch: 0), 30)
    XCTAssertEqual(TOTP.secondsRemaining(period: 30, atMillisecondsSinceEpoch: 29_000), 1)
    XCTAssertEqual(TOTP.secondsRemaining(period: 30, atMillisecondsSinceEpoch: 30_000), 30)
    XCTAssertEqual(TOTP.secondsRemaining(period: 0, atMillisecondsSinceEpoch: 30_000), 0)
  }
}

/// `Base32.swift` is the other half of the divergence risk: a decode that
/// disagrees with the reference implementations makes every code above wrong
/// in the extension while the app keeps computing the right one.
final class Base32Tests: XCTestCase {

  func testDecodesLowercaseWhitespaceAndDashes() {
    let canonical = Base32.decode("JBSWY3DPEHPK3PXP")
    XCTAssertEqual(Base32.decode("jbswy3dpehpk3pxp"), canonical)
    XCTAssertEqual(Base32.decode("jb sw y3-dp eh pk3pxp"), canonical)
    XCTAssertEqual(Base32.decode("JBSW Y3DP EHPK 3PXP"), canonical)
  }

  func testIgnoresPadding() {
    XCTAssertEqual(Base32.decode("MFRGG==="), Base32.decode("MFRGG"))
  }

  func testRejectsInvalidCharacters() {
    XCTAssertNil(Base32.decode("not valid base32!!"))
  }

  func testRejectsEmptyInput() {
    XCTAssertNil(Base32.decode(""))
    XCTAssertNil(Base32.decode("===="))
  }
}
