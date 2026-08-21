# Windows: a plan

Nothing here is built. This is the concrete Windows instance of the checklist in
[adding-a-platform.md](adding-a-platform.md), written so the decisions are made
before anyone opens an editor.

It disagrees with that document on one point. `adding-a-platform.md` names
"Windows with Hyper-V" as the likely target; this plan recommends QEMU, and says
why below.

## What ports unchanged

The parts worth the most are the parts with no Apple in them:

- `LinuxGuestCatalog.swift` — profile shape, revisions, pinned checksums.
- `CloudInit.swift`, `FedoraCloudInit.swift`, `DebianCloudInit.swift`,
  `OpenSUSECloudInit.swift`, `GuestProvisioningSupport.swift` — the entire guest
  contract. YAML and shell that runs inside the guest, architecture-neutral.
- `OpenPGPSignatureVerifier.swift` — needs one substitution, below.
- `DiskUtilities.swift` — QCOW2 header parsing and resize; pure byte work.
- `ISO9660Writer.swift` — NoCloud seed generation; pure byte work.
- `MemorablePasswordWords.swift`, `SafetyAcknowledgement.swift`, and the
  password policy in `docs/password-strength.md`.

This is most of the accumulated knowledge in the project, and it is the reason a
port is transcription rather than invention.

## What has to be written

**A wider provider contract, first.** `LINUX.md` records a gap that applies here
equally: starting, stopping, and unregistering a VM live in `UTMLauncher` and
`UTMRegistryController`, written against Apple Events, outside
`VirtualMachineProvider` entirely. The contract has to grow to cover lifecycle
before any second host can exist, and that work belongs on macOS with the
existing tests green — not inside a port.

**A split package, also first.** `Package.swift` declares
`platforms: [.macOS(.v13)]` and one `SandfortApp` target covering all of
`sources/sandfortapp/`, 13 of whose 33 files import SwiftUI or AppKit. There is
no non-UI target, so phase 1's exit criterion below cannot be expressed, let
alone met. Splitting it into a portable core and a macOS UI target is the same
shape of prerequisite as the contract widening: macOS work a port should
inherit rather than perform, and cheap to do while there is still only one
implementation to keep green.

**A `VirtualMachineProvider` implementation.** Nine methods, all of them about
packaging rather than provisioning:

```
createSetupBundle    createCleanBundle    resetCleanBundle
repairBundle         attachMaterials      detachMaterials
setDisplayName       ensureBundleNotRunning
identifier
```

