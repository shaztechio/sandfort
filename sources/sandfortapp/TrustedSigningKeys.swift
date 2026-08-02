import Foundation

/// SECURITY-CRITICAL DATA. Read `docs/security-model.md` before changing it.
///
/// Reviewed, version-controlled public keys for the distributions Sandfort
/// pins images from, together with their full fingerprints.
///
/// The fingerprint is the trust anchor, not the key block. `OpenPGPSignatureVerifier`
/// refuses to use a key whose fingerprint does not match the pinned value, so
/// replacing a block here without also replacing the fingerprint fails closed.
/// Never fetch these from a keyserver, a mirror, or any other runtime source:
/// a key fetched at the same time as the signature proves nothing about who
/// produced the artifact.
enum TrustedSigningKeys {
    /// openSUSE Project Signing Key <opensuse@opensuse.org>, RSA-4096.
    /// Published at
    /// `https://download.opensuse.org/distribution/leap/16.0/repo/oss/repodata/repomd.xml.key`
    /// and recorded in `docs/linux-profile-provenance.md`.
    static let openSUSEFingerprint = "AD48 5664 E901 B867 051A B15F 35A2 F86E 29B7 00A4"

    static let openSUSEPublicKey = """
        -----BEGIN PGP PUBLIC KEY BLOCK-----
        
        mQINBGKwfiIBEADe9bKROWax5CI83KUly/ZRDtiCbiSnvWfBK1deAttV+qLTZ006
        090eQCOlMtcjhNe641Ahi/SwMsBLNMNich7/ddgNDJ99H8Oen6mBze00Z0Nlg2HZ
        VZibSFRYvg+tdivu83a1A1Z5U10Fovwc2awCVWs3i6/XrpXiKZP5/Pi3RV2K7VcG
        rt+TUQ3ygiCh1FhKnBfIGS+UMhHwdLUAQ5cB+7eAgba5kSvlWKRymLzgAPVkB/NJ
        uqjz+yPZ9LtJZXHYrjq9yaEy0J80Mn9uTmVggZqdTPWx5CnIWv7Y3fnWbkL/uhTR
        uDmNfy7a0ULB3qjJXMAnjLE/Oi14UE28XfMtlEmEEeYhtlPlH7hvFDgirRHN6kss
        BvOpT+UikqFhJ+IsarAqnnrEbD2nO7Jnt6wnYf9QWPnl93h2e0/qi4JqT9zw93zs
        fDENY/yhTuqqvgN6dqaD2ABBNeQENII+VpqjzmnEl8TePPCOb+pELQ7uk6j4D0j7
        slQjdns/wUHg8bGE3uMFcZFkokPv6Cw6Aby1ijqBe+qYB9ay7nki44OoOsJvirxv
        p00MRgsm+C8he+B8QDZNBWYiPkhHZBFi5GQSUY04FimR2BpudV9rJqbKP0UezEpc
        m3tmqLuIc9YCxqMt40tbQOUVSrtFcYlltJ/yTVxu3plUpwtJGQavCJM7RQARAQAB
        tDRvcGVuU1VTRSBQcm9qZWN0IFNpZ25pbmcgS2V5IDxvcGVuc3VzZUBvcGVuc3Vz
        ZS5vcmc+iQJVBBMBCAA/AhsDBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgBYhBK1I
        VmTpAbhnBRqxXzWi+G4ptwCkBQJqF/o4BQkO7EoWAAoJEDWi+G4ptwCkD4EQAL7q
        mTQK6Am7lfb7e/WCjuyQEEh43y/S4WM4qwNgvpveUzuGcS+q78kLj3FzqEEH2MuL
        4cBN2tdNogXKzMKGUOqjw4vycinVwGRiR+a7guhUYS/syusLIgT+jTk9p4qMxW4D
        83iceavzisNO7Vp7kI0pbiTrrgc6IeVVMf1pJiGyQaXNGYGAUPMaEs5bgLFnQORR
        zP57IM6BkiL6zHv2wIV1RZPzzseWCOYPxRVYlAn8s0oZULWHAfTcOMWodf3mpgAa
        RuWX/UXbMgugtfpeWJpzrIiuO3EkDfbqEtPZBBQH27SZheSojqYdIeL2uJ/SqHZe
        enJ8YaO7KpKShGQuSpId8T5GTHx0BcFoctHGeZ8wSBFLO2i6Cf2fjsI3J8qY5k8V
        a2b1//Vz62GTbmppRrS3LBtEiMKOCeypQqiiFQzGEUvEPFgC9wzet1jVjzaW5Pa3
        mULzmfPPXcK0OtwYEZAvnwkI+ZurYEVA3zJo7sqDKlKfw/LszqwMVtFVUAKrm6I7
        NFHxxe2+4yNCbkhpCy4KbMoFS7x1mMB4myhSEMlWvzvAvwbIOeNHCmjI0BXcLrX3
        mCnZbC74F/HZnksj75wQp+McBnlxru/9EcqhA8ogZ45sizGyk5kQVOiaDE3O3IVC
        dATe9F7RaWn7JqQA74X+5COSw1GvShe2EmpO9J6p
        =is8v
        -----END PGP PUBLIC KEY BLOCK-----
"""
}
