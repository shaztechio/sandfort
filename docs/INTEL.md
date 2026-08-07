# Intel macOS: a plan, and an argument against it

Nothing here is built, and unlike [LINUX.md](LINUX.md) and [WINDOWS.md](WINDOWS.md)
this document does not recommend building it.

It is the third sibling of the checklist in
[adding-a-platform.md](adding-a-platform.md), and the shape is different again.
Windows had to choose a hypervisor. Linux had to justify a product. Intel macOS
has neither problem: the hypervisor is the same UTM, the product is the same
product, and the engineering is the cheapest of the three by a wide margin.

It still should not be built, and the reason is arithmetic rather than
architecture. That is the whole document.

## The verdict, first

**Not worth doing, unless someone turns up with a specific machine.**

The condition, stated precisely so it can be checked rather than argued: an
owned Mac Pro 2019, iMac 27" 2020, or MacBook Pro 16" 2019, with at least 32 GB
of RAM and a 1 TB SSD, a floor of **Sequoia 15 rather than Sonoma 14**, and an
accepted end-of-life date for the whole provider. Absent that hardware the port
cannot clear the boot-smoke-test requirement in
[AGENTS.md](../AGENTS.md), and a profile that cannot clear it must not ship.

**Phase 0 below is worth doing regardless of that verdict**, and would be worth
doing if Intel were never supported at all.

## The blocker from the other two plans does not apply here

[LINUX.md](LINUX.md) records the finding that matters beyond Linux: starting,
stopping, and unregistering a VM live outside `VirtualMachineProvider`, so the
contract has to grow before any second host.

That finding is accurate and it does not block this. Every one of those
operations is an Apple Event addressed to `com.utmapp.UTM`, plus one
`NSWorkspace.open`. The host OS is the same macOS, the target is the same UTM,
and Apple Events carry no architecture semantics. UTM ships universal — `lipo
-archs` on 4.7.5 returns `x86_64 arm64` — so the same bundle identifier resolves
to the same scripting interface on an Intel host.

Say it plainly, because it is the most reusable sentence here: **the
widened-contract prerequisite is a second-*host* prerequisite, not a
second-*architecture* one.**

This is why the port is cheap. It is a catalog change wearing a platform's
clothing.

## UTM silently gives you emulation, and that is disqualifying

This is not "run the existing profiles on an Intel Mac." From UTM's own source,
acceleration is gated on the VM architecture matching the host:

```swift
var hasHypervisorSupport: Bool {
    guard UTMCapabilities.current.contains(.hasHypervisorSupport) else { return false }
    if UTMCapabilities.current.contains(.isAarch64) { return self == .aarch64 }
    else if UTMCapabilities.current.contains(.isX86_64) { return self == .x86_64 }
    else { return false }
}
```

and the argument builder turns that into `-accel hvf` or `-accel tcg`.

So on an Intel host an ARM64 VM gets `hasHypervisorSupport == false`, Sandfort's
`"Hypervisor": true` in the bundle is **ignored**, and QEMU launches under whole-
system TCG emulation. A GNOME desktop under TCG is not a slow product, it is a
broken one — and nothing in the configuration Sandfort wrote reports that it
happened.

[LINUX.md](LINUX.md) already forbids exactly this: never silently fall back to
TCG. Here UTM does it for us. Sandfort must **refuse** an unaccelerable profile
outright, not warn about it.

The consequence is that the catalog gains a second axis: four distributions ×
two architectures. All four distributions publish symmetric x86_64 cloud images,
so the images exist; every one needs its own pinned SHA-256, its own signature
check, its own provenance record, and its own revision counter starting at 1.
Never reuse an ARM64 checksum or revision.

## Sonoma is the wrong floor, and it is worth being blunt about why

Intel Macs that run Sonoma, minus those that run Sequoia, are two
machines: **MacBook Air 2018 and 2019**. Dual-core, four-thread, 7-watt parts,
sold with 8 GB of RAM and a 128 GB SSD at the base configuration.

