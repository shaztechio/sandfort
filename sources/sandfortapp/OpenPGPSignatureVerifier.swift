import CryptoKit
import Foundation
import Security

/// SECURITY-CRITICAL CODE. Read `docs/security-model.md` before changing it.
///
/// This is a deliberately minimal OpenPGP detached-signature verifier for
/// distribution checksum files. It exists so profile intake can confirm that a
/// pinned image checksum is a value the distribution actually signed, without
/// shelling out to `gpg`, which the app is not allowed to depend on.
///
/// A verifier fails open when it is wrong: a parsing mistake turns "invalid
/// signature" into "accepted". Every change must preserve these rules.
///
/// - Parse defensively. Every read is bounds-checked and every length is
///   validated against the remaining buffer. Never trust a declared length.
/// - Accept only what is needed. Unknown packet versions, algorithms, signature
///   types, and partial or indeterminate packet lengths are rejected rather
///   than skipped or guessed.
/// - Never treat the stored left-16 digest bits as verification. They are a
///   corruption check only; the RSA verification below is the real gate.
/// - The trust anchor is the caller's pinned fingerprint, not the signature.
///   A signature verifies against a key; only a pinned fingerprint makes that
///   key the right one. Verifying against an unpinned key proves nothing.
enum OpenPGPSignatureVerifier {
    enum VerificationError: Error, Equatable {
        case malformedArmor
        case armorChecksumMismatch
        case malformedPacket
        case unsupportedPacketLength
        case unsupportedKeyVersion(Int)
        case unsupportedSignatureVersion(Int)
        case unsupportedPublicKeyAlgorithm(Int)
        case unsupportedHashAlgorithm(Int)
        case unsupportedSignatureType(Int)
        case fingerprintMismatch(expected: String, actual: String)
        case issuerMismatch(expected: String, actual: String)
        case digestPrefixMismatch
        case unusableKeyMaterial
        case signatureIsNotValid
    }

    /// A signing key parsed from a reviewed, version-controlled key block.
    struct PublicKey: Equatable {
        let fingerprint: String
        let keyID: String
        let modulus: Data
        let exponent: Data
    }

    /// Facts established by a successful verification, for provenance records.
    struct VerifiedSignature: Equatable {
        let keyID: String
        let fingerprint: String
        let signatureVersion: Int
        let hashAlgorithm: String
        let created: Date
    }

    /// Hash algorithms this verifier will accept. SHA-1 and MD5 are absent
    /// deliberately: both are unacceptable for signature verification.
    private enum HashAlgorithm: UInt8 {
        case sha256 = 8
        case sha384 = 9
        case sha512 = 10

