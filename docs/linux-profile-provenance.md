# Linux profile provenance

Catalog image metadata is reviewed and version-controlled. Runtime downloads
must use the exact profile URL and pass the pinned SHA-256 before Sandfort opens
or modifies the image. A new image or provisioning policy receives a new profile
revision; an existing revision is never retargeted.

All four profiles were revised on 2026-08-02 to mask `getty@tty1.service`, which
otherwise showed a console login prompt before the graphical greeter. That took
Ubuntu to revision 2, Fedora to revision 2, Debian to revision 4, and openSUSE to
revision 3. Every pinned image and checksum is unchanged; only guest provisioning
moved. Baselines built from any earlier revision are intentionally incompatible
and must be rebuilt, including pre-revision Ubuntu state, which no longer
resolves to any current profile.

All four revisions were confirmed on real UTM boots on 2026-08-02. The graphical
greeter is the only login presented, and a text console remains reachable for
diagnostics.

All four were revised again on 2026-08-03, taking Ubuntu to revision 3, Fedora
to revision 3, Debian to revision 5, and openSUSE to revision 4. openSUSE gains
GNOME Terminal, since its GNOME pattern ships no terminal emulator any more than
it shipped a browser; every profile gains an optional Visual Studio Code, on by
default, installed from Microsoft's checksum-verified arm64 tarball rather than
their package repository; and every profile now verifies that a terminal and a
browser actually exist, which closes the gap recorded in `AGENTS.md`. Pinned
images and checksums are unchanged.

A further revision on 2026-08-03 takes Ubuntu to 4, Fedora to 4, Debian to 6,
and openSUSE to 5, fixing a VS Code that would not launch. Electron's
`chrome-sandbox` helper ships setuid but owned by Microsoft's build user, so the
bit is meaningless once extracted, and Chromium falls back to unprivileged user
namespaces. Ubuntu 24.04 restricts those through AppArmor, so the editor died
during launch showing only a spinner; the other profiles were at risk for the
same reason. The helper is now owned by root and verified setuid, and the
desktop entry launches the GUI binary rather than the command line wrapper.
`--no-sandbox` was deliberately not used: it would disable Electron's sandbox
inside a tool meant to contain untrusted code.

Ubuntu revision 4 was verified in UTM by the maintainer on 2026-08-03, including
that Visual Studio Code launches. Its checks are recorded in
`ubuntu-qualification.md`. Fedora revision 4 was verified by the maintainer on
2026-08-03, including Visual Studio Code launching under SELinux enforcing,
which the Fedora provisioner verifies during setup. That retires the same
concern for openSUSE, which has the same SELinux posture. Debian and openSUSE are still unconfirmed.

Debian revision 7 removes a two-minute boot delay found while qualifying revision
6. `systemd-analyze blame` inside an offline clean instance showed
`systemd-networkd-wait-online.service` taking 2min 0.08s and blocking
`cloud-init-network`, and through it every later target, so the greeter did not
appear for over two minutes. Debian's cloud image runs systemd-networkd beside
the NetworkManager this profile installs: NetworkManager settles in 185ms and
networkd, managing nothing, waits out its full timeout. Both wait-online units
are now masked, as Ubuntu has always done. Fedora and openSUSE do not install
systemd-networkd, so neither is affected and neither is revised.

The delay predates the console-login change but was invisible: masking the VT1
getty replaced a login prompt with a bare cursor, so a slow boot began to look
like a hang.

## openSUSE Leap 16.0 ARM64

Status: qualified and selectable in the production catalog.

- Profile: `opensuse-leap-16.0-arm64`, revision 5
- Artifact: `Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2`
- Official immutable URL:
  `https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2`
- Official SHA-256 file:
  `https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2.sha256`
- Official detached checksum signature:
  `https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2.sha256.asc`
- Published and pinned SHA-256:
  `2e9eeb56e7523775f1f01261f4900f289e20c38910226b0c1e5aa7228a84194a`
- Artifact size: 318,963,712 bytes
- openSUSE Project Signing Key fingerprint:
  `AD48 5664 E901 B867 051A B15F 35A2 F86E 29B7 00A4`
- Intake date: 2026-08-02
- Signature verification date: 2026-08-02

During intake, the exact cloud image, published checksum, detached signature,
and official CycloneDX SBOM were obtained from openSUSE's versioned Leap 16.0
appliance directory. The downloaded artifact independently matched the
published SHA-256 and passed Sandfort's native QCOW2 geometry validation. The
SBOM confirms that the base image contains cloud-init, NetworkManager, SELinux
policy and tools, OpenSSH, and qemu-guest-agent. Leap's official repository
metadata was also checked for every package name encoded by the provisioner.