Sandfort's fixed hardware is 4 CPUs, 4 GiB, and a 64 GiB disk per environment,
rising to 6 GiB and 96 GiB under the deferred sizing plan in
[AGENTS.md](../AGENTS.md) — and the product's central affordance is running
several environments and several instances concurrently.

On a base 2018 Air that is 4 vCPUs on 2 physical cores, most of the machine's
RAM, and a 96 GiB sparse disk on a 128 GB SSD. It would not be slow. It would
not fit.

**The only thing choosing Sonoma over Sequoia buys is the one machine in the
compatibility list that cannot run the product.** Three further reasons point the
same way: Sonoma leaves Apple's security-update window when macOS 27 ships, and
an unpatched host is a poor foundation for an app whose premise is "you are about
to run malware on this machine"; GitHub's only Intel runner is `macos-15-intel`,
which runs Sequoia, so a Sonoma floor is untestable in CI even for the unit
suite; and macOS 26 Tahoe is the final Intel release, supporting four models,
after which macOS 27 drops Intel entirely.

### The deployment target is a separate decision

The current floor is macOS 13, in `Package.swift` and in
`tools/packaging/Info.plist`. Nothing about x86_64 needs an API newer than that,
and UTM 5 requires macOS 13 as well, so the two already agree. Raising the floor
to 14 would be a decision about SwiftUI APIs taken on its own merits, and it
would cost Apple-silicon users on Ventura for no Intel-related gain.

If an Intel slice ever ships, its floor should be Sequoia — enforced as a
**runtime** check, not a bundle-wide `LSMinimumSystemVersion` bump, since that
key is one value for the whole bundle. `LSMinimumSystemVersionByArchitecture`
exists but is keyed on `LSArchitecturePriority` architectures, historically
`ppc`/`i386`/`x86_64`, and whether it accepts `arm64` is unconfirmed.

## What ports unchanged

More than in either sibling document, and worth naming because it is the
strongest part of the case:

- `NativeDownloader.swift`, `DiskUtilities.swift`, `ISO9660Writer.swift`. All
  byte-level code is endian-explicit already — QCOW2 fields are read through an
  explicit big-endian initializer, and the ISO writer deliberately emits both
  endiannesses. Nothing depends on host byte order.
- The disk-lock check. Plain POSIX `fcntl(F_SETLK)`, identical on x86_64 macOS.
- `OpenPGPSignatureVerifier.swift` and `TrustedSigningKeys.swift`. Same
  Security.framework, and Ubuntu, Fedora, and openSUSE sign their x86_64
  manifests with the keys already bundled. No cryptographic substitution at all,
  unlike the Windows plan.
- **The provider contract itself**, per the section above.
- The persisted-state model. Environment directories key on `profile.id` and
  compatibility keys on `(id, revision, sha256)`, so a distinct ID means an
  x86_64 baseline can never be mistaken for an ARM64 one. **No new field.** The
  legacy-profile mapping stays ARM64-only and correctly returns nil.
- `UTMRegistryController.swift`, `SandboxLibrary.swift`, `SandfortViewModel`, and
  the entire view layer.

The UTM plist writer is already parameterized: `architecture`, `utmArchitecture`,
and `utmTarget` are fields on `LinuxGuestProfile.Hardware` rather than constants,
and a bundle test proves it by writing a fake profile and asserting the values
reach the plist. `q35` is UTM's default x86_64 target and UEFI boot is enabled
for any `pc`/`q35` target, so most keys need no change.

## Three hardcoded ARM64 assumptions, and only one is where you would look

The interesting one is not in `UTMBundleBuilder.swift`.

**Firmware.** `SandfortWorkflow.swift:759-761` hardcodes
`Contents/Resources/qemu/edk2-arm-vars.fd`. UTM's own mapping is `edk2-arm` vars
for aarch64 and `edk2-i386` vars for x86_64 — and on a 4.7.5 install
`edk2-i386-vars.fd` exists while **`edk2-x86_64-vars.fd` does not**; the vars
blob really is named for i386, even though the code blob is not. Handing an
x86_64 guest the ARM vars produces a UEFI boot failure rather than a clean error.
The user-facing string in `SandfortConfiguration.swift:167` is wrong too — it
says "UTM's ARM64 UEFI firmware could not be found."

