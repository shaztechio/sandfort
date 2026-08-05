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

**A `VirtualMachineProvider` implementation.** Seven methods, all of them about
packaging rather than provisioning:

```
createSetupBundle    createCleanBundle    resetCleanBundle
repairBundle         setDisplayName       ensureBundleNotRunning
identifier
```

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

**WSL2 is not a candidate.** Its entire design is host integration — drive
mounts, localhost forwarding, shared clipboard. That is the negation of the
guarantee, not a cheaper route to it.

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

Prove each one in tests, not by inspection. That is step 5 of
`adding-a-platform.md` and it is the actual gate.

## Phases

**1. Core port.** Everything in "What ports unchanged", plus the CNG signature
backend, building and passing its tests on Windows with no UI. Exit: the full
non-UI test suite is green on a Windows runner.

**2. Provider.** `QemuBundleProvider` implementing the seven methods, writing a
bundle layout of its own. Exit: bundle-format regression tests pass, and every
row of the table above is asserted.

**3. One profile, end to end.** Ubuntu x86-64 only. Download, verify, provision,
boot, automatic poweroff, graphical login, offline reset, Internet reset. Exit:
a real boot smoke test, the same bar the four ARM64 profiles had to clear.

**4. The other three profiles.** Fedora, Debian, openSUSE on x86-64, each with
its own qualification run and provenance record.

**5. Shell.** WinUI or Avalonia over the existing view model.

**6. Distribution.** Authenticode signing and SmartScreen reputation instead of
Developer ID and notarization. A Windows job in the release workflow. Note that
reputation accrues over time and downloads, so early builds will warn regardless
of correct signing — plan for that rather than being surprised by it.

## Open questions to settle first

- **Language for the core.** Swift on Windows is real but SwiftUI is not, and
  the toolchain story is thinner. A C# or Rust core with a hand-port of the
  guest profiles may ship sooner than a shared Swift core. Decide before
  phase 1; it is expensive to revisit.
- **WHPX prerequisites.** Enabling the Windows Hypervisor Platform needs a
  feature toggle and a reboot, and historically conflicted with other
  hypervisors and some anti-cheat. Decide what the first-run experience says.
- **Does the app ship QEMU, or require it?** Sandfort requires UTM today and
  helps you find it. Bundling QEMU means owning its update cadence and its CVEs;
  requiring it means a worse first run. This is the biggest product decision in
  the plan.
- **Where instance disks live**, and whether roaming profiles or OneDrive
  redirection can put a 64 GiB sparse file somewhere that syncs.

## An optimization worth taking on both platforms

Instance creation is a full byte copy today. Measured on the Debian environment:

```
Protected Baseline    on-disk 6.1G
Instance 1            on-disk 6.1G
environment total     13G
```

`FileManager.copyItem` does not clone on APFS, so this is not a macOS advantage
that Windows would fail to match — both platforms pay the same cost. A QCOW2
**backing file** would make instances near-free on either.

It is not free of consequence. A backing file is shared state between the
baseline and every instance derived from it, and the security model currently
forbids sharing mutable guest disks. Read-only backing is a weaker claim than a
full copy, and the decision belongs in `security-model.md` before it belongs in
code. Raise it as its own change, on macOS first, not as a detail of the Windows
port.