The two materials methods deliberately carry **no default implementation**. A
provider that quietly ignored them would compile, pass its bundle tests, and
tell a user their files are in a sandbox that does not have them. See
[Materials](#materials) below.

`ensureBundleNotRunning` is the one with a platform-specific answer. On macOS it
tests the qcow2's `fcntl` write lock, which QEMU holds while a VM is live. On
Windows the equivalent is opening the file with no sharing flags and treating
`ERROR_SHARING_VIOLATION` as "running". Same idea, different call.

**A view layer.** WinUI 3 or Avalonia. `SandfortViewModel` is already separate
from the views, so this is a re-skin of a known shape rather than a redesign.

**x86-64 profiles.** All four distributions publish x86-64 cloud images with the
same cloud-init contract, so the provisioning does not change — but the URL,
SHA-256, and revision are per-architecture, and each needs its own qualification
run. The catalog roughly doubles. **Never reuse an ARM64 checksum on x86-64.**

**A signature-verification backend.** The OpenPGP parsing stays; only the RSA
PKCS#1 v1.5 verification calls Security.framework today. That becomes CNG
(`BCryptVerifySignature`) or an equivalent. Treat this as security-critical work
under the rules in `AGENTS.md`: the negative tests — tampered payload, tampered
signature, unpinned key, corrupted armor, truncated packet, garbage — must stay
green, because a verifier that is wrong fails open.

**A launcher.** Spawning the hypervisor with arguments, the way `NSWorkspace`
opens UTM today. Not a shell dependency.

**Half of `MaterialsPackager`.** The size checks, the name sanitizing, and the
`ISO9660Writer` call are pure byte work and port unchanged. The folder-archive
step does not: it runs
`NSFileCoordinator().coordinate(readingItemAt:options:[.forUploading])`, which
has no Windows equivalent, so the port writes its own zip. Treat that as
user-visible behaviour rather than an implementation detail — the archive is
what lands in the guest and what the user unpacks there — so it needs its own
test, not an assumption that any zip will do.

## The hypervisor decision

**Recommendation: QEMU with the Windows Hypervisor Platform.**

QEMU maps onto this design almost one to one. It reads QCOW2 directly, so
`DiskUtilities` and the whole disk pipeline survive untouched. Its user-mode
networking is a direct expression of Sandfort's two network modes:
`-netdev user,restrict=on` *is* the offline guarantee, and dropping `restrict`
is the Internet mode. Launching a binary with arguments is a smaller surface
than a management API.

Hyper-V is the better isolation story — a Type-1 hypervisor with VBS behind it,
against QEMU's userspace device emulation — and it fights the design twice:

- It wants VHDX, not QCOW2, so every image needs conversion. (Raw to *fixed VHD*
  is nearly free: a 512-byte footer appended to a raw image. VHDX is the hard
  one.)
- "Internet but no host access" is awkward. A Private switch gives no network at
  all; the Default Switch NATs *and* exposes the host. The per-launch network
  choice is a load-bearing guarantee, not a convenience, and it should not be
  the thing that gets bent to suit the hypervisor.

So the hypervisor with the stronger boundary is the worse fit for the policy
that boundary exists to enforce. Choosing QEMU means saying that plainly, and
writing a more cautious version of the residual-risk section for this host.

**What would change the recommendation:** a way to get NAT without host
reachability on Hyper-V that does not depend on host firewall rules the user
could undo. If that exists, Hyper-V becomes the better answer and the disk
conversion is worth paying for.

None of this has been run. [windows-qemu-spike.md](windows-qemu-spike.md) checks
the two claims underneath it — that WHPX accelerates, and that
`-netdev user,restrict=on` isolates — in an afternoon, with no Sandfort code and
before phase 0. If either fails, the recommendation reopens while it is still
only a document.

**WSL2 is not a candidate.** Its entire design is host integration — drive
mounts, localhost forwarding, shared clipboard. That is the negation of the
guarantee, not a cheaper route to it.

## Host requirements

Choosing WHPX sets a floor, and this plan should state it as precisely as the
macOS side states macOS 13 and Apple silicon — not leave it to be discovered
during phase 1.

| | |
| --- | --- |
| x86-64 host | Windows 10 version 2004. The WHP API exists from 1803, but 2004 is what QEMU tests against. |
| ARM64 host | Windows 11 24H2 with the April 2025 optional updates or May 2025 security updates. |
| Edition | Not established. See below. |
| CPU | SLAT, plus Intel VT-x with EPT and Unrestricted Guest, or AMD SVM, enabled in firmware. |
| Feature | `HypervisorPlatform`, through Windows Features or `DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All`, then a reboot. |

**The edition question, which argues for QEMU a second time.** Hyper-V's role and
manager are Pro, Enterprise, and Education only — Microsoft says outright it
cannot be installed on Home. WHPX is a different feature, a user-mode API for
third-party virtualization stacks, and neither QEMU's documentation nor
Microsoft's API documentation states an edition restriction. Home already runs
the same hypervisor for WSL2 and VBS, and Google is sunsetting the Android
Emulator hypervisor driver at the end of 2026 and moving that entire Windows user
base onto WHPX, which it could not do if Home were excluded.

So the recommendation above has a second argument behind it, about reach rather
than design: **Hyper-V would have excluded Windows Home by definition, and QEMU
with WHPX probably does not.** Against Home's share of consumer Windows that is
not a footnote.

"Probably" is doing real work in that sentence and must not survive into a
shipped requirement. Nobody documents the edition matrix either way. **Check it
on a Home machine before publishing a requirement**, the same way a profile is
boot-smoke-tested rather than reasoned about.

**Windows on ARM is unscoped, and it is the less obvious omission.** The phases
below assume x86-64 throughout and never say whether an ARM64 Windows host is in
or out. That matters more than it looks, because the entire existing guest
catalog is ARM64: an ARM64 Windows host is the one Windows configuration that
could run profiles already qualified, rather than needing four new ones. WHPX
only became viable there in 2025, so there is no history to lean on. Decide it
explicitly rather than by silence.

## Materials

A clean instance can carry one extra drive: a read-only image Sandfort builds
from the file or folder the user picked. [materials.md](materials.md) has the
full design; what follows is only what changes on this host.

**The drive shape.** macOS writes three things into the UTM plist —
`ImageType: "CD"`, `Interface` from the profile, and `ReadOnly`. QEMU expresses
the same drive as cdrom media with `readonly=on` and a device chosen per profile.
`readonly=on` is the mechanism, not a convention: it is what makes the
read-only claim true at the hypervisor rather than in the guest's manners. Never
VirtIO, on any host — as a VirtIO disk the desktop classes the drive as an
internal system drive and never offers it to the user at all.

**`materialsInterface` is a kernel-module fact, and it is per architecture.**
Ubuntu, Debian, and openSUSE use SCSI; Fedora uses USB because Fedora Cloud Base
ships no `sym53c8xx`. That is not a property of Fedora. It is a property of the
**ARM64** Fedora Cloud Base kernel's module set, and an x86-64 image is a
different kernel build. Qualify each x86-64 profile's interface against its own
image and never inherit the ARM64 value — the same rule that forbids reusing an
ARM64 checksum, applied to a different field.

**Materials reach clean instances only**, and three separate places have to hold
that: `attachMaterials` is never called for a setup VM or a protected baseline;
`repairBundle` removes an image from those roles — the file as well as the drive
entry, since an orphaned payload is still the user's file sitting in a bundle;
and `createCleanBundle` drops one inherited from the baseline clone.

**The guest is handed a copy, never the user's file.** Guest-to-host is
impossible by construction rather than by configuration, which is what makes
this survivable if `readonly=on` is ever wrong. Reasserting `ReadOnly` on every
repair sits on top of that, not instead of it.

**Attach and repair must write the same drive shape.** They did not once, and
repair silently undid the attach on the next state read. Whatever the QEMU
provider writes on attach, its repair path writes identically — assert it, in
one test that attaches and then repairs.

**The 512 MiB payload limit is host-neutral.** It is a memory bound, not a disk
one: the ISO is built whole in memory while the caller still holds the payload.
Raising it on Windows needs the same fix it needs on macOS — streaming
`ISO9660Writer` to a file handle first — so it is not a macOS limitation a port
gets to relax.

## Security invariants, mapped

Every rule in `docs/security-model.md` has to hold. The ones whose *mechanism*
changes:

| Invariant | Windows mechanism |
| --- | --- |
| Offline clean runs | `-netdev user,restrict=on`, or no network device at all |
| Internet runs, no inbound | user-mode NAT with no `hostfwd` |
| No host directory sharing | no `virtfs`, no `9p`, no shared folder device |
| No clipboard sharing | no SPICE agent, no clipboard channel |
| No automatic USB | no `usb-host` passthrough |
| Instance not running | file share-mode probe, not `fcntl` |
| Per-instance identity | fresh VM UUID and MAC per instance, as today |
| Firmware state per instance | per-instance OVMF vars file, as `efi_vars.fd` today |
| Materials read-only | cdrom media with `readonly=on`, reasserted on every repair |
| Materials on clean instances only | never written for setup or baseline; repair strips the entry **and** the file |
| No guest-to-host path via materials | the image is built from a copy, never the user's file |

Prove each one in tests, not by inspection. That is step 5 of
`adding-a-platform.md` and it is the actual gate.

## Phases

**0. Prerequisites, on macOS.** Widen the provider contract to cover lifecycle,
and split the package into a portable core and a macOS UI target. Both are
described above, both belong to macOS rather than to a port, and neither should
be attempted while also writing a second provider. Exit: the existing suite green
on macOS, and a core target that builds without SwiftUI.

**Both are worth doing whether or not this port ever happens**, the way
`INTEL.md`'s phase 0 was. Moving lifecycle behind the provider gets Apple Events
out of the app's middle, and separating the core from the view layer is ordinary
hygiene that happens to be a prerequisite. Neither is speculative work banked
against a port that may not start — which matters, because everything after this
phase is.

**1. Core port.** Everything in "What ports unchanged", plus the CNG signature
backend, building and passing its tests on Windows with no UI. Exit: the full
non-UI test suite is green on a Windows runner, on a host meeting the
requirements above.

**2. Provider.** `QemuBundleProvider` implementing the nine methods, writing a
bundle layout of its own, including the materials drive. Exit: bundle-format
regression tests pass and every row of the table above is asserted — the three
materials rows among them, plus an attach-then-repair test proving repair does
not undo the attach.

**3. One profile, end to end.** Ubuntu x86-64 only. Download, verify, provision,
boot, automatic poweroff, graphical login, offline reset, Internet reset, and
materials attached, mounted and visible on the desktop, detached, and **not**
resurrected by the next reset. Exit: a real boot smoke test, the same bar the
four ARM64 profiles had to clear.

**4. The other three profiles.** Fedora, Debian, openSUSE on x86-64, each with
its own qualification run, provenance record, and its own `materialsInterface`
confirmed against its own image rather than inherited from ARM64.

**5. Shell.** WinUI or Avalonia over the existing view model.

**6. Distribution.** Authenticode signing and SmartScreen reputation instead of
Developer ID and notarization. A Windows job in the release workflow. Note that
reputation accrues over time and downloads, so early builds will warn regardless
of correct signing — plan for that rather than being surprised by it.

## Open questions to settle first

- **Language for the core.** Swift on Windows is real but SwiftUI is not, and
  the toolchain story is thinner. A C# or Rust core with a hand-port of the
  guest profiles may ship sooner than a shared Swift core. Decide before
  phase 1; it is expensive to revisit. It is also testable rather than
  arguable — `GuestArchitectureTests` pins a digest a hand-port would have to
  reproduce byte for byte. See
  [core-language-spike.md](core-language-spike.md), and run it before phase 0,
  because the answer decides how much of phase 0 pays for itself.
- **Has any of this been run?** No. The hypervisor recommendation, the two
  network modes, and the acceleration story are all reasoned rather than
  observed. [windows-qemu-spike.md](windows-qemu-spike.md) checks the two that
  matter most in an afternoon, with QEMU alone and no Sandfort code. Do it before
  phase 0 — a wrong hypervisor found here costs a day, and found in phase 3 costs
  a phase.
- **Does WHPX work on Windows Home?** The reasoning under "Host requirements"
  says it should and cannot prove it. Check a Home machine early: the answer
  decides how much of consumer Windows the port reaches, and it is cheap to
  establish now and expensive to discover after phase 5.
- **What the first run says about WHPX.** The feature toggle and reboot are in
  the requirements table; what is open is the experience. WHPX has historically
  conflicted with other hypervisors and some anti-cheat, so decide what the app
  says when the feature is off, and what it says when it is on but something
  else holds the hypervisor.
- **Is an ARM64 Windows host in scope?** It is the only Windows configuration
  that could run the already-qualified ARM64 catalog. Decide it rather than
  letting the x86-64 phases answer by omission.
- **Does the app ship QEMU, or require it?** Sandfort requires UTM today and
  helps you find it. Bundling QEMU means owning its update cadence and its CVEs;
  requiring it means a worse first run. This is the biggest product decision in
  the plan.
- **Where instance disks live**, and whether roaming profiles or OneDrive
  redirection can put a 64 GiB sparse file somewhere that syncs.

## An optimization macOS already has for free, and Windows will not

Instance creation looks like a full byte copy and is not one. `FileManager.copyItem`
clones on APFS, so an instance shares the baseline's blocks until something
writes to them: 0.005 s and no measurable disk for a 5.68 GiB baseline bundle.
The `du` reading that suggested otherwise — 6.1G baseline plus 6.1G instance,
13G total — was the same 6.1G counted twice, because `du` counts blocks per file.
`security-model.md` has the measurement and the reasoning, and
`InstanceCloneCostTests` keeps it true.

**This is the one place in this document where Windows is genuinely worse off.**
NTFS has no clone: `CopyFile2` copies bytes. An instance there really would cost
a full copy of the baseline, in time and in space, on the filesystem the port
would actually ship on. ReFS has block cloning but is not what a user's C: drive
is formatted as, and the port cannot require it.

A QCOW2 **backing file** is the obvious answer and was rejected on macOS for
reasons that are not about cost: Rebuild deletes the baseline and would orphan
every instance depending on it, the guest's own hypervisor would hold a
reference to the protected baseline, and a running instance would lock it. None
of those become less true on Windows. If the copy proves unacceptable there,
solve it against those three objections rather than by reopening the decision —
and note that a Windows provider is free to use a different mechanism from the
macOS one, since each provider owns its own VM packaging.