The detached OpenPGP signature over the published `.sha256` file was
cryptographically verified without the `gpg` tool, using Sandfort's own
`OpenPGPSignatureVerifier` (security-critical code; see `security-model.md`).
`OpenPGPSignatureVerifierTests` reproduces this verification on every `make
test` run and asserts that the signed checksum still equals the value pinned in
the catalog. The signature is a version 3
RSA packet over SHA-512, issued by key ID `35A2F86E29B700A4`. That key ID
matches the openSUSE Project Signing Key published at
`https://download.opensuse.org/distribution/leap/16.0/repo/oss/repodata/repomd.xml.key`,
whose full fingerprint is recorded above. RSA PKCS#1 v1.5 recovery over the
4096-bit modulus reproduced the exact EMSA padding and SHA-512 DigestInfo, and
the signed checksum is byte-identical to the SHA-256 pinned in this catalog. The
signature therefore covers the exact artifact Sandfort downloads, and the pinned
hash is a value openSUSE actually signed rather than only a value observed at a
URL.

`OpenSUSECloudInit.swift` installs GNOME/GDM, Firefox, selected development
tools, NetworkManager, qemu/SPICE guest agents, firewalld, and an app-owned
daily security-patch timer through Zypper. It disables and masks SSH, requires
SELinux enforcing mode, installs a MAC-independent DHCP connection for
disposable instances, configures an empty DROP-target firewall zone, verifies
every requirement, and powers off only after writing Sandfort's completion
marker. Revision 3 passed the real-UTM matrix in `opensuse-qualification.md` on
2026-08-02 and was promoted to the production catalog.

Revision 2 adds the browser. Unlike Ubuntu's `ubuntu-desktop-minimal`, Fedora's
`workstation-product-environment`, and Debian's `task-gnome-desktop`, Leap's
`patterns-gnome-gnome` requires only `gnome-session-wayland` and declares no
recommends, so revision 1 produced a desktop with no way to browse the web.
Leap 16 keeps browsers in `patterns-gnome-gnome_internet`, whose recommends
also include Evolution, Polari, Transmission, and VPN plugins that a disposable
sandbox must not ship. Revision 2 therefore installs `MozillaFirefox` (140 ESR,
aarch64, `/usr/bin/firefox`) explicitly and pins
`MozillaFirefox-branding-openSUSE`, because two packages provide the required
`MozillaFirefox-branding` capability and the unattended solver must not be left
to choose between them. Both are verified during setup.

Revision 3 masks `getty@tty1.service`. Instances are built with a display and
no serial device, so the VT1 getty parked a text `sandfort login:` prompt on the
framebuffer from multi-user.target until GDM started, which reads as though the
sandbox must be used from a command line. Masking that one unit leaves VT1 free
for the greeter. It deliberately does not mask the `getty@` or `autovt@`
templates, so logind still spawns a console on demand and Ctrl+Alt+F2 remains a
rescue path if the desktop fails. Baseline setup is unaffected: the setup VM has
a serial device and no display, and its failure path still uses
`serial-getty@ttyAMA0`.

## Ubuntu 24.04 LTS ARM64

Status: qualified and selectable in the production catalog. Default profile.

- Profile: `ubuntu-24.04-arm64`, revision 4
- Artifact: `ubuntu-24.04-server-cloudimg-arm64.img`
- Official immutable URL:
  `https://cloud-images.ubuntu.com/releases/noble/release-20260725/ubuntu-24.04-server-cloudimg-arm64.img`
- Official checksum manifest:
  `https://cloud-images.ubuntu.com/releases/noble/release-20260725/SHA256SUMS`
- Official detached manifest signature:
  `https://cloud-images.ubuntu.com/releases/noble/release-20260725/SHA256SUMS.gpg`
- Published and pinned SHA-256:
  `2eaec7286c49fdea713dddabcf5012cafa7097a658e916acb48f4bc5fdc8e419`
- UEC Image Automatic Signing Key fingerprint:
  `D2EB 4462 6FDD C30B 513D 5BB7 1A5D 6C4C 7DB8 7C81`
- Signature verification date: 2026-08-02

The detached signature over `SHA256SUMS` was verified with Sandfort's own
`OpenPGPSignatureVerifier`. It is a version 4 RSA packet over SHA-512 from the
UEC Image Automatic Signing Key `<cdimage@ubuntu.com>`, whose fingerprint is
pinned in `TrustedSigningKeys.swift`. The signed manifest lists many artifacts;
the line for `ubuntu-24.04-server-cloudimg-arm64.img` carries the exact SHA-256
pinned in this catalog, and a test asserts that equality on every `make test`.

Canonical does not publish this key alongside the images, so it was retrieved
from Canonical's keyserver by full fingerprint and then reviewed and bundled.
The pin, not the retrieval, is what makes it trusted.

## Debian 13 (Trixie) ARM64

Status: qualified and selectable in the production catalog.

- Profile: `debian-13-arm64`, revision 7
- Artifact: `debian-13-generic-arm64-20260712-2537.qcow2`
- Official immutable URL:
  `https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-generic-arm64-20260712-2537.qcow2`
