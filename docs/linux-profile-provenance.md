# Linux profile provenance

Catalog image metadata is reviewed and version-controlled. Runtime downloads
must use the exact profile URL and pass the pinned SHA-256 before Sandfort opens
or modifies the image. A new image or provisioning policy receives a new profile
revision; an existing revision is never retargeted.

## Debian 13 (Trixie) ARM64

Status: qualified and selectable in the production catalog.

- Profile: `debian-13-arm64`, revision 3
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

- Profile: `fedora-44-arm64`, revision 1
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
