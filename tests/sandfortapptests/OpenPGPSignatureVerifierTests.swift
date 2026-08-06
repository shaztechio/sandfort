// Copyright 2026 Shazron Abdullah and Sandfort contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

    // MARK: - Ubuntu

    /// The official Ubuntu `SHA256SUMS` for the pinned noble release, base64
    /// encoded so the exact signed bytes survive editing.
    private let ubuntuChecksumFile = Data(base64Encoded: """
        MDE0ZjQ0N2U2Y2IwNGVlZGViODU5MDEwN2I3MzkxZTgzOGJjZDVjMzQ0NWU2YTVhYWU5MTY4NjRh
        MGVlZDQ3ZCAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm1oZi5tYW5pZmVzdAowYzMw
        MDY2ZTllNDZmNzg1ZDE4MDdiODVmZGRmZDkxNThiNGYyYTRkMDQ4ZjZkMTNiOGU1MGQ5NmI1NWE5
        ZWQ1ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQuaW1nCjE1NGM5NzljMzg5
        ZTkwYWU2NzZiNDIwMzI2ZTczZWI4ZmI2Yjg4ZWY5NGRhMjFmNTIzYjQwNjk0MTBlMWQxNTQgKnVi
        dW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQtcm9vdC50YXIueHoKMWIxNjAxN2VhMzc4
        YWE0MmQzZjY3ZmVlZWJjN2Q1ODA5NzlkMTQ4Mjg4NWNhOTMwYTlhMTMxNDRmZTI3M2EyYiAqdWJ1
        bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LXJvb3QubWFuaWZlc3QKMWIxNjAxN2Vh
        Mzc4YWE0MmQzZjY3ZmVlZWJjN2Q1ODA5NzlkMTQ4Mjg4NWNhOTMwYTlhMTMxNDRmZTI3M2EyYiAq
        dWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LnNxdWFzaGZzLm1hbmlmZXN0CjFi
        ZjkyZjAzNzUyZDY0ZGM4MjYwYjFiZDgyM2IxNmVlNzMyMDNjZDJkMzkwYTA1MTY2MzU4M2YwODgz
        ZjU4MjIgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctczM5MHguZGFpbHkuMjAyNjA3MDUu
        MjAyNjA3MjUuaW1hZ2VfY2hhbmdlbG9nLmpzb24KMjQzZjI5MThlYjgwYmM4ZjIxNDk1ODIwYTRk
        ZGM1ZTE5OTBiMDVlZGY2ZWZiMmYyZjhlN2NkOTJmYjI0MDJkZiAqdWJ1bnR1LTI0LjA0LXNlcnZl
        ci1jbG91ZGltZy1wcGM2NGVsLmltZwoyODk2NGI5MTNlZGJjNTEwYmI3YWI4Yjc3N2U4YTM1ZDEz
        Njg0ZjQ5OTNkNTQxYTZmMTQwNDhiZjdjYTE3NGEwICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3Vk
        aW1nLWFtZDY0LnJlbGVhc2UuMjAyNjA3MDUuMjAyNjA3MjUuaW1hZ2VfY2hhbmdlbG9nLmpzb24K
        Mjg5NjRiOTEzZWRiYzUxMGJiN2FiOGI3NzdlOGEzNWQxMzY4NGY0OTkzZDU0MWE2ZjE0MDQ4YmY3
        Y2ExNzRhMCAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC5yZWxlYXNlLjIwMjYw
        NzA1LjIwMjYwNzI1LmltYWdlX2NoYW5nZWxvZy5qc29uCjJlNDA4MDQyZDMzNzYzMTZhNDliZGI2
        M2FiMmMzNDcxZDQyNzYzMzZiNzdhZDFlOWU4ZTQ5ZGUwZjNhMTM2MzYgKnVidW50dS0yNC4wNC1z
        ZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5kYWlseS4yMDI2MDcwNS4yMDI2MDcyNS5pbWFnZV9jaGFu
        Z2Vsb2cuanNvbgoyZWFlYzcyODZjNDlmZGVhNzEzZGRkYWJjZjUwMTJjYWZhNzA5N2E2NThlOTE2
        YWNiNDhmNGJjNWZkYzhlNDE5ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0Lmlt
        Zwo0N2E0ZTMxNDY4NDMwNzkxOWRkNzUyMjk3YzRjNmEyMDAwNzJkODVmZmQ2MDVlODY2ZTliNTRi
        YWQ5ZjExMjdiICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQtbHhkLnRhci54
        ego1NDljNmNhNmJmZGUzNjU1YTkzZjJmNTExODk1ZTIxOGQzZWRjYjA3NDYzOTQ2ZjhlNzBjYjJk
        M2Q0OWRkNTkwICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLXJvb3QudGFyLnh6
        CjU3NDY3YzcwZmU2M2UxM2RhOGMyNjFiNTAzZDQ1NTA5YmI4ZjU4OWQwMGQ1YjU1MTYxYzI3NjQ3
        NDEyNzJkOTAgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQubWFuaWZlc3QKNTlk
        M2I2ZmE2MmU5MGNlODg1MmFkYjIwZWYyYjkwNWQxYTFjNjU4MmE2NzliMTU0MWVlNTZmYTdjNmZh
        ZmJjNCAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1zMzkweC1yb290Lm1hbmlmZXN0CjU5
        ZDNiNmZhNjJlOTBjZTg4NTJhZGIyMGVmMmI5MDVkMWExYzY1ODJhNjc5YjE1NDFlZTU2ZmE3YzZm
        YWZiYzQgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctczM5MHguc3F1YXNoZnMubWFuaWZl
        c3QKNWRjMTc3MmE4ZjZmZjA2YTY2MzI5NWU0NGYxMDQxODljY2RiYjRjYTdiMWNiYWFhMzcyNjI3
        YWExMTE5ZjU0MiAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC1henVyZS52aGQu
        dGFyLmd6CjY3YzNlNDI4NGZjNTRhM2M4OTZlOGM2ZmFiN2ZmNjk5NGMwMWM4ODY2YjYyZWIwZjM1
        MWFkNzhlODk0ZjhlY2IgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC1yb290
        Lm1hbmlmZXN0CjY3YzNlNDI4NGZjNTRhM2M4OTZlOGM2ZmFiN2ZmNjk5NGMwMWM4ODY2YjYyZWIw
        ZjM1MWFkNzhlODk0ZjhlY2IgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5z
        cXVhc2hmcy5tYW5pZmVzdAo2ODI5MjkxYTc1ZTE4NDc4MTIyNGQ5OGRkNzFhN2QzM2Y0NGY5NTU1
        OGIwNDJiMDFiNmQ4NjQwYWQ3Yzg5NWZkICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXMz
        OTB4LWx4ZC50YXIueHoKNjhjYTgxODdjZjZkM2MxMWNlZGI5N2QwMjhmNTNiNDBiODU2Mjc4YmQ3
        NDhkMzBjOTkzZGUwNDQ5YzFjMGY0ZiAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1zMzkw
        eC5zcXVhc2hmcwo2ZDgyODA2Y2EzZjZhMDJlOGI1NWMxZDE3YTY1YjEwZjFhYzc2MDExNmZjNTA4
        OWM1MWM2ODU2Y2Y2MjhhM2M5ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0Lm92
        YQo2ZWExZWUzOTFlNTdlYTgyNzIzZjgxYjg3MDk2MzNkZTc4OGQ2M2JmMmYxOTgzZTFhNmZkYjg3
        ODZmYjBjNWY2ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0LWF6dXJlLnZoZC5t
        YW5pZmVzdAo2ZjYwMmRlNjdmMjk0NzdlNmVhMGUwYTk4Zjc5NzdlMzk5OTJjNmE5MWYwZGQ5OWRi
        YjhkYWYzYmNjMGZmYzNiICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQubWFu
        aWZlc3QKNzNjZWVjOGIxNWM0M2NhNWI3YzhmM2U3OGIxNDQ4YzNhOWFlOGRlMTRhMzUyOTE0ZTI2
        ZTljZWY4ZTg3YTkyMCAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm1oZi1seGQudGFy
        Lnh6Cjc2MWU1MTFkMDUyMzc2MTM3NzdmN2E1NGY3NzRhOWEwNzI5MjEwZTUwY2U3M2VkZTRhODE5
        ZDE4MmE4MmIxM2IgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC1yb290LnRh
        ci54ego3ZTVlMTYxYmM2MGJmYzEyYWQzOTMyMzIzOTJjY2Y1NzQ4NmU0YjlmOWRiYjYxYzY2OGEy
        ODU3YzQzMjRiOWQ2ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXMzOTB4LnRhci5nego4
        MTM4NmU3MmQwNTIzZmYwNmYzODk1OTE3ZWZkZjM3NDU0NjY5Y2VlMDYxOTA5ZWU4NDM4MDJlN2Zi
        MmFhOGU3ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0LnRhci5nego4NDcxMDEz
        MmYyNDA2NDA4YzQxNGNlZjYxNDg2ZWRlNjZhNzRiNzA0NzFiOTA4YjFjMDEwM2M2ODcwMTJiMGUw
        ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwucmVsZWFzZS4yMDI2MDcwNS4y
        MDI2MDcyNS5pbWFnZV9jaGFuZ2Vsb2cuanNvbgo4NTNjMDJmOWY0YWQ0NGM4MGViMTFjNGU5YWQx
        ZGZhMWVlOGVlM2EyNWRkZjhiNjNlZjUzM2JlZmZjNDI1MTNjICp1YnVudHUtMjQuMDQtc2VydmVy
        LWNsb3VkaW1nLWFybWhmLmRhaWx5LjIwMjYwNzA1LjIwMjYwNzI1LmltYWdlX2NoYW5nZWxvZy5q
        c29uCjg1OTYzODdkZDE0YzQ1MmM2MTg4NDViOWM1ZjkyODRjYzRlZTczYjgwMGEzYTNjYjU1NmZh
        N2RmZTEyYzM5NDEgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQudGFyLmd6Cjg3
        N2FmOGU5ZWFlYzkwZWM3YzRjYTE2NmRhMDA5MmJmOTlkZGJjODk4ODUwMDQ1MWM4ZWU0YjM3YTIx
        NjQ1N2MgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQtYXp1cmUudmhkLnRhci5n
        ego4ZTkyMDQ0YWVjNTc1N2RmMGU0OTVlMzk3NjRlYWY1ODViMTAyMWFiNzk2NGE2MWI3ZTYwNDdk
        NmFhNWRjYmQ3ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXMzOTB4LXJvb3QudGFyLnh6
        Cjk3MTgwN2VjZDRjYWM0NTZkMjZmOWJlMjEyNjljYzkxYjIzMGVmZmI2ZDk1ZGY3OWU5YWE4MGVm
        NjVkZmQzNzYgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5yZWxlYXNlLjIw
        MjYwNzA1LjIwMjYwNzI1LmltYWdlX2NoYW5nZWxvZy5qc29uCjk5ZDE1MzYwOGUyMWNiZTZlMDM3
        ZjFhM2EzYTE3NTYzMTdiM2EzMTMwMDhiNmY5MzI5MzJhYjU4M2VmODdlNjYgKnVidW50dS0yNC4w
        NC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQtYXp1cmUudmhkLm1hbmlmZXN0CmEyZWM2ODQ0NzFlMjM4
        NjIxMzEzY2MwZjY5YTFjYzE3ZDM3OTEyYjRmOGIzNDc1N2NkZGYyMmVjZTMyNjRmZTcgKnVidW50
        dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5zcXVhc2hmcwpiMGFjNDU1NDY3YjNlYTA0
        MTYyYTMzZWYwNTIxYWY2Y2Y4MzhmOWZjMmM4YTMxMTVkYzgxZGFhNmIxZWI2OTFjICp1YnVudHUt
        MjQuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0Lm1hbmlmZXN0CmI1N2RjODE4ZjMxYzFhMzFkOTkx
        Nzk0MTY4NjQ1NzM4MDVkYjIyNzZmM2Y0OGQwZGMwNjJkOWZlZDE2OTY2MGUgKnVidW50dS0yNC4w
        NC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQtbHhkLnRhci54egpiOWRjODU2NDU0MDMwNjhmODAxYWE5
        YjM4ZGEzNGY2Yzc5ODYxYTFlNzc0OWQzMTZmZGJiMjMyZTE0OWUwYmE5ICp1YnVudHUtMjQuMDQt
        c2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwuZGFpbHkuMjAyNjA3MDUuMjAyNjA3MjUuaW1hZ2VfY2hh
        bmdlbG9nLmpzb24KYmJhNzA3NjMyZWM4ZjQ4M2QxZWQwZjY2ZGQxY2MwZjE4ZmFiMmNhZTUxOWMz
        NGMwNTUyZWRjMDQxZjJlN2JjYyAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2NGVs
        Lm1hbmlmZXN0CmMwODM4MjRiYWEwOTU1NWI2Yjg0MWNkYmVhMDVkZGUzNmY2MmQyMDRlOWNhOGI2
        YjA4ZWNjZjdiODFiNDFlZjYgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC1s
        eGQudGFyLnh6CmM5YmJhNGM2ZTFmZTkzOWE3ODgxNGJhZTNjOWMzZmI0N2MzMTA4ZDVmNDhlYmFj
        ZWQ2MDM4NDY0MGE2NmViNDEgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtaGYudGFy
        Lmd6CmNhYzM5YmFlNTZhZTRlNWUxMGU4Yjk4MTc0ZmUxOTZhZjVmZTdiOTk4YTg0ZmIwNzg3NmNk
        NjBlNDUzMTlkODQgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtaGYucmVsZWFzZS4y
        MDI2MDcwNS4yMDI2MDcyNS5pbWFnZV9jaGFuZ2Vsb2cuanNvbgpjYmVkOTBjZDYzN2U5ZjI4Mjll
        NmY1NmRlOGZmOWI3MmFkZWYxZDVhZDczYWY4MjI4MDAxYzk1NjMwMDg2MGYxICp1YnVudHUtMjQu
        MDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLmltZwpkMTk0MGY3ZDY5ZDM0MzM1NWUxODNkZmYxZTA4
        YTU5ODUyZDMyZTczMDliYWE3YTRiYWQ4MzY1YjExYjAwNWFjICp1YnVudHUtMjQuMDQtc2VydmVy
        LWNsb3VkaW1nLWFtZDY0LmltZwpkODE2ZmMwYjk2YjZiNTEzMmNjZTEzYTg2NmJkOTI5MjBjMzk2
        ZTI0OWJkNmVkYmU5ODJkM2VjYzI1OGU5N2ZkICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1n
        LWFybTY0LnNxdWFzaGZzCmQ5MzI3MWY0ZTRmNGJiMGVhZmU3Mzc5NmM0MTVkYWI5YjEzYTI2YjYz
        NGY4N2M2YmU0NjQyZDg5YmQyNDIzNTggKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYW1k
        NjQtcm9vdC50YXIueHoKZGI4YTQ3OGUxZjc2MzY4MjIyZWY1MGI4NWZmNTg3ZmRlYWVkOTE2N2Y2
        ODI5OTY4ZjJmYTMyMmEzZDQzNDUyYiAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2
        NGVsLXJvb3QudGFyLnh6CmRjMWFkYjg1Y2NjOTZlNTJiZDlmNDdjMzU1NWU5ZDRkZDQzMGZhNjQ0
        MGY1MWY2MTUwMjFmYmY1MDdhNGI2ODUgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRpbWctYXJt
        aGYtcm9vdC5tYW5pZmVzdApkYzFhZGI4NWNjYzk2ZTUyYmQ5ZjQ3YzM1NTVlOWQ0ZGQ0MzBmYTY0
        NDBmNTFmNjE1MDIxZmJmNTA3YTRiNjg1ICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFy
        bWhmLnNxdWFzaGZzLm1hbmlmZXN0CmRlMzhjM2MzNjhlYzc3YTU5ZjZiYzU3ODA2NjE4NGM0ZmRk
        ZTUyMjhmNzZmODQwODRkNzE5MzEzY2M4ZDdkMjMgKnVidW50dS0yNC4wNC1zZXJ2ZXItY2xvdWRp
        bWctYW1kNjQuZGFpbHkuMjAyNjA3MDUuMjAyNjA3MjUuaW1hZ2VfY2hhbmdlbG9nLmpzb24KZGUz
        OGMzYzM2OGVjNzdhNTlmNmJjNTc4MDY2MTg0YzRmZGRlNTIyOGY3NmY4NDA4NGQ3MTkzMTNjYzhk
        N2QyMyAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC5kYWlseS4yMDI2MDcwNS4y
        MDI2MDcyNS5pbWFnZV9jaGFuZ2Vsb2cuanNvbgpkZjM4NWNjNWY0ZGU4MjUxZTMwNTQzOTNlNTE2
        ZWRjNjc5NGUzYzA2NDg5YmVjYTc2OGYzYzI5NmIxMTEyODllICp1YnVudHUtMjQuMDQtc2VydmVy
        LWNsb3VkaW1nLXMzOTB4LnJlbGVhc2UuMjAyNjA3MDUuMjAyNjA3MjUuaW1hZ2VfY2hhbmdlbG9n
        Lmpzb24KZTAxOTU2ZDUwMDQ0NDk4YzhlYTgzNTlhMjU3M2Y5ZGQ1NzE5YWViODZmODE2M2UxOWIx
        YTg5MTk2MWFmY2Y5ZiAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LnRhci5n
        egplNjc2ZGNiNDM0NWFlMThiZDU4OTJhMGY4Y2NlMWRkNmY5NzEyYmE5NzM1MjA1YjA0OGViNjk4
        MjIwZDc1NTlmICp1YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0LnZtZGsKZTc4NTUw
        NWNhMzRmNDdiMDVjNjlhM2M4OWFmMzU4NzRhOGM0MGQ3YTA0YTVlYzVlNzhjYzlmZmFhY2JmOWRk
        NiAqdWJ1bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnRhci5negplYzY4YjE5NDk2
        ZWFjNWExNDNiNDlmZTRmZTM4Y2E4YTYzOWMyZDEyYWNkYTNhOGUyMWRmOGJkZWU5MGZiMzIyICp1
        YnVudHUtMjQuMDQtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwuc3F1YXNoZnMKZWY0ZTliODk5YmRi
        ZWRiZmY1MTg3OGVlOGVlYjRjZTcwY2YyMWQyMDM3ZTExMGJiNDUzOWJhNDU4MTM3ZWM4MiAqdWJ1
        bnR1LTI0LjA0LXNlcnZlci1jbG91ZGltZy1zMzkweC5pbWcKZWZlMWQ1NGIyNTkxNDQ5MWY4NGEy
        ZmU4NWRiMzFhZTEyMmM4NGVlODcyNTI3MGM2MmE4MTMwZTEyODk1MDA0ZSAqdWJ1bnR1LTI0LjA0
        LXNlcnZlci1jbG91ZGltZy1hcm02NC1yb290Lm1hbmlmZXN0CmVmZTFkNTRiMjU5MTQ0OTFmODRh
        MmZlODVkYjMxYWUxMjJjODRlZTg3MjUyNzBjNjJhODEzMGUxMjg5NTAwNGUgKnVidW50dS0yNC4w
        NC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQuc3F1YXNoZnMubWFuaWZlc3QKZjBiOTZiOGE2NmNkNzYy
        MjNiYTZhZTgxMDkyMzNkN2QzYmQxNDEzOTJkMmIwNTAzY2I3NWI0ZjYzOTM1ODljZCAqdWJ1bnR1
        LTI0LjA0LXNlcnZlci1jbG91ZGltZy1hcm1oZi5zcXVhc2hmcwpmNGUxYjU4ZjBlZTEyYTQ2OTk4
        ZjIxNjE0YmY2YzYxNjhkMDVhN2JjOWJlNmQ1Y2RjYmNkYzA3ODJhMThkMTY1ICp1YnVudHUtMjQu
        MDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0LnNxdWFzaGZzCmY1OTFiZDYzZWY3MjgzMzI1NWM2MDQz
        YzI0NDEwOWNhN2I5NDg1OTcxMjc3NWNjZTE2YTE5N2I4OWI5NjBiZTggKnVidW50dS0yNC4wNC1z
        ZXJ2ZXItY2xvdWRpbWctczM5MHgubWFuaWZlc3QKZjg0ZWMzYjM0OTBhNTQ3ZTU5MDBmNmI2NjQ2
        M2JkNTFlNjc4MTA0MjQwNDUxNDFlNTBmODkxNDgxODc5OTQyMSAqdWJ1bnR1LTI0LjA0LXNlcnZl
        ci1jbG91ZGltZy1hbWQ2NC1seGQudGFyLnh6CmZjN2E0MmI2ZjYzNGEyN2Q3MmU1YzdmYjY4YmM5
        ZGE2ZWQ3ODE5NTAwNzhlZWM5NTY3NDNmODk0OGEwNTdhZTcgKnVidW50dS0yNC4wNC1zZXJ2ZXIt
        Y2xvdWRpbWctYW1kNjQtcm9vdC5tYW5pZmVzdApmYzdhNDJiNmY2MzRhMjdkNzJlNWM3ZmI2OGJj
        OWRhNmVkNzgxOTUwMDc4ZWVjOTU2NzQzZjg5NDhhMDU3YWU3ICp1YnVudHUtMjQuMDQtc2VydmVy
        LWNsb3VkaW1nLWFtZDY0LnNxdWFzaGZzLm1hbmlmZXN0Cg==
""".filter { !$0.isWhitespace })!

    /// The official detached `SHA256SUMS.gpg` for that file.
    private let ubuntuSignature = """
        -----BEGIN PGP SIGNATURE-----

        iQIzBAABCgAdFiEE0utEYm/dwwtRPVu3Gl1sTH24fIEFAmplOd8ACgkQGl1sTH24
        fIEEcg//Vfv84MjoK6U49Ahh2ekBHMOaLnCYzUls92aENPEWMOVbhQmwG2uIvZyk
        PVy54zby32j0BsbwU5Zn7RXlw35XZfgIuH7hx2WlemQjAwXpjO/QOl90wozcibK6
        bg7IRTqvnWy0reD8V1EdaLcabXDJSvGKuXBDuvyBYiS+UDaKGxy5C5aS1pHBMW1b
        pm5a173BuvuZqmNecQO2wklRGAyHHe7f5lqgdmxGxwnc8DhbWL160DL9p0rZeAAl
        pFXCEivPLaAuzrOUnU6hgGGpJldKVQHWDx5zWviT+jx5jHjRo806V+jIzKCWQ0Kn
        zOjOpq26nSMNQWbwrdyy3B/IWBdpcHcURAMh3n2/QL8yhB8ulvlpO7Qh4BuN5dY3
        1gg6GXW3PO7LlUq28xAIikTEcmSNm1AHktsrA5bQIk6+00s9Mkl70Wouq/KNufmE
        vQCrUzim+T3cMslWiCHcwH+JwDQcfrJyoQ2dzEiujGAbufL87QrtJ0uONJWqLRP5
        +d1xgMDbi5qhZsHhRZHpaBCN/lc8cXWR3S+Ay1qrg9RHzXlT9mVpbCp7Eja9UqkN
        GDhgRNMKEvcvcrFVam8yR6upSunu07F4/Fuqx9P8zEPVOYSbr26tJKjeITJ55Tgr
        /wxVhPjr/kHVnIhmEcYvnyjo64ZDt4xkYHICF2rywIVyNXm2oGM=
        =PCHg
        -----END PGP SIGNATURE-----
        """

    private func ubuntuKey() throws -> OpenPGPSignatureVerifier.PublicKey {
        try OpenPGPSignatureVerifier.publicKey(
            armored: TrustedSigningKeys.ubuntuPublicKey,
            pinnedFingerprint: TrustedSigningKeys.ubuntuFingerprint
        )
    }

    func testOfficialUbuntuChecksumSignatureVerifies() throws {
        let verified = try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: ubuntuSignature,
            over: ubuntuChecksumFile,
            using: try ubuntuKey()
        )
        XCTAssertEqual(verified.fingerprint, "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")
        XCTAssertEqual(verified.signatureVersion, 4)
        XCTAssertEqual(verified.hashAlgorithm, "SHA-512")
    }

    func testUbuntuSignedChecksumIsTheValuePinnedInTheCatalog() throws {
        try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: ubuntuSignature,
            over: ubuntuChecksumFile,
            using: try ubuntuKey()
        )
        let profile = LinuxGuestCatalog.ubuntu2404ARM64
        // Ubuntu lists many artifacts; find the one this profile downloads.
        let line = String(decoding: ubuntuChecksumFile, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasSuffix(" *ubuntu-24.04-server-cloudimg-arm64.img") }
        XCTAssertEqual(line?.split(separator: " ").first.map(String.init), profile.image.sha256)
    }

    func testUbuntuSignatureIsRejectedAgainstTheWrongDistributionKey() throws {
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: ubuntuSignature,
            over: ubuntuChecksumFile,
            using: try pinnedKey()
        )) { error in
            guard case .issuerMismatch = error as? OpenPGPSignatureVerifier.VerificationError else {
                return XCTFail("Expected the openSUSE key to be refused for an Ubuntu signature")
            }
        }
    }

    // MARK: - Fedora

    /// The official clearsigned Fedora 44 aarch64 `CHECKSUM` manifest.
    private let fedoraChecksumDocument = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        # Fedora-Cloud-Base-AmazonEC2-44-1.7.aarch64.raw.xz: 513786992 bytes
        SHA256 (Fedora-Cloud-Base-AmazonEC2-44-1.7.aarch64.raw.xz) = 090d3cb07b266535ff81603d12cd143626caedc51be46977fef5f9161d5117b3
        # Fedora-Cloud-Base-Azure-44-1.7.aarch64.vhdfixed.xz: 531866092 bytes
        SHA256 (Fedora-Cloud-Base-Azure-44-1.7.aarch64.vhdfixed.xz) = 758a871afbb37a78e4b675bd31d320661c8288081bffe5baaedc883705ec3fa8
        # Fedora-Cloud-Base-GCE-44-1.7.aarch64.tar.gz: 517158695 bytes
        SHA256 (Fedora-Cloud-Base-GCE-44-1.7.aarch64.tar.gz) = 527a326e2512a4ad55f3b580b9dfb3764248c72d4b756c8fea4f619562c67cce
        # Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2: 528154624 bytes
        SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = 55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b
        # Fedora-Cloud-Base-UEFI-UKI-44-1.7.aarch64.qcow2: 555810816 bytes
        SHA256 (Fedora-Cloud-Base-UEFI-UKI-44-1.7.aarch64.qcow2) = 809a34279fdce4ecbdfa9e7bebd27ee3d255cb90d6ad83e7fb15211634cf95f9
        # Fedora-Cloud-Base-Vagrant-libvirt-44-1.7.aarch64.vagrant.libvirt.box: 751600056 bytes
        SHA256 (Fedora-Cloud-Base-Vagrant-libvirt-44-1.7.aarch64.vagrant.libvirt.box) = 403b4b1de4bec1d730a08f035e5b79c3381ace8f22e59f1e29681e8a65844edf
        -----BEGIN PGP SIGNATURE-----

        iQIzBAEBCAAdFiEENvYS3PJ/fRpIqDXk2/z3HG2fkKYFAmnrjXoACgkQ2/z3HG2f
        kKaa4w/9ERR/1bjkpvSl2pzfbIQ6g98mTak1evpWaV6lN5c9+4/udWOpSShV+qZX
        Un+Uvl8O5lNiQG72Badz0wGU6h3BHrAnmsKbBcFG0xMxspmIJa8B+N0HS9ZeD4+T
        f0IftHwi+Vyj16U4nkUavNZQ1rs0qqB9ELnbqcmzJt+V30QO6R8NLXAIkboXC1lv
        xUibVal/Wwfv2ql40galLytuXmdHLIJ87I1oOb/t9i2bDm7D/u2zIJtApRxe9k+P
        YM0A1pguxQN9sIB+u6XWtoRRQGMPE4jougjUOdCoVFT0LjpTZ1Z+870YyJA8hnYa
        sUwCcsvf/zMcve5AEXtRrR4tvpZ7hUZ6TWhvbwRbV+CDdDuouvuustAsBZPUAlvd
        A7VhWFGKcu5QsRMH5eKnjktPXzKo6rHDjkg74KzgsE9O8KZODH0Pptfo+k0KrQO4
        FHT2AxhbJObxnnQPDTBynU6iBEkxFGL4CL+gEGgx+dMCJGXDTcdaPoESFLIMZBEl
        YHTeyBsCafRPfx9wA4P42b7TihSPjQ4yckNu98Mob1q4XfJsVOv5b1sDNkt2Xr+G
        chdL7xEohOMYOoQVfDWXYtcwh52zv/SxlVbqrepI2n+KBgBUfVO5I5oIHZCKNsBf
        sBxMKn9vqGxpZNU20HiYg1Yni3rK2wqJb3jUnI6WsZZb1Ap1Iho=
        =Me1A
        -----END PGP SIGNATURE-----
        """

    // MARK: - The returned message is the text that was verified

    /// Dash-escaping is not tampering: RFC 4880 §7.1 *requires* a line starting
    /// with "-" to be escaped, and requires the escape to be stripped before
    /// hashing. So this document must verify. What matters is that the message
    /// handed back is the text that was hashed, or a caller reading it gets
    /// bytes nobody signed.
    func testADashEscapedLineVerifiesAndIsReturnedUnescaped() throws {
        let prefix = "SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = "
        let target = prefix + LinuxGuestCatalog.fedora44ARM64.image.sha256
        let escaped = fedoraChecksumDocument.replacingOccurrences(of: target, with: "- " + target)
        XCTAssertNotEqual(escaped, fedoraChecksumDocument)

        let result = try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: escaped, using: try fedoraKey()
        )
        XCTAssertEqual(
            checksum(forPrefix: prefix, in: result.message),
            LinuxGuestCatalog.fedora44ARM64.image.sha256,
            "the returned message must be the dash-unescaped text that was hashed"
        )
    }

    /// Trailing whitespace is excluded from the hash precisely so transport can
    /// add or strip it. Returning the raw line put it back, so the value a
    /// caller extracted was not the value that was signed.
    func testTrailingWhitespaceIsStrippedFromTheReturnedMessage() throws {
        let prefix = "SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = "
        let target = prefix + LinuxGuestCatalog.fedora44ARM64.image.sha256
        let padded = fedoraChecksumDocument.replacingOccurrences(of: target, with: target + "   \t")
        XCTAssertNotEqual(padded, fedoraChecksumDocument)

        let result = try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: padded, using: try fedoraKey()
        )
        XCTAssertEqual(
            checksum(forPrefix: prefix, in: result.message),
            LinuxGuestCatalog.fedora44ARM64.image.sha256,
            "the returned message must carry no trailing whitespace the signature did not cover"
        )
    }

    /// The region between the header and the first blank line is unsigned. It
    /// must be armor headers and nothing else: skipping to the first blank line
    /// regardless of content let arbitrary unauthenticated text — including a
    /// plausible-looking checksum line — sit inside the signed-message section
    /// of a document that verifies.
    func testUnsignedTextInTheArmorHeaderRegionIsRejected() throws {
        let forged = fedoraChecksumDocument.replacingOccurrences(
            of: "Hash: SHA256\n",
            with: "Hash: SHA256\nSHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = "
                + String(repeating: "0", count: 64) + "\n"
        )
        XCTAssertNotEqual(forged, fedoraChecksumDocument)
        XCTAssertThrowsError(
            try OpenPGPSignatureVerifier.verifyClearsignedMessage(armored: forged, using: try fedoraKey())
        ) { XCTAssertEqual($0 as? OpenPGPSignatureVerifier.VerificationError, .malformedArmor) }
    }

    /// A packet length must never be able to end the process. `parseKeyPacket`
    /// is called through `try?`, and a `try?` cannot catch a Swift runtime trap:
    /// before the guard, a tag-6 body over 65535 bytes killed the process rather
    /// than skipping the key.
    func testAnOversizedKeyPacketThrowsRatherThanTrapping() throws {
        var body = Data([0x04])                                   // v4
        body.append(contentsOf: [0, 0, 0, 0])                     // creation time
        body.append(0x01)                                         // RSA
        body.append(contentsOf: [0x00, 0x08]); body.append(0xFF)  // modulus MPI
        body.append(contentsOf: [0x00, 0x02]); body.append(0x03)  // exponent MPI
        body.append(Data(repeating: 0x41, count: 70_000 - body.count))

        var blob = Data([UInt8(0x80 | (6 << 2) | 2)])             // old format, tag 6, 4-octet length
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(70_000).bigEndian, Array.init))
        blob.append(body)

        XCTAssertThrowsError(try OpenPGPSignatureVerifier.publicKey(
            binaryKeyring: blob,
            pinnedFingerprint: String(repeating: "0", count: 40)
        ))
    }

    /// A body one byte under the limit still parses, which is what shows the
    /// boundary is the two-octet fingerprint length and not the packet shape.
    func testAKeyPacketAtTheTwoOctetLimitStillParses() throws {
        var body = Data([0x04])
        body.append(contentsOf: [0, 0, 0, 0])
        body.append(0x01)
        body.append(contentsOf: [0x00, 0x08]); body.append(0xFF)
        body.append(contentsOf: [0x00, 0x02]); body.append(0x03)
        body.append(Data(repeating: 0x41, count: 65_535 - body.count))

        var blob = Data([UInt8(0x80 | (6 << 2) | 2)])
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(65_535).bigEndian, Array.init))
        blob.append(body)

        // Not the pinned fingerprint, so it is reported as a mismatch rather
        // than an unsupported length: the packet itself was parsed.
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.publicKey(
            binaryKeyring: blob,
            pinnedFingerprint: String(repeating: "0", count: 40)
        )) { error in
            guard case .fingerprintMismatch(_, let actual)? =
                error as? OpenPGPSignatureVerifier.VerificationError else {
                return XCTFail("expected a fingerprint mismatch, got \(error)")
            }
            XCTAssertFalse(actual.isEmpty, "the oversized-adjacent packet must still yield a fingerprint")
        }
    }

    private func checksum(forPrefix prefix: String, in message: String) -> String? {
        message.components(separatedBy: "\n")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func fedoraKey() throws -> OpenPGPSignatureVerifier.PublicKey {
        try OpenPGPSignatureVerifier.publicKey(
            binaryKeyring: Data(base64Encoded: TrustedSigningKeys.fedoraKeyringBase64
                .filter { !$0.isWhitespace })!,
            pinnedFingerprint: TrustedSigningKeys.fedora44Fingerprint
        )
    }

    /// Fedora ships several releases' keys in one file, so this proves the
    /// verifier selects by pinned fingerprint rather than taking the first key.
    func testFedoraKeyIsSelectedByFingerprintFromAMultiKeyKeyring() throws {
        let key = try fedoraKey()
        XCTAssertEqual(key.fingerprint, "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6")
        XCTAssertEqual(key.keyID, "DBFCF71C6D9F90A6")
    }

    func testOfficialFedoraClearsignedChecksumVerifies() throws {
        let result = try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: fedoraChecksumDocument,
            using: try fedoraKey()
        )
        XCTAssertEqual(result.signature.fingerprint, "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6")
        XCTAssertEqual(result.signature.signatureVersion, 4)
        XCTAssertEqual(result.signature.hashAlgorithm, "SHA-256")
        XCTAssertTrue(result.message.contains("SHA256 ("))
    }

    /// The checksum must be read from the verified message, never from the
    /// original document, and must be the value pinned in the catalog.
    func testFedoraSignedChecksumIsTheValuePinnedInTheCatalog() throws {
        let profile = LinuxGuestCatalog.fedora44ARM64
        let result = try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: fedoraChecksumDocument,
            using: try fedoraKey()
        )
        let line = result.message
            .split(separator: "\n")
            .first { $0.hasPrefix("SHA256 (\(profile.image.fileName)) = ") }
        XCTAssertEqual(
            line?.components(separatedBy: " = ").last,
            profile.image.sha256
        )
    }

    func testTamperedClearsignedMessageIsRejected() throws {
        let key = try fedoraKey()
        let profile = LinuxGuestCatalog.fedora44ARM64
        let tampered = fedoraChecksumDocument.replacingOccurrences(
            of: "SHA256 (\(profile.image.fileName)) = \(profile.image.sha256)",
            with: "SHA256 (\(profile.image.fileName)) = " + String(repeating: "0", count: 64)
        )
        XCTAssertNotEqual(tampered, fedoraChecksumDocument)
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: tampered,
            using: key
        )) { error in
            // Must fail verification, not parsing. A malformed-input error here
            // would mean the fixture never reached the signature check and the
            // test was passing for the wrong reason.
            let failure = error as? OpenPGPSignatureVerifier.VerificationError
            XCTAssertTrue(
                failure == .digestPrefixMismatch || failure == .signatureIsNotValid,
                "Expected a verification failure, received \(String(describing: failure))"
            )
        }
    }

    /// A clearsigned document carries a text-mode signature. Feeding its
    /// signature block to the detached path must fail rather than verify
    /// uncanonicalized bytes.
    func testClearsignedSignatureIsRefusedOnTheDetachedPath() throws {
        let key = try fedoraKey()
        let block = fedoraChecksumDocument.components(separatedBy: "-----BEGIN PGP SIGNATURE-----")
        let signatureBlock = "-----BEGIN PGP SIGNATURE-----" + block[1]
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyDetachedSignature(
            armored: signatureBlock,
            over: Data(fedoraChecksumDocument.utf8),
            using: key
        )) { error in
            XCTAssertEqual(
                error as? OpenPGPSignatureVerifier.VerificationError,
                .unsupportedSignatureType(1)
            )
        }
    }
}
