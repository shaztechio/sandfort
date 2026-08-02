# Why these Linux profiles

Sandfort's four curated profiles are Ubuntu 24.04 LTS, Fedora Cloud 44,
Debian 13, and openSUSE Leap 16. All four are production-supported on Apple
Silicon.

The catalog is deliberately small. Sandfort does not aim to list every Linux
distribution; every entry becomes trusted baseline-building code that must be
downloaded from an official source, pinned to an immutable checksum, provisioned
without manual installation, and qualified through real UTM boots.

## Selection criteria

A profile is chosen when it adds meaningful coverage while meeting Sandfort's
security and automation requirements:

- An official image suitable for virtualization, with a stable architecture and
  a checksum that Sandfort can pin in source control.
- ARM64 and UEFI support for the current Apple Silicon UTM provider.
- Automated first boot through cloud-init or an equivalently reviewable
  mechanism.
- A maintained package and security-update path.
- A graphical desktop, guest agent, firewall, and development tools that can be
  installed and verified without weakening host isolation.
- A distinct ecosystem or release model that provides useful testing coverage
  rather than merely duplicating an existing profile.

## Ubuntu 24.04 LTS

Ubuntu is the default profile because it is the most familiar starting point
for many developers and coding challenges. Its official ARM64 cloud image is
designed for automated virtual-machine deployment, and cloud-init is a
first-class part of that workflow. The LTS release provides a comparatively
stable package base and five years of standard security maintenance, reducing
baseline churn for non-technical users.

Ubuntu also establishes the broad Debian/APT compatibility users commonly
expect, while its popularity makes setup failures and guest-tool issues easier
to diagnose. It is not the only APT-based profile: Debian is retained separately
because its upstream policy, package defaults, and lifecycle differ materially.

References: [Ubuntu 24.04 LTS support lifespan](https://documentation.ubuntu.com/release-notes/24.04/),
[official Ubuntu cloud images](https://cloud-images.ubuntu.com/releases/noble/).

## Fedora Cloud 44

Fedora was chosen to cover the RPM, DNF5, SELinux, and firewalld ecosystem. It
deliberately contrasts with Ubuntu: packages and kernels move faster, mandatory
access control is SELinux rather than AppArmor, and the firewall and automatic
update implementation are distribution-specific.

Fedora Cloud publishes QEMU-ready images and signed checksum metadata. That
makes it a strong second profile for proving that Sandfort's catalog and
provisioning boundaries are genuinely distribution-aware rather than Ubuntu
logic with a different label. It is also representative of the technology that
later reaches Red Hat-family systems without adding a near-duplicate enterprise
clone to the initial catalog.

References: [Fedora Cloud downloads](https://fedoraproject.org/cloud/download/),
[Sandfort image provenance](linux-profile-provenance.md#fedora-cloud-44-arm64).

## Debian 13

Debian was chosen as the stable upstream APT counterpart to Ubuntu. It offers a
smaller, less vendor-specific base while still providing official ARM64 cloud
images, cloud-init automation, GNOME, AppArmor, UFW, unattended upgrades, and
the development packages Sandfort needs.

Debian also earns its place by exposing assumptions that Ubuntu can hide. Its
qualification uncovered two real networking differences involving persistent
first-boot configuration and Netplan's generated udev rules. Fixing those
issues strengthened the profile boundary and the clean-instance test matrix.
Debian 13 has a five-year lifecycle and officially supports AArch64, making it a
reasonable stable alternative rather than another fast-moving profile.

References: [Debian 13 release and lifecycle](https://www.debian.org/releases/trixie/),
[Debian 13 cloud-image support](https://www.debian.org/News/2025/20250809.en.html),
[Sandfort Debian provenance](linux-profile-provenance.md#debian-13-trixie-arm64).

## openSUSE Leap — fourth production profile

openSUSE Leap was chosen as the fourth candidate because it adds the SUSE and
Zypper ecosystem while retaining a stable, enterprise-oriented release model.
Although it is also RPM-based, it is not a Fedora duplicate: repository
management, package tooling, system configuration, release engineering, and
its relationship with SUSE Linux Enterprise create a distinct provisioning and
maintenance path for Sandfort to qualify.

Leap also meets the current provider's basic intake requirements unusually
well. The openSUSE project publishes an AArch64 QEMU cloud QCOW2 image together
with SHA-256 checksum and signature files. Leap 16 uses SELinux by default,
supports graphical desktop environments, and has a documented long-lived
release plan. Those properties make it a better current fourth candidate than
an image that would require an interactive ISO installation or an unofficial
ARM conversion.

Sandfort pins Leap 16.0 AArch64 Cloud Build 18.7 and its official SHA-256, and
the separate openSUSE provisioner implements Zypper updates, desktop/login
setup, NetworkManager, SELinux, firewalld, guest agents, and automatic security
patches. Qualification exposed two Leap-specific gaps that the other three
profiles do not have, because Leap's GNOME pattern neither pulls in a browser
nor leaves VT1 to the graphical greeter. Revision 3 fixes both and passed the
full UTM matrix, including offline and Internet-enabled clean instances, reset,
resume, deletion, and concurrent environments.

References: [official openSUSE Leap AArch64 cloud images](https://download.opensuse.org/download/distribution/openSUSE-current/appliances/),
[openSUSE Leap 16 release notes](https://doc.opensuse.org/release-notes/x86_64/openSUSE/Leap/16.0/yast-html/release-notes.html),
[openSUSE AArch64 guidance](https://en.opensuse.org/openSUSE:AArch64).

## Why other profiles wait

Additional distributions can still be valuable, but adding them prematurely
increases the trusted download surface, baseline maintenance, documentation,
and real-UTM regression matrix. A fourth Debian derivative would add limited
ecosystem coverage, while an image without official immutable ARM64 artifacts
cannot meet the current provider's trust model.

CachyOS was considered because an Arch-based rolling profile would add valuable
Pacman and current-toolchain coverage. It was not selected as the fourth current
provider candidate because its official distribution and optimized repositories
are x86-64-focused, and Sandfort has not identified a qualifying official ARM64
cloud image. It can be reconsidered for a future x86-64 provider or if its
official architecture support changes; Sandfort will not substitute an
unofficial conversion.

References: [CachyOS project overview](https://cachyos.org/),
[CachyOS architecture optimizations](https://wiki.cachyos.org/features/kernel/).

This list may change as distributions alter their architectures, image
publishing, or support policy. Any change must be recorded as a reviewed catalog
revision and must pass the requirements in
[Linux profile provenance](linux-profile-provenance.md) and the repository's
qualification guidance.
