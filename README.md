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

![Sandfort's window: four Linux environments in the sidebar, two with protected
baselines, one mid-setup, and openSUSE Leap 16 selected and ready to
create](assets/Sandfort-screenshot.png)

## Quick start

1. Install [UTM](https://mac.getutm.app/).
2. Download the latest `.dmg` from
   [Releases](https://github.com/shaztechio/sandfort/releases/latest), open it,
   and drag Sandfort to Applications. Builds are signed with a Developer ID
   certificate and notarized by Apple.

   To build from source instead: `make app`, then open `dist/Sandfort.app`.
3. Choose an Ubuntu, Fedora, Debian, or openSUSE environment and click its
   **Create Environment** action. Git, curl, and jq are always installed;
   Python 3, Node.js LTS, and Visual Studio Code are optional, and advanced mode
   accepts a [custom setup script](docs/custom-setup-scripts.md) that runs as
   root inside the guest, never on the host.
4. Sandfort downloads the profile's official ARM64 cloud image, verifies its
   pinned SHA-256, and opens the VM in UTM.
5. First boot runs in a text console, because the cloud images log setup to the
   serial port. Leave it alone until it finishes installing the desktop and
   tools and powers itself off.
6. Click **Finish Setup**. UTM then shows that environment's **Protected
   Baseline** and its first disposable **Instance 1**.
7. Use **New Clean Sandbox** for another numbered instance from the baseline.
   Instances run concurrently and use the graphical desktop.

## Using clean sandboxes

Each Linux environment keeps one **Protected Baseline** and any number of
disposable numbered instances built from it. **Resume Instance** reopens an
instance with its files, processes, and contamination intact; **Reset & Run
Clean** restores that instance's disk and firmware state from the baseline.
Every instance has its own disk, UEFI state, VM UUID, and MAC address, so
instances run side by side, including ones from different distributions. Start
instances through Sandfort, and never run a Protected Baseline directly in UTM.

Every instance creation and clean launch asks whether the guest gets Internet
access. Offline is the default, and an Internet run still keeps shared folders,
clipboard, USB sharing, and inbound port forwarding disabled. Rebuild, rename,
and delete act only on the selected environment. Sign-in credentials, the
permission macOS asks for the first time Sandfort drives UTM, and the rest of
the day-to-day detail are in the [Help guide](HELP.md); the guarantees
underneath them are in [docs/security-model.md](docs/security-model.md).

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
