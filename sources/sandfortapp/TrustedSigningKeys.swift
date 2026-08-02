// Copyright 2026 Sandfort contributors
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

    /// UEC Image Automatic Signing Key <cdimage@ubuntu.com>, RSA-4096.
    /// Signs `SHA256SUMS` for Ubuntu cloud images. Retrieved from Canonical's
    /// keyserver by full fingerprint; the pin below, not the retrieval, is what
    /// makes it trusted.
    static let ubuntuFingerprint = "D2EB 4462 6FDD C30B 513D 5BB7 1A5D 6C4C 7DB8 7C81"

    static let ubuntuPublicKey = """
        -----BEGIN PGP PUBLIC KEY BLOCK-----
        Comment: Hostname:
        Version: Hockeypuck 2.2

        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
        l1LWUW7hwHbO2OE=
        =scXX
        -----END PGP PUBLIC KEY BLOCK-----
"""

    /// Fedora (44) <fedora-44-primary@fedoraproject.org>, RSA-4096.
    ///
    /// Fedora publishes one binary keyring holding several releases' keys, so
    /// this is the exact published `fedora.gpg` from
    /// `https://fedoraproject.org/fedora.gpg`, base64-encoded for embedding and
    /// otherwise unaltered. The verifier selects the Fedora 44 key from it by
    /// the pinned fingerprint; it never takes whichever key happens to be first.
    static let fedora44Fingerprint = "36F6 12DC F27F 7D1A 48A8 35E4 DBFC F71C 6D9F 90A6"

    static let fedoraKeyringBase64 = """
        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
        6aMFGH0QWj/LnGHC72ZWAImYsItb8HIRgkQ=
"""
}