- Official SHA-512 manifest:
  `https://cloud.debian.org/images/cloud/trixie/20260712-2537/SHA512SUMS`
- Published SHA-512:
  `3be884e19878b307a5916eb59be17efb7f1a5ec8290f2253345640f0a8740082fd40cfb7a7940b56cca0a76289ecd448507011cfd1b17472c9998d90f44b5c2c`
- Derived and pinned SHA-256:
  `7e556159a995fa4634e2ea52228ec7a4226193e2d1a87e2c7158e4c6d53ed5fe`
- Artifact size: 431,882,240 bytes
- Intake date: 2026-08-02

During intake, the exact image and SHA-512 manifest were downloaded from
Debian's immutable dated directory. The artifact matched Debian's published
SHA-512, and its SHA-256 was independently derived before being pinned in the
catalog. Debian does not publish a detached signature alongside this cloud
manifest, so provenance relies on the immutable official HTTPS location and
the reviewed hash recorded here. Replacing the artifact or URL requires a new
profile revision.

The Debian provisioner installs Debian's GNOME task, GDM, NetworkManager,
qemu/SPICE guest agents, selected development tools, AppArmor, UFW, and
unattended upgrades. It disables and masks SSH, verifies the security policy,
and powers off only after writing Sandfort's completion marker. It replaces the
first-boot ENI file with a NetworkManager DHCP profile that has no interface or
MAC-address match. It also disables cloud-init network regeneration and removes
the image's saved Netplan YAML. This prevents Netplan from generating a runtime
udev deny-list that marks UTM's `enp0s1` adapter unmanaged. Network-manager
ownership and wait-online behavior remain explicit items in the real UTM
qualification matrix.

Qualification revision 1 used Debian's first-boot ENI configuration and was not
promoted. A real clean instance with a newly generated MAC address failed to
obtain Internet access. Revision 2 deliberately makes that baseline
incompatible and adds the MAC-independent NetworkManager profile described
above. A real UTM boot then exposed a second image-specific issue: Netplan's
generated `/run/udev/rules.d/90-netplan.rules` matched UTM's `enp0s1` PCI layout
and overrode NetworkManager with `NM_UNMANAGED=1`. Revision 3 removes the stale
Netplan input and disables cloud-init network regeneration, requiring another
Debian qualification rebuild.

## Fedora Cloud 44 ARM64

Status: qualified and selectable in the production catalog.

- Profile: `fedora-44-arm64`, revision 4
- Artifact: `Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2`
- Official versioned URL:
  `https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2`
- Official checksum manifest:
  `https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-44-1.7-aarch64-CHECKSUM`
- Published and pinned SHA-256:
  `55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b`
- Artifact size: 528,154,624 bytes
- Fedora 44 signing certificate fingerprint:
  `36F6 12DC F27F 7D1A 48A8 35E4 DBFC F71C 6D9F 90A6`
- Intake date: 2026-08-02

During intake, the exact artifact and clear-signed checksum manifest were
downloaded from Fedora's versioned release path. The manifest's SHA-256 matched
Fedora's official Cloud download page, and the downloaded artifact independently
matched that SHA-256 using both `shasum` and Sandfort's native hashing code. The
manifest's OpenPGP signature was cryptographically verified against Fedora 44
certificate `36F6 12DC F27F 7D1A 48A8 35E4 DBFC F71C 6D9F 90A6`, downloaded
from Fedora's official certificate bundle. That fingerprint independently
matched Fedora's current security page.

That signature has since been re-verified with Sandfort's own
`OpenPGPSignatureVerifier` rather than `gpg`. The Fedora manifest is
clearsigned, not detached: it carries a version 4 RSA text-mode signature over
SHA-256, so the verifier canonicalizes the message first, removing dash-escaping
and trailing whitespace and joining lines with CRLF. Fedora publishes one binary
keyring holding several releases' keys, so the Fedora 44 key is selected from it
by pinned fingerprint rather than by position. Checksums are read from the
verified message, never from the original document, because only the
canonicalized text is signed.

The separate Fedora provisioner now installs Fedora's exact
`workstation-product-environment` through DNF5, selected development tools,
GDM, NetworkManager, qemu/SPICE guest agents, firewalld, and DNF5 automatic
updates. It disables SSH, requires SELinux enforcing mode, configures an empty
DROP-target firewall zone, applies security-only automatic updates without
rebooting, verifies the policy, and powers off only after writing Sandfort's
completion marker. Automated policy tests cover these requirements.

Phase 5 was exercised by the user through the isolated real-UTM build and
approved for promotion on 2026-08-02. Qualification exposed an instance-deletion
registration defect; the native UTM unregister-and-confirm path was added and
the user confirmed the correction before promotion. Fedora is therefore present
in both production `profiles` and `supportedProfiles`. The separately packaged
verification app remains available for regression testing against isolated app
data and UTM names.
