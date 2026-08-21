# Linux: a plan

Nothing here is built. This is the Linux instance of the checklist in
[adding-a-platform.md](adding-a-platform.md), and a sibling of
[WINDOWS.md](WINDOWS.md).

Two things make it a different shape from the Windows plan. The hypervisor
question has no argument in it, and the product question does.

## The hypervisor is not the interesting decision

QEMU with KVM. There is no second candidate worth the paragraph: it is in the
kernel, it reads QCOW2 directly so the whole disk pipeline survives untouched,
and its user-mode networking expresses both of Sandfort's network modes exactly
— `-netdev user,restrict=on` *is* the offline guarantee, and dropping `restrict`
is the Internet mode. None of it needs root.

The open sub-question is **libvirt or raw QEMU**. libvirt brings a defined domain
format, lifecycle management, and network primitives, at the cost of a daemon, a
group-membership permission model, and a second thing to be compatible with. Raw
QEMU is fewer moving parts and matches how Sandfort already treats UTM: write a
configuration, spawn a process. Start with raw QEMU and adopt libvirt only if
lifecycle management proves to want it.

## The structural problem: the provider boundary is too small

`VirtualMachineProvider` covers bundle creation, reset, repair, materials attach
and detach, renaming, and a running check. It does **not** cover starting,
stopping, or unregistering a VM. Those live in `UTMLauncher` and
`UTMRegistryController`, both written directly against UTM's Apple Events,
outside the abstraction that is supposed to make other hosts possible.

That the contract can grow is not theoretical: it already did, when materials
added `attachMaterials` and `detachMaterials`, and the macOS provider absorbed
them without disturbing anything else. Lifecycle is a larger version of the same
move, not a different kind of change.

On macOS the omission was reasonable: UTM owns the library and the window, and
Sandfort is a policy layer over it. **On Linux there is no UTM.** GNOME Boxes is
not automatable enough to delegate to, and nothing else is ubiquitous. So
Sandfort becomes the VM manager rather than a layer over one, and it owns process
lifecycle: spawn, monitor, shut down, reap, and notice a crash.

That is the largest piece of work in this plan, and it is not Linux-specific
work. The contract needs to grow to cover lifecycle, and `UTMBundleBuilder`
needs to implement the new methods by delegating to the Apple Event code it
already has. **Do that first, on macOS, with the existing tests green.** It is
the same prerequisite for Windows, and doing it as part of a port means changing
the abstraction and writing its first new implementation at the same time.

## What ports unchanged

As in the Windows plan: the curated catalog, all four cloud-init profiles, the
OpenPGP verifier, the QCOW2 resizer, the ISO-9660 writer, the password policy,
and the safety acknowledgement. Architecture-neutral, host-neutral, and the bulk
of the accumulated knowledge.

One difference from Windows worth stating plainly: **Swift on Linux is a real
option.** Foundation and SwiftPM work; only SwiftUI is absent. The Windows plan
concluded a C# or Rust core might ship sooner because the toolchain story is
thinner there. Here the portable core can genuinely be shared, and only the view
layer — GTK4 with libadwaita, or Qt — needs writing. That makes Linux the
cheaper of the two ports, and arguably the one that should go first, because it
proves the shared core with the least rewriting.

One exception, small but worth naming rather than discovering:
`MaterialsPackager` archives a chosen folder through
`NSFileCoordinator().coordinate(readingItemAt:options:[.forUploading])`, and
`NSFileCoordinator` is not in Swift Corelibs Foundation. The size checks, the
name sanitizing, and the `ISO9660Writer` call all port; that one step needs a
Linux zip implementation, and it is user-visible because the archive is what the
user unpacks inside the guest. The Windows plan needs the same thing for the same
reason.

## Both architectures matter

Windows is overwhelmingly x86-64. Linux is not: x86-64 desktops, ARM64 servers,
Ampere workstations, and Asahi on Apple silicon are all real. Both need curated
profiles with their own URLs, checksums, and revisions, and each needs its own
qualification run. The catalog roughly triples rather than doubles.

Guests run natively on the matching host architecture. Do not emulate across
architectures: TCG is slow enough to make the product feel broken, and it is not
what any of these profiles were qualified against.

## Distribution has no notarization to copy

macOS gave a single answer — Developer ID plus notarization, verifiable offline
by a stapled ticket. Linux has no equivalent, and the trust story has to be
rebuilt rather than ported:

- **AppImage** — one file, runs anywhere, no sandbox to fight. Weakest identity
  story: trust reduces to a checksum and a signature the user must check.
- **Flatpak** — the best desktop integration and a real sandbox, which then has
  to be opened for `/dev/kvm` and for spawning a hypervisor. Worth checking early
  whether that combination is even sensible, rather than late.
- **Native `.deb`/`.rpm`** — best integration and the strongest trust story,
  because repository signing is a chain users already rely on. Highest ongoing
  cost, multiplied by every distribution and release supported.

