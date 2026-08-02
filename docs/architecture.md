# Architecture

The runtime is native Swift and has four boundaries:

| Layer | Current files | Responsibility |
|---|---|---|
| App | `SandfortApp.swift` | SwiftUI state, confirmations, credentials, progress |
| Guest catalog | `LinuxGuestCatalog.swift` | Curated image metadata, hardware requirements, and provisioning strategy |
| Portable core | downloader, checksum, cloud-init, ISO writer, workflow | Trusted image acquisition and provisioning policy |
| Host provider | `UTMBundleBuilder.swift`, `UTMLauncher` | Hypervisor bundle format and native host launch |

The production catalog exposes tested Ubuntu 24.04, Fedora 44, Debian 13, and
openSUSE Leap 16 ARM64 profiles.
The workflow and UTM builder consume the selected profile rather than embedding
image and hardware constants. `CloudInit.swift` and `FedoraCloudInit.swift`
contain separate distribution provisioning strategies. Future distributions
must supply their own strategy without weakening common isolation policy.
Catalog entries are compiled into the app, not accepted from arbitrary URLs or
an unsigned remote catalog.

The catalog distinguishes selectable `profiles`, baseline-compatible
`supportedProfiles`, and pre-release `qualificationProfiles`. Fedora Cloud 44
and Debian 13 passed their real-UTM qualification matrices and are in both production collections.
Its provisioner generates Fedora-specific DNF5, GNOME/GDM, firewalld, SELinux,
guest-agent, and automatic-update policy. A separately packaged Fedora
verification app still admits only that exact profile and uses its own bundle
ID, Application Support directory, legacy-migration policy, and UTM name prefix.
This permits regression testing without touching a production baseline. See
`linux-profile-provenance.md` for artifact intake and `fedora-qualification.md`
for the manual verification matrix.

Debian 13 is the third production provisioner. `DebianCloudInit.swift` generates Debian-specific APT,
GNOME/GDM, NetworkManager, AppArmor, UFW, guest-agent, and unattended-upgrade
policy. Its separately packaged regression build uses an independent bundle
identifier, Application Support directory, cache, and UTM prefix. Its release
matrix is retained in `debian-qualification.md`.

openSUSE Leap 16 is the fourth production provisioner. `OpenSUSECloudInit.swift`
generates Leap-specific Zypper, GNOME/GDM, NetworkManager, SELinux, firewalld,
guest-agent, and security-patch timer policy, and compensates for two Leap
specifics: its GNOME pattern pulls in no browser, and its VT1 getty would
otherwise show a console login prompt before the graphical greeter. Revision 3
passed its matrix and was promoted; that matrix is retained in
`opensuse-qualification.md` and its separately packaged regression build keeps
an independent bundle identifier, Application Support directory, cache, and UTM
prefix.

`OpenPGPSignatureVerifier.swift` and `TrustedSigningKeys.swift` sit beside the
catalog as security-critical intake support. They confirm that a pinned image
checksum is a value the distribution signed, using Security.framework RSA rather
than a `gpg` dependency. `security-model.md` states the rules that keep them
safe to change.

Profile-sensitive provider calls receive the resolved `LinuxGuestProfile`
explicitly. Setup, clean creation, reset, and repair therefore use the baseline's
saved profile rather than a global Ubuntu default. Legacy state without a profile
ID resolves to the original Ubuntu profile; an explicit unknown ID is never
silently replaced. `GuestProvisioningSupport.swift` contains only common safe
mechanics, while package-manager, desktop, firewall, and service policy remain in
the distribution provisioner.

New baselines persist the profile ID, profile revision, and exact source-image
SHA-256. The bundled catalog retains every profile revision that remains safe for
existing baselines. State written before these fields existed stays usable only
through an explicit legacy mapping and is not rewritten with a checksum Sandfort
cannot prove. A mismatched revision or checksum blocks repair, reset, and new
instances while leaving Resume and the destructive Rebuild path available.
Reopening or finishing an incomplete setup requires all exact metadata because it
regenerates trusted guest setup media.

Each curated profile may have one independent environment containing a protected
baseline and a backward-compatible array of numbered clean instances. The
pre-Phase-7 singleton state remains at its original root and is adopted as the
matching Ubuntu or Fedora environment without moving its VM bundles. Additional
environments live under `Sandfort/Environments/<profile-id>` and share only the
immutable verified-image cache. Existing UTM registrations keep their saved
names until that environment is rebuilt; every new or rebuilt VM name includes
the distribution. This avoids creating a stale UTM registration merely to
improve a label. Legacy single-instance state is migrated to
Instance 1. Each provider must give every new instance independent disk and UEFI
state plus unique hypervisor and network identifiers. Optional user labels are
state metadata and part of the UTM display name only; renaming must not move the
bundle or change its identity. Reset may replace the hypervisor UUID and MAC
address while retaining the app-level number, label, bundle path, and display
name.

The environment selector scopes every routine action. **Add Linux Environment**
creates another profile without deleting an existing one. Rebuild and Delete
Environment affect only the selected environment, and every operation resolves
the exact profile persisted by that environment. Distinct UTM names, directories,
VM UUIDs, MAC addresses, disks, and UEFI state allow instances from different
distributions to run concurrently.

`VirtualMachineProvider` is the provider contract. The workflow depends on that
protocol rather than directly on UTM. A future one-click installer should be a new
Swift package/app target with its own host provider while reusing or porting the
portable policy and test vectors. Suggested target layout:

```text
sources/
  sandfortcore/              download, verification, cloud-init policy
  sandfortmacosapp/          SwiftUI frontend
  providers/utmmacosarm64/   current UTM plist and launch implementation
  providers/utmmacosx64/     future x86_64 image/configuration
  providers/hypervwindows/   future Windows provider
  providers/qemulinux/       future Linux provider
```

Each provider must enforce no host directory, clipboard, automatic USB, bridged
networking, or port forwarding, and must restore a trusted baseline before every
untrusted launch. Image URLs and hashes are architecture-specific and immutable.
