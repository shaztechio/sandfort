# Architecture

The runtime is native Swift and has three boundaries:

| Layer | Current files | Responsibility |
|---|---|---|
| App | `SandfortApp.swift` | SwiftUI state, confirmations, credentials, progress |
| Portable core | downloader, checksum, cloud-init, ISO writer, workflow | Trusted image acquisition and provisioning policy |
| Host provider | `UTMBundleBuilder.swift`, `UTMLauncher` | Hypervisor bundle format and native host launch |

Persisted state contains one protected baseline and a backward-compatible array
of numbered clean instances. Legacy single-instance state is migrated to
Instance 1. Each provider must give every new instance independent disk and UEFI
state plus unique hypervisor and network identifiers. Optional user labels are
state metadata and part of the UTM display name only; renaming must not move the
bundle or change its identity. Reset may replace the hypervisor UUID and MAC
address while retaining the app-level number, label, bundle path, and display
name.

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