**Serial console.** `ttyAMA0` → `ttyS0`, appearing in the failure path and the
getty mask in all four provisioners. This is the *diagnostic rescue path* for a
failed baseline: get it wrong and a failed x86_64 setup is unreachable and
silent, which is the worst possible place for this particular bug.

**Guest tool architecture.** `linuxArchiveArchitecture: "arm64"` → `"x64"`, in
all four provisioners. Note the trap: Node.js publishes `node-vX-linux-x64` and
VS Code's update path is `linux-x64` — both `x64`, neither `x86_64` nor `amd64`
— but they are consumed by two different call sites and nothing would catch a
mismatch except a failed baseline half an hour in. Add a contract test.

### And one that is a bug today

`SandfortWorkflow.swift:878-885` reports the host architecture through a
**compile-time** `#if arch(arm64)`. It describes the slice that is running, not
the machine, so in an arm64-only binary it is a constant string that `doctor()`
interpolates into a sentence and never acts on. There is no host-architecture
check anywhere in the app.

Today that is reachable one way: an Apple-silicon Mac where the user ticked "Open
using Rosetta" gets a `doctor()` report claiming an unsupported architecture.
Rare, but it is `doctor()` lying, and `doctor()` exists to be believed.

## Isolation invariants, mapped

Every mechanism holds identically on x86_64/q35, and no plist key differs by
architecture. That is a genuinely reassuring result rather than a formality:
`IsolateFromHost` maps to user-mode `restrict=on` regardless of architecture,
directory sharing, clipboard, USB, and bridged networking are the same keys, the
disk lock is the same syscall, and per-instance UUIDs and MACs are unaffected.

**One row changes**: per-instance firmware state, which is the same mechanism
with a different source blob, per the firmware finding above.

One addition to residual risk, and it is not about isolation. UTM has an
unresolved report of **high idle host CPU under HVF on Intel**, with a
collaborator confirming it does not occur on Apple silicon. The thread is old
enough to be stale, but it describes exactly the workload Sandfort creates — a
desktop VM parked at a greeter — and on a laptop that means battery and fans.
Measure before claiming the experience is acceptable.

## The cost that actually decides it

[AGENTS.md](../AGENTS.md) requires, before a profile appears in the UI:
automated contract tests **plus** a real UTM boot smoke test through setup,
automatic poweroff, graphical login, offline reset, and Internet-enabled reset.

- **5 gates × 4 profiles = 20 crossings**, none automatable, none runnable on
  Apple silicon.
- Each preceded by a full baseline build. The documented setup times are 10–30
  minutes for Ubuntu and 20–45 for the others — **and those are Apple-silicon
  numbers.**
- Each profile also carries its qualification document's full matrix, including
  two concurrent instances and Rebuild with UTM both open and closed.
- Plus a regression pass on all four **ARM64** profiles, because the shared
  substitutions touch every provisioner. **This is the sharpest hidden cost:** a
  careless revision bump on an ARM64 profile forces every existing user to
  Rebuild. The work must be provably additive.
- **CI cannot help.** GitHub retired `macos-13` in December 2025; the replacement
  `macos-15-intel` disappears in August 2027, after which no x86_64 macOS runner
  exists at all. The boot tests were never going to run in CI regardless.

For a solo maintainer without the hardware, this is not realistic. And buying a
cheap 2018 Air to qualify it would be worse than not buying one: it would qualify
the port against the configuration that cannot run it.

## Phases

**Phase 0 — make the architecture axis explicit, ship no x86_64 profile.**
**Done.** No new hardware, no forced rebuild, entirely on Apple silicon with the
existing suite green. It was worth merging on its own merits, and it was.

- The firmware vars name, the serial console device, and the archive
  architecture are `LinuxGuestProfile.Hardware` fields, threaded through the
  four provisioners in place of the hardcoded literals. Firmware resolution
  takes the resolved profile rather than a constant path.
- The compile-time architecture check is now `HostArchitecture`, detected at run
  time including Rosetta, and `doctor()` reports host RAM and free space.
- `create()` refuses a baseline whose architecture this host cannot
  hardware-accelerate. A no-op today by construction; it exists so it cannot be
  forgotten when it stops being one.
