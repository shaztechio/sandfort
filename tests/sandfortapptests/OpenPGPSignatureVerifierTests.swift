import XCTest
@testable import SandfortApp

/// Tests for SECURITY-CRITICAL code. A signature verifier's dangerous failure
/// mode is accepting something it should reject, so the negative cases below
/// matter at least as much as the positive one.
final class OpenPGPSignatureVerifierTests: XCTestCase {
    /// The official openSUSE `.sha256` file for the pinned Leap 16 image,
    /// base64-encoded so the exact signed bytes survive editing.
    private let signedChecksumFile = Data(base64Encoded: "MmU5ZWViNTZlNzUyMzc3NWYxZjAxMjYxZjQ5MDBmMjg5ZTIwYzM4OTEwMjI2YjBjMWU1YWE3MjI4YTg0MTk0YSAgTGVhcC0xNi4wLU1pbmltYWwtVk0uYWFyY2g2NC1DbG91ZC1CdWlsZDE4LjcucWNvdzIK")!

    /// The official detached `.sha256.asc` signature for that file.
    private let detachedSignature = """
        -----BEGIN PGP SIGNATURE-----
        Version: GnuPG v2.4.4 (GNU/Linux)
        
        iQIVAwUAajTUIDWi+G4ptwCkAQq64BAAkCJPitUf9CP1VksRmHluM+FGyf/AStvW
        5xM0WdIYE8Zr+ygueknSp0oVW5Oq8jubib6dEZUzwf6Y5xRNv610fUdOQAlSGNuZ
        6nygaMOyBHhPbrWaIYng2VfQD/EsQghpzH2aZvSrMi0/CYYMquTIC2CFKb6o9w4C
        RoD3Q7eKBcx4rbTxuo+bHqTaIC4lMcrwOSPHXXM5a04Da1CSV1VVG9PjYiM0Swcm
        LDQshIWORe0f/QM/ZfRERvFX5x7ho2tEXWEKunfEEfNqIdPO4Jnx04Q6T2j2tPBm
        3o1YqwY+f5ybLeGNd7JCjoaFm5mUZVEO5iVcXzt2lhMj3Es81zqeTcxMwXh/xsjj
        RVdLR4XvBI/W668BK+c7ub/pJkSZBnx7leVQ/0TLWXpv3gGlmJA4qVZvwa46cL/a
        MnNaKKVDzKqLttwtc4hy9slaRYoctoItTWBqnCQ/AC6Y0mLdtYO7lTPAk2QgiYfe
        +lorCYcPpWhdSVGL6Fs5ULHy6zb44kHCt/YRTjQJPx4/n+sBsrs/+QCBl+0xL1Gk
        w+H2UGj9TrYpsXHCC7FWqcOlWImOcBZfuJZKIY4IgldNNNTD/wToseDF441CowZ3
        +OWSuWShAzUAExS6nMgIxb5W+zH6YktDTi4AN2mW5ZDQh5PUMQ2B+WzIAoi9xZ5C
        GTMzhzdEc7c=
        =fwos
        -----END PGP SIGNATURE-----
"""

    private func pinnedKey() throws -> OpenPGPSignatureVerifier.PublicKey {
        try OpenPGPSignatureVerifier.publicKey(
            armored: TrustedSigningKeys.openSUSEPublicKey,
            pinnedFingerprint: TrustedSigningKeys.openSUSEFingerprint
        )
    }

    func testBundledOpenSUSEKeyMatchesItsPinnedFingerprint() throws {
        let key = try pinnedKey()
        XCTAssertEqual(key.fingerprint, "AD485664E901B867051AB15F35A2F86E29B700A4")
        XCTAssertEqual(key.keyID, "35A2F86E29B700A4")
        XCTAssertEqual(key.modulus.count, 512)
    }