Whichever is chosen, `docs/releasing.md` and the release workflow need a Linux
path, and `security-model.md` needs an honest paragraph about what verifying a
Linux download actually proves.

## Materials

The QEMU drive shape is identical to the one in
[WINDOWS.md](WINDOWS.md#materials) — cdrom media, `readonly=on`, a device chosen
per profile, never VirtIO — and so are the rules that make it safe: clean
instances only, the file removed as well as the drive entry when repair finds one
on a setup VM or a baseline, the inherited copy dropped by `createCleanBundle`,
and the guest always handed an image built from a copy rather than the user's
file. Attach and repair must write the same shape; they did not once, and repair
silently undid the attach.

The part specific to this plan is the catalog. `materialsInterface` is SCSI for
Ubuntu, Debian, and openSUSE and USB for Fedora, and that USB is a fact about the
**ARM64** Fedora Cloud Base kernel's module set — it ships no `sym53c8xx` — not
about Fedora. Since this port covers both architectures, every profile qualifies
its own interface against its own image. Do not carry a value across an
architecture boundary any more than a checksum.

## Isolation invariants, mapped

| Invariant | Linux mechanism |
| --- | --- |
| Offline clean runs | `-netdev user,restrict=on`, or no network device at all |
| Internet runs, no inbound | user-mode NAT with no `hostfwd` |
| No host directory sharing | no `virtiofs`, no `9p`, no shared filesystem device |
| No clipboard sharing | no SPICE agent, no clipboard channel |
| No automatic USB | no `usb-host` passthrough |
| Instance not running | the qcow2 `fcntl` lock, exactly as today — QEMU holds it |
| Per-instance identity | fresh VM UUID and MAC per instance |
| Firmware state per instance | per-instance OVMF vars file, as `efi_vars.fd` today |
| Materials read-only | cdrom media with `readonly=on`, reasserted on every repair |
| Materials on clean instances only | never written for setup or baseline; repair strips the entry **and** the file |
| No guest-to-host path via materials | the image is built from a copy, never the user's file |

`ensureBundleNotRunning` is the one piece that needs no adaptation at all: it
already tests the QEMU write lock on the disk, and on Linux that is the same
QEMU.

## The product question, asked honestly

On macOS, Sandfort's value has two halves: a curated verified guest, and making
disposable VMs pleasant on a platform where that is otherwise fiddly.

On Linux the second half largely evaporates. `virt-manager`, `virsh`,
`multipass`, `incus`, and `distrobox` exist, and the audience knows how to make a
VM. What is left is the half that actually matters — an immutable verified image,
a protected baseline, offline by default, disposable instances, and a written
threat model — but it is a narrower pitch, and the plan should not pretend
otherwise.

That is not an argument against the port. It is an argument for leading with the
policy rather than the convenience, and for treating the Linux port as
lower-priority than Windows on audience grounds even though it is cheaper on
engineering grounds.

## Phases

1. **Widen the provider contract to cover lifecycle, and split the package**,
   both on macOS with tests green. `Package.swift` declares one macOS target over
   all of `sources/sandfortapp/`, 13 of whose 33 files import SwiftUI or AppKit,
   so there is no portable core to build on a Linux runner until it is split.
   Prerequisites for any second host, and the riskiest change here.
2. **Core on Linux.** Everything under "What ports unchanged" building and
   passing on a Linux runner with no UI.
3. **`QemuKvmProvider`.** Bundle layout, the materials drive, process lifecycle,
   and every row of the isolation table asserted in tests — including an
   attach-then-repair test proving repair does not undo the attach.
4. **One profile end to end**, x86-64 Ubuntu: download, verify, provision, boot,
   automatic poweroff, graphical login, offline reset, Internet reset, and
   materials attached, visible on the desktop, detached, and not resurrected by
   the next reset.
5. **The rest of the matrix.** The other three distributions, then ARM64, each
   qualifying its own `materialsInterface`.
6. **Shell and packaging.** GTK4 or Qt over the existing view model, and one
   distribution format chosen deliberately.

## Open questions to settle first

- **libvirt or raw QEMU.** Start raw; revisit if lifecycle management demands it.
- **Which packaging format**, and whether Flatpak's sandbox and `/dev/kvm` are a
  sensible pairing. Answer before phase 6, not during it.
- **`/dev/kvm` permissions.** Group membership is the usual answer and a poor
  first-run experience. Decide what the app says when KVM is present but
  unreadable, and never silently fall back to TCG emulation.
- **Who owns the VM window.** QEMU's GTK display is the simple answer; SPICE is
  the flexible one. This is the closest thing to a UX decision in the plan.
- **Ship QEMU or require it**, the same question the Windows plan asks. On Linux
  the answer is more clearly "require": it is packaged everywhere, and bundling
  it means owning its CVEs.