        var name: String {
            switch self {
            case .sha256: return "SHA-256"
            case .sha384: return "SHA-384"
            case .sha512: return "SHA-512"
            }
        }

        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .sha256: return .rsaSignatureDigestPKCS1v15SHA256
            case .sha384: return .rsaSignatureDigestPKCS1v15SHA384
            case .sha512: return .rsaSignatureDigestPKCS1v15SHA512
            }
        }

        func digest(_ data: Data) -> Data {
            switch self {
            case .sha256: return Data(SHA256.hash(data: data))
            case .sha384: return Data(SHA384.hash(data: data))
            case .sha512: return Data(SHA512.hash(data: data))
            }
        }
    }

    // MARK: - Public entry points

    /// Parses a bundled public key block and requires it to match the pinned
    /// fingerprint. The fingerprint comparison is what makes the key trusted;
    /// it also detects an accidental or malicious edit of the embedded block.
    ///
    /// The v4 fingerprint is a SHA-1 digest because the OpenPGP format defines
    /// it that way. That is not a security choice here: the key material is
    /// bundled and reviewed rather than attacker-supplied, and the comparison is
    /// against a full pinned fingerprint, not a short key ID.
    static func publicKey(
        armored: String,
        pinnedFingerprint: String
    ) throws -> PublicKey {
        let packets = try packets(inArmored: armored)
        guard let keyPacket = packets.first(where: { $0.tag == 6 }) else {
            throw VerificationError.malformedPacket
        }
        let body = keyPacket.body
        var reader = ByteReader(body)
        let version = Int(try reader.byte())
        guard version == 4 else { throw VerificationError.unsupportedKeyVersion(version) }
        _ = try reader.bytes(4)                       // creation time
        let algorithm = Int(try reader.byte())
        // 1 = RSA (encrypt or sign), 3 = RSA sign-only.
        guard algorithm == 1 || algorithm == 3 else {
            throw VerificationError.unsupportedPublicKeyAlgorithm(algorithm)
        }
        let modulus = try reader.multiprecisionInteger()
        let exponent = try reader.multiprecisionInteger()

        var fingerprintInput = Data([0x99])
        fingerprintInput.append(contentsOf: withUnsafeBytes(of: UInt16(body.count).bigEndian, Array.init))
        fingerprintInput.append(body)
        let fingerprint = Data(Insecure.SHA1.hash(data: fingerprintInput)).hexadecimalString

        let expected = normalizedFingerprint(pinnedFingerprint)
        guard constantTimeEquals(fingerprint, expected) else {
            throw VerificationError.fingerprintMismatch(expected: expected, actual: fingerprint)
        }
        return PublicKey(
            fingerprint: fingerprint,
            keyID: String(fingerprint.suffix(16)),
            modulus: modulus,
            exponent: exponent
        )
    }

    /// Verifies a detached binary-document signature over `payload`.
    @discardableResult
    static func verifyDetachedSignature(
        armored: String,
        over payload: Data,
        using key: PublicKey
    ) throws -> VerifiedSignature {
        let packets = try packets(inArmored: armored)
        guard let packet = packets.first(where: { $0.tag == 2 }) else {
            throw VerificationError.malformedPacket
        }
        let body = packet.body
        var reader = ByteReader(body)
        let version = Int(try reader.byte())
        switch version {
        case 3: return try verifyVersion3(body: body, reader: &reader, payload: payload, key: key)
        case 4: return try verifyVersion4(body: body, reader: &reader, payload: payload, key: key)
        default: throw VerificationError.unsupportedSignatureVersion(version)
        }
    }

    // MARK: - Signature versions

    private static func verifyVersion3(
        body: Data,
        reader: inout ByteReader,
        payload: Data,
        key: PublicKey
    ) throws -> VerifiedSignature {
        // A v3 signature's hashed material is exactly five bytes: the signature
        // type and the four-byte creation time. Anything else is malformed.
        guard try reader.byte() == 5 else { throw VerificationError.malformedPacket }
        let signatureType = try reader.byte()
        try requireBinaryDocument(signatureType)
        let creationBytes = try reader.bytes(4)
        let issuer = try reader.bytes(8).hexadecimalString
        let publicKeyAlgorithm = Int(try reader.byte())
        try requireRSA(publicKeyAlgorithm)
        let hashAlgorithm = try requireSupportedHash(try reader.byte())
        let storedPrefix = try reader.bytes(2)
        let signature = try reader.multiprecisionInteger()

        guard constantTimeEquals(issuer, key.keyID) else {
            throw VerificationError.issuerMismatch(expected: key.keyID, actual: issuer)
        }

        var signedData = payload
        signedData.append(signatureType)
        signedData.append(creationBytes)
        let digest = hashAlgorithm.digest(signedData)

        try verify(
            digest: digest,
            storedPrefix: storedPrefix,
            signature: signature,
            hashAlgorithm: hashAlgorithm,
            key: key
        )
        return VerifiedSignature(
            keyID: key.keyID,
            fingerprint: key.fingerprint,
            signatureVersion: 3,
            hashAlgorithm: hashAlgorithm.name,
            created: Date(timeIntervalSince1970: TimeInterval(creationBytes.bigEndianUInt32))
        )
    }

    private static func verifyVersion4(
        body: Data,
        reader: inout ByteReader,
        payload: Data,
        key: PublicKey
    ) throws -> VerifiedSignature {
        let signatureType = try reader.byte()
        try requireBinaryDocument(signatureType)
        let publicKeyAlgorithm = Int(try reader.byte())
        try requireRSA(publicKeyAlgorithm)
        let hashAlgorithm = try requireSupportedHash(try reader.byte())
        let hashedLength = Int(try reader.bytes(2).bigEndianUInt16)
        let hashedSubpackets = try reader.bytes(hashedLength)
        let unhashedLength = Int(try reader.bytes(2).bigEndianUInt16)
        let unhashedSubpackets = try reader.bytes(unhashedLength)
        let storedPrefix = try reader.bytes(2)
        let signature = try reader.multiprecisionInteger()

        // The issuer may appear in either area. Only the hashed area is covered
        // by the signature, so an unhashed issuer is a hint, never a guarantee;
        // the RSA verification against the pinned key is what actually binds.
        let issuer = issuerKeyID(inSubpackets: hashedSubpackets)
            ?? issuerKeyID(inSubpackets: unhashedSubpackets)
        if let issuer, !constantTimeEquals(issuer, key.keyID) {
            throw VerificationError.issuerMismatch(expected: key.keyID, actual: issuer)
        }

        // A v4 signature hashes the payload, then its own leading bytes through
        // the hashed subpacket area, then a trailer covering that area's length.
        let hashedArea = body.prefix(6 + hashedLength)
        guard hashedArea.count == 6 + hashedLength else { throw VerificationError.malformedPacket }
        var signedData = payload
        signedData.append(hashedArea)
        signedData.append(contentsOf: [0x04, 0xFF])
        signedData.append(contentsOf: withUnsafeBytes(of: UInt32(hashedArea.count).bigEndian, Array.init))
        let digest = hashAlgorithm.digest(signedData)

        try verify(
            digest: digest,
            storedPrefix: storedPrefix,
            signature: signature,
            hashAlgorithm: hashAlgorithm,
            key: key
        )
        return VerifiedSignature(
            keyID: key.keyID,
            fingerprint: key.fingerprint,
            signatureVersion: 4,
            hashAlgorithm: hashAlgorithm.name,
            created: signatureCreationDate(inSubpackets: hashedSubpackets) ?? Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Verification

    private static func verify(
        digest: Data,
        storedPrefix: Data,
        signature: Data,
        hashAlgorithm: HashAlgorithm,
        key: PublicKey
    ) throws {
        // The stored prefix only catches corruption early. It is never proof.
        guard digest.prefix(2) == storedPrefix else {
            throw VerificationError.digestPrefixMismatch
        }
        guard let secKey = makeSecKey(modulus: key.modulus, exponent: key.exponent) else {
            throw VerificationError.unusableKeyMaterial
        }
        // OpenPGP strips leading zero bytes from the signature MPI; the platform
        // verifier requires a value the exact width of the modulus.
        var padded = signature
        guard padded.count <= key.modulus.count else { throw VerificationError.malformedPacket }
        if padded.count < key.modulus.count {
            padded = Data(repeating: 0, count: key.modulus.count - padded.count) + padded
        }
        guard SecKeyVerifySignature(
            secKey,
            hashAlgorithm.secKeyAlgorithm,
            digest as CFData,
            padded as CFData,
            nil
        ) else {
            throw VerificationError.signatureIsNotValid
        }
    }

    private static func makeSecKey(modulus: Data, exponent: Data) -> SecKey? {
        let der = derSequence([derInteger(modulus), derInteger(exponent)])
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    // MARK: - Requirements

    private static func requireBinaryDocument(_ type: UInt8) throws {
        // 0x00 is a signature over binary data. Text-mode signatures (0x01)
        // require line-ending canonicalization that this verifier does not do,
        // so accepting them would verify the wrong bytes.
        guard type == 0x00 else { throw VerificationError.unsupportedSignatureType(Int(type)) }
    }

    private static func requireRSA(_ algorithm: Int) throws {
        guard algorithm == 1 || algorithm == 3 else {
            throw VerificationError.unsupportedPublicKeyAlgorithm(algorithm)
        }
    }

    private static func requireSupportedHash(_ raw: UInt8) throws -> HashAlgorithm {
        guard let algorithm = HashAlgorithm(rawValue: raw) else {
            throw VerificationError.unsupportedHashAlgorithm(Int(raw))
        }
        return algorithm
    }

    // MARK: - Subpackets

    private static func subpackets(_ data: Data) -> [(type: UInt8, body: Data)] {
        var reader = ByteReader(data)
        var found: [(UInt8, Data)] = []
        while reader.remaining > 0 {
            guard let first = try? reader.byte() else { return found }
            var length = 0
            switch first {
            case 0..<192:
                length = Int(first)
            case 192..<255:
                guard let second = try? reader.byte() else { return found }
                length = ((Int(first) - 192) << 8) + Int(second) + 192
            default:
                guard let raw = try? reader.bytes(4) else { return found }
                length = Int(raw.bigEndianUInt32)
            }
            guard length >= 1, let body = try? reader.bytes(length) else { return found }
            found.append((body[body.startIndex], body.dropFirst()))
        }
        return found
    }

    private static func issuerKeyID(inSubpackets data: Data) -> String? {
        for packet in subpackets(data) {
            if packet.type == 16, packet.body.count == 8 {
                return packet.body.hexadecimalString
            }
            // Issuer fingerprint: version byte followed by the fingerprint.
            if packet.type == 33, packet.body.count == 21 {
                return String(packet.body.dropFirst().hexadecimalString.suffix(16))
            }
        }
        return nil
    }

    private static func signatureCreationDate(inSubpackets data: Data) -> Date? {
        for packet in subpackets(data) where packet.type == 2 && packet.body.count == 4 {
            return Date(timeIntervalSince1970: TimeInterval(packet.body.bigEndianUInt32))
        }
        return nil
    }

    // MARK: - Armor and packets

    private struct Packet {
        let tag: Int
        let body: Data
    }

    private static func packets(inArmored armored: String) throws -> [Packet] {
        try parsePackets(try decodeArmor(armored))
    }

    /// Decodes Radix-64 armor and validates its CRC-24 checksum.
    private static func decodeArmor(_ armored: String) throws -> Data {
        let lines = armored.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP") }),
              let end = lines.firstIndex(where: { $0.hasPrefix("-----END PGP") }),
              begin < end
        else { throw VerificationError.malformedArmor }

        var payload = ""
        var declaredChecksum: String?
        var inHeaders = true
        for line in lines[(begin + 1)..<end] {
            if inHeaders {
                // Armor headers run until the first blank line.
                if line.isEmpty { inHeaders = false; continue }
                if line.contains(": ") { continue }
                inHeaders = false
            }
            if line.isEmpty { continue }
            if line.hasPrefix("=") {
                declaredChecksum = String(line.dropFirst())
                continue
            }
            payload += line
        }
        guard let data = Data(base64Encoded: payload), !data.isEmpty else {
            throw VerificationError.malformedArmor
        }
        // The checksum is optional in current OpenPGP, but when it is present a
        // mismatch means the block was damaged or altered in transit.
        if let declaredChecksum {
            guard let expected = Data(base64Encoded: declaredChecksum), expected.count == 3 else {
                throw VerificationError.malformedArmor
            }
            guard expected.bigEndianUInt24 == crc24(data) else {
                throw VerificationError.armorChecksumMismatch
            }
        }
        return data
    }

    private static func parsePackets(_ data: Data) throws -> [Packet] {
        var reader = ByteReader(data)
        var packets: [Packet] = []
        while reader.remaining > 0 {
            let header = try reader.byte()
            guard header & 0x80 != 0 else { throw VerificationError.malformedPacket }
            let tag: Int
            let length: Int
            if header & 0x40 != 0 {
                tag = Int(header & 0x3F)
                let first = try reader.byte()
                switch first {
                case 0..<192:
                    length = Int(first)
                case 192..<224:
                    length = ((Int(first) - 192) << 8) + Int(try reader.byte()) + 192
                case 255:
                    length = Int(try reader.bytes(4).bigEndianUInt32)
                default:
                    // Partial body lengths are not needed here and are a common
                    // source of parser confusion, so they are refused.
                    throw VerificationError.unsupportedPacketLength
                }
            } else {
                tag = Int((header >> 2) & 0x0F)
                switch header & 0x03 {
                case 0: length = Int(try reader.byte())
                case 1: length = Int(try reader.bytes(2).bigEndianUInt16)
                case 2: length = Int(try reader.bytes(4).bigEndianUInt32)
                default: throw VerificationError.unsupportedPacketLength
                }
            }
            packets.append(Packet(tag: tag, body: try reader.bytes(length)))
        }
        guard !packets.isEmpty else { throw VerificationError.malformedPacket }
        return packets
    }

    private static func crc24(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in data {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864CFB }
            }
        }
        return crc & 0xFFFFFF
    }

    // MARK: - Helpers

    private static func normalizedFingerprint(_ value: String) -> String {
        value.filter { !$0.isWhitespace }.uppercased()
    }

    /// Length-independent comparison. These values are public, so this is
    /// defensive hygiene rather than a defense against a practical attack.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func derInteger(_ value: Data) -> Data {
        var content = Data(value.drop { $0 == 0 })
        if content.isEmpty { content = Data([0]) }
        // DER integers are signed, so a leading high bit needs a zero pad.
        if let first = content.first, first & 0x80 != 0 { content = Data([0]) + content }
        return Data([0x02]) + derLength(content.count) + content
    }

    private static func derSequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data(), +)
        return Data([0x30]) + derLength(content.count) + content
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes = Data()
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: bytes.startIndex)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }

    /// Bounds-checked cursor. Every read either succeeds within the buffer or
    /// throws; no read is allowed to run past the declared data.
    private struct ByteReader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = Data(data)
            self.offset = 0
        }

        var remaining: Int { data.count - offset }

        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw VerificationError.malformedPacket }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw VerificationError.malformedPacket }
            let start = data.startIndex + offset
            defer { offset += count }
            return data[start..<(start + count)]
        }

        mutating func multiprecisionInteger() throws -> Data {
            let bits = Int(try bytes(2).bigEndianUInt16)
            return try bytes((bits + 7) / 8)
        }
    }
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    var bigEndianUInt16: UInt16 {
        reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    var bigEndianUInt24: UInt32 {
        reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    var bigEndianUInt32: UInt32 {
        reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