    func testOfficialOpenSUSEChecksumSignatureVerifies() throws {
        let verified = try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: detachedSignature,
            over: signedChecksumFile,
            using: try pinnedKey()
        )
        XCTAssertEqual(verified.keyID, "35A2F86E29B700A4")
        XCTAssertEqual(verified.signatureVersion, 3)
        XCTAssertEqual(verified.hashAlgorithm, "SHA-512")
    }

    /// The point of verifying at all: the checksum openSUSE signed must be the
    /// exact value pinned in the catalog, not merely a value served at a URL.
    func testSignedChecksumIsTheValuePinnedInTheCatalog() throws {
        try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: detachedSignature,
            over: signedChecksumFile,
            using: try pinnedKey()
        )
        let signedText = String(decoding: signedChecksumFile, as: UTF8.self)
        let signedHash = signedText.split(separator: " ").first.map(String.init)
        XCTAssertEqual(signedHash, LinuxGuestCatalog.opensuseLeap16ARM64.image.sha256)
        XCTAssertTrue(signedText.contains(LinuxGuestCatalog.opensuseLeap16ARM64.image.fileName))
    }

    func testTamperedPayloadIsRejected() throws {
        var tampered = signedChecksumFile
        tampered[tampered.startIndex] = tampered[tampered.startIndex] ^ 0x01
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: detachedSignature,
            over: tampered,
            using: try pinnedKey()
        ))
    }

    /// Mutating the signature itself leaves the stored digest prefix intact, so
    /// this exercises the real RSA verification rather than the cheap precheck.
    func testTamperedSignatureFailsRSAVerificationNotJustThePrefixCheck() throws {
        let key = try pinnedKey()
        var raw = try XCTUnwrap(Data(base64Encoded: base64Body(of: detachedSignature)))
        raw[raw.count - 1] = raw[raw.count - 1] ^ 0xFF
        let rearmored = rearmor(raw)
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: rearmored,
            over: signedChecksumFile,
            using: key
        )) { error in
            XCTAssertEqual(
                error as? OpenPGPSignatureVerifier.VerificationError,
                .signatureIsNotValid
            )
        }
    }

    func testKeyWithUnexpectedFingerprintIsRejected() {
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.publicKey(
            armored: TrustedSigningKeys.openSUSEPublicKey,
            pinnedFingerprint: "0000 0000 0000 0000 0000 0000 0000 0000 0000 0000"
        )) { error in
            guard case .fingerprintMismatch = error as? OpenPGPSignatureVerifier.VerificationError else {
                return XCTFail("Expected a pinned-fingerprint mismatch")
            }
        }
    }

    func testCorruptedArmorChecksumIsRejected() throws {
        let corrupted = detachedSignature.replacingOccurrences(of: "=fwos", with: "=AAAA")
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: corrupted,
            over: signedChecksumFile,
            using: try pinnedKey()
        )) { error in
            XCTAssertEqual(
                error as? OpenPGPSignatureVerifier.VerificationError,
                .armorChecksumMismatch
            )
        }
    }

    func testTruncatedPacketIsRejectedRatherThanReadPastTheBuffer() throws {
        let key = try pinnedKey()
        let raw = try XCTUnwrap(Data(base64Encoded: base64Body(of: detachedSignature)))
        for truncation in [3, 20, raw.count / 2, raw.count - 1] {
            XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
                armored: rearmor(raw.prefix(truncation)),
                over: signedChecksumFile,
                using: key
            ), "Truncation at \(truncation) must be refused")
        }
    }

    func testGarbageArmorIsRejected() throws {
        let key = try pinnedKey()
        for blob in ["", "not armor at all", "-----BEGIN PGP SIGNATURE-----\n\n-----END PGP SIGNATURE-----"] {
            XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
                armored: blob,
                over: signedChecksumFile,
                using: key
            ))
        }
    }

    // MARK: - Fixtures

    private func base64Body(of armored: String) -> String {
        armored.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.hasPrefix("=") && !$0.contains(": ") && !$0.isEmpty }
            .joined()
    }

    /// Rebuilds an armored block without a checksum line, which current OpenPGP
    /// permits, so a test can alter the packet without the CRC masking it.
    private func rearmor(_ data: Data) -> String {
        """
        -----BEGIN PGP SIGNATURE-----

        \(data.base64EncodedString())
        -----END PGP SIGNATURE-----
        """
    }
}
