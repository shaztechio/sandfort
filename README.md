# Sandfort

![Sandfort app icon](assets/Sandfort.png) Sandfort is a native SwiftUI app that
creates disposable Linux VMs for untrusted work. Its curated catalog currently
supports Ubuntu 24.04 LTS, Fedora Cloud 44, Debian 13, and openSUSE Leap 16.
The first
provider supports Apple Silicon macOS and [UTM](https://mac.getutm.app/).

**A clean machine for untrusted work.**

Project site: [sandfort.app](https://sandfort.app/)

Sandfort was inspired in part by Elastic Security Labs' research into
[Contagious Interview malware using SVG steganography](https://www.elastic.co/security-labs/contagious-interview-malware-svg-steganography),
which illustrates the risks of running untrusted coding challenges directly on
a personal computer.

Read the [Sandfort Help guide](HELP.md) for complete operating, safety, and
troubleshooting instructions. The same source is packaged as the searchable
native Help Book available from **Help → Sandfort Help** in the app.

## Screenshot

![Sandfort app showing a ready sandbox instance](assets/Sandfort-screenshot.png)

## Quick start

1. Download and install [UTM](https://mac.getutm.app/).
2. Run `make app`.
3. Open `dist/Sandfort.app`, choose an Ubuntu, Fedora, Debian, or openSUSE
   environment,
   and click its **Create Environment** action.
   Before creating or rebuilding, choose whether the baseline should include
   Python 3 development tools and the latest official Node.js LTS/npm. Git, curl,
   and jq are always included. Visual Studio Code is included by default and can
   be turned off. Node's and VS Code's Linux ARM64 downloads are SHA-256 verified
   against the vendor's published checksum.
   Advanced mode also accepts a custom shell script, documented with worked
   examples in [docs/custom-setup-scripts.md](docs/custom-setup-scripts.md). It
   is embedded in cloud-init
   and runs as root inside the selected Linux guest during baseline creation,
   never on the macOS host.
4. The app downloads the profile's official ARM64 cloud image, shows byte-based
   percentage progress, verifies its pinned SHA-256, and
   opens the generated VM in UTM.
5. First boot uses UTM's text terminal because the cloud images send setup
   output to their serial console. Let it install the desktop, Git, curl, guest
   tools, firewall, and security updates. Leave it running until all selected
   tools are verified, setup journals and package caches are compacted, and the
   VM powers itself off automatically.
6. Click **Finish Setup**. UTM will clearly label that environment's source VM as
   **Protected Baseline** and the first disposable VM as **Instance 1**.
7. Select an instance and use the **Run Instance** menu, or click
   **New Clean Sandbox** to create another numbered instance from the baseline.
   Give it an optional descriptive name for identification. Clean instances use
   the graphical desktop display and may run concurrently.

## Using clean sandboxes

Clean sessions use a small in-memory system journal. This avoids persistent
journal flushing during disposable boots and discards guest logs with the rest
of the clean session when it shuts down. Baseline setup also disables
distribution-specific wait-online services so an unavailable network does not
delay the graphical login.

The setup login uses a generated, memorable four-word hyphen-separated phrase
and is displayed in the app. Every numbered instance has an independent disk,
UEFI state, VM UUID, and MAC address. **Resume Instance** preserves its current
work and contamination. **Reset & Run Clean** restores only that instance from
the protected baseline. Always start instances through the app and never run the
Protected Baseline directly in UTM.

Reset removes the stopped instance's old UTM registration and recreates its
bundle before launch. This makes an already-open UTM library load the selected
offline or Internet mode instead of a cached configuration. The permanent
instance number and optional name remain, while its disposable VM UUID, MAC
address, disk, and UEFI state are freshly generated or restored.

Each Linux environment has an independent protected baseline, credentials,
tool configuration, and numbered instances. Use **Add Linux Environment** to
create Ubuntu, Fedora, Debian, and openSUSE environments side by side; instances from
those environments can run concurrently. Verified image downloads are shared, but VM disks and
state are not.

During **Rebuild**, the app rebuilds only the selected environment and asks for
its new baseline password, prefilling the current password. The chosen value is validated before any existing
VM data is deleted, then applied by cloud-init and inherited by all new instances.
After confirmation, macOS may ask permission for Sandfort to control UTM. The
app uses that permission to remove the old protected baseline and every recorded
numbered instance from UTM's library before deleting their app-owned bundles. If
permission is denied, rebuild stops before deleting the current sandbox. Sandfort
opens UTM automatically if it is closed, then waits for UTM to confirm each
library removal before continuing. This prevents UTM from retaining a stale entry
while its deletion is still in progress.

Use **Delete Environment** to remove only the selected distribution's baseline
and instances. Other environments and cached verified downloads remain.

Instance names can be changed later with **Run Instance → Rename Instance**.
The permanent instance number, bundle path, VM UUID, disk, and baseline
relationship do not change when a display name changes.

Use **Run Instance → Delete Instance** to remove a stopped instance. The app
unregisters it from UTM, waits for confirmation, moves its bundle to macOS Trash,
and removes it from saved state without changing the Protected Baseline or other
instances. Deleted instance numbers are not reused.

Each instance creation and clean launch asks whether the guest should have Internet access. The default
is offline. Internet-enabled runs still disable shared folders, clipboard, USB
sharing, and incoming port forwarding, but UTM must relax guest-to-host network
isolation to provide outbound access.

## Native runtime

The distributed app does not bundle or invoke shell scripts, `osascript`,
AppleScript, `curl`, `qemu-img`, or `hdiutil`. Swift code performs the download,
streaming progress, SHA-256 verification, QCOW2 resize, ISO-9660 cloud-init media
creation, UTM plist generation, and launch through `NSWorkspace`.

Run tests with `make test`. Read [why these Linux profiles were chosen](docs/linux-profile-selection.md),
[the architecture](docs/architecture.md), [security model](docs/security-model.md), and
[sandbox password-strength assessment](docs/password-strength.md) before using
the VM with hostile code.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Sandfort's isolation rules and curated
image catalog are the product, so read [AGENTS.md](AGENTS.md) and
[docs/security-model.md](docs/security-model.md) before changing VM
configuration, networking, downloads, or guest provisioning.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md)
for private reporting, what is in scope, and the documented limitations that are
design decisions rather than bugs.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE)
for bundled third-party material.