- The firmware error no longer says "ARM64".

The expectation that this would be easy was itself the finding, and it held.
The one thing worth passing on: **byte-equality is the only assertion that
proves a guest did not change.** Every other test in the suite is a `contains`,
so all of them stayed green through a mutation that would have forced every
existing user to Rebuild. `GuestArchitectureTests` pins a SHA-256 of the
generated `user-data` per profile per tool selection, captured before the
change; a failure there is a changed guest, not a test to update.

Phase 0 removed latent hardcoding that was wrong today, it is the shared
prerequisite both other port plans need for their x86-64 catalogs, and it turns
the rest of this into a catalog change.

**Phase 1 — one profile, one boot, one machine.** Ubuntu x86_64 into the
qualification profiles, a universal build, its own qualification target, and a
real boot through all five gates on a real Intel Mac. **The exit criterion is not
"it boots" — it is "it is pleasant."** Record setup wall-clock, idle host CPU
with the VM at the greeter, and time-to-desktop on a clean reset. If those
numbers are bad, stop.

**Phase 2 — universal build and distribution.** `--arch arm64 --arch x86_64`,
the relocated product path, notarization, an Intel CI job, and the release-notes
requirements string. The app roughly doubles in size and every user pays for the
slice they cannot run.

**Phase 3 — the other three profiles**, each with its own qualification run,
provenance record, and Make target.

**Phase 4 — docs and site**, including the project site's requirements copy.

## Open questions to settle first

- **`virtio-gpu-pci` or `virtio-vga` on x86_64?** Both are valid in UTM's x86_64
  device list, but `virtio-gpu-pci` has no legacy VGA compatibility, so the
  pre-driver console depends entirely on OVMF's virtio-gpu GOP driver. It should
  work. "Should" is how you get a black screen during UEFI and GRUB — the exact
  class of bug the deferred `plymouth-quit-wait` note is scarred by. Test both,
  and decide before phase 1 rather than during it.
- **Is UTM's Intel idle-CPU problem still real?** Park a clean instance at the
  greeter for ten minutes and measure. If it is still high, that is disqualifying
  on a laptop and belongs in residual risk rather than in a bug report from a
  user.
- **What does q35 do to boot time?** The Debian wait-online work showed how much
  of the experience is boot latency, and it turned out to be Debian-only. Measure
  `systemd-analyze critical-chain graphical.target` on x86_64 rather than
  assuming the ARM64 tuning transfers.
- **Does UTM 5 change any of this?** Everything above was verified against 4.7.5
  and UTM's current source. That gap has since been audited on its own terms —
  see `utm-version-audit.md`, which found no change to any plist key, Apple
  Event code, or URL behaviour Sandfort depends on, and left a list of live
  checks that still need a UTM 5 install. Two of its findings bear on this plan
  specifically: UTM 5.0.x is still a **beta** line, so a port cannot assume
  users are on it; and the `edk2-i386-vars.fd` path this document relies on
  sits in the same UTM-internal directory whose UTM 5 contents are unconfirmed.
  The x86_64-specific questions above remain unanswered either way.
- **Does repeated `swift build --arch` produce a working universal product, and
  where does it land?** SwiftPM relocates the product under
  `.build/apple/Products/Release/` for multi-arch builds, so the packaging script
  would need to resolve the path rather than assume it. Unverified — it needs a
  build.
- **How does the UI present eight profiles?** The flat "Add Linux Environment…"
  menu doubles. Probably a submenu per architecture, but it is a real design
  question and the wrong answer makes it easy to create the wrong environment.
- **Does `LSMinimumSystemVersionByArchitecture` accept `arm64`?** Unconfirmed,
  and the runtime check is the reliable route regardless.

## A note on `VirtualMachineProvider.identifier`

Found while checking the provider boundary: `identifier`, implemented as
`"macos-arm64.utm-qemu"`, is never read anywhere in `sources/` or `tests/`. It is
a label nobody consults. If a second provider ever exists it is either the
discriminator or it should be deleted — and this document is the first plan that
would have made it load-bearing.
