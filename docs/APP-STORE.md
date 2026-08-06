# The Mac App Store: what it would actually take

Nothing here is built. This is a feasibility record, in the shape of
[INTEL.md](INTEL.md), [LINUX.md](LINUX.md), and [WINDOWS.md](WINDOWS.md).

The short version: **the blocker everyone expects is not the blocker.** Driving
another app through Apple Events looks disqualifying under App Sandbox and turns
out to be the one part UTM already solved deliberately. What actually stands in
the way is file access between two sandboxes, and a reviewer on a clean Mac.

Beyond that sits a larger question this document exists to frame rather than
settle: whether Sandfort should stop driving UTM at all.

## Apple Events are not the problem

`Sandfort.entitlements` requests `com.apple.security.automation.apple-events`.
That is a **hardened runtime** entitlement, and it is the right one for Developer
ID distribution — a notarized build without it installs, launches, and silently
never starts a VM. It is not the App Store mechanism, and its absence from a
sandboxed build would not be the reason a sandboxed build failed.

The App Store mechanism is `com.apple.security.scripting-targets`, and it works
only when the *target* app opts in by publishing scripting access groups. UTM
does, in `UTM.sdef`:

```xml
<suite name="UTM Suite" code="UTMs" description="UTM virtual machines scripting suite.">
    <access-group identifier="com.utmapp.UTM.vm-access" />
```

The group is declared at suite level, so it covers `start` (`UTMvstar`) and
`stop` (`UTMvstop`); `delete` (`coredelo`) additionally declares
`identifier="*"`. Those are exactly the three operations
`UTMRegistryController` performs.

UTM is itself sandboxed and carries `com.apple.security.virtualization`
(verified with `codesign -d --entitlements`), which is a strong signal it built
this path for App Store distribution rather than by accident.

So a sandboxed Sandfort would declare:

```xml
<key>com.apple.security.scripting-targets</key>
<dict>
    <key>com.utmapp.UTM</key>
    <array><string>com.utmapp.UTM.vm-access</string></array>
</dict>
```

No temporary exception, no case-by-case justification. **Unverified**: that this
grant actually delivers the three events in practice. It is cheap to test and
should be tested before anything else here is considered, because everything
downstream assumes it.

## Two things that are the problem

### 1. Two sandboxes cannot see each other's files

`SandboxLibrary` roots everything at
`~/Library/Application Support/Sandfort/`. Under App Sandbox that relocates into
Sandfort's container, and UTM — sandboxed in its own container — cannot read it.

`NSWorkspace.open` extends a sandbox extension to the receiving app for the item
opened, which covers the import. But UTM **registers** the VM and reopens it on
later launches, long after that extension is gone. Persistent access needs a
security-scoped bookmark held by UTM, for a bundle *directory* rather than a
file. Whether that works is the single unresolved question in this document.

If it does not, the fallback is asking the user to choose a location through an
open panel so Sandfort holds a bookmark to somewhere both apps can reach. That is
a real UX regression: the app currently needs no file prompts at all, and the
thing being chosen ("where should virtual machines live") is not a question a
first-run user has an opinion about.

### 2. A reviewer on a clean Mac sees an app that does nothing

Without UTM installed, Sandfort cannot create or launch anything. App Review
tests on a clean machine, and an app that appears inert is a 2.1 rejection
regardless of how good the reason is.

Mitigable — detect UTM's absence and link to it on the App Store — but it has to
be designed for, not discovered during review.

### What is *not* the problem, despite appearances

Guideline 2.5.2, on downloading and executing code, is weaker here than it looks.
UTM ships on the App Store and lets users run arbitrary guest operating systems.
Sandfort downloads four curated images, pinned by SHA-256, checked against
distribution OpenPGP signatures where published, from official vendor URLs. That
is a strictly narrower thing than what is already accepted.

Nothing else in the app needs an exception. Downloads are `URLSession`, disks and
ISOs are written with Foundation, there is no `osascript`, no shell out, no JIT.
The prohibition in [AGENTS.md](../AGENTS.md) against shell tooling — adopted for
other reasons entirely — happens to leave the app in good shape for this.

## The larger question: stop driving UTM

Every problem above dissolves if Sandfort hosts the VM itself through
Virtualization.framework with `com.apple.security.virtualization`. No Apple
Events, no second sandbox, no dependency, no reviewer confusion.

It is the most consequential change anyone could make to this codebase, and the
costs are not small.

**It is a second provider.** That makes the finding in [LINUX.md](LINUX.md)
load-bearing at last: starting, stopping, and unregistering a VM live outside
`VirtualMachineProvider`, so the contract has to grow first. It would also give
`identifier` — implemented as `"macos-arm64.utm-qemu"` and currently read by
nothing anywhere in `sources/` or `tests/` — something real to discriminate.

**Sandfort would have to become a VM viewer.** Today UTM owns every pixel the
user sees of a guest; `ContentView` is a control panel. Virtualization.framework
hands back a `VZVirtualMachineView` and the app owns display, input, resizing,
fullscreen, and the whole feel of using a sandbox. This is the largest hidden
cost and it is a product change, not a plumbing change.

**Running VMs would die with the app.** A `VZVirtualMachine` lives in the host
process. Today a sandbox outlives Sandfort, which is why quitting is safe; and
`AppLifecycle` deliberately terminates the app when its window closes, "the way
System Settings does". Those two facts are incompatible. Either that lifecycle
decision is reversed, or running VMs are killed on quit, or a helper process is
introduced — and a helper process is a third architecture, not a tweak.

**qcow2 has to become raw.** Virtualization.framework attaches raw disk images;
all four catalog images are qcow2, and `DiskUtilities.validateQCOW2Geometry`
already parses their headers. A converter means decoding L1/L2 tables and
writing clusters out — **new byte-level parsing code, in an app that has just
finished paying for exactly that class of bug.** The verifier findings in
[security-reviews/](security-reviews/) are the recent, specific reason to treat
this as expensive rather than routine. Sparse files on APFS keep the size
manageable; the parser is the cost, not the bytes. It would also foreclose the
qcow2 backing-file idea filed as its own issue.

**Every isolation guarantee changes its enforcement mechanism.** Today they are
plist keys another app reads. Under Virtualization.framework they become
"configuration objects Sandfort chose not to construct":

| Guarantee | Today | Virtualization.framework |
| --- | --- | --- |
| Offline | `IsolateFromHost: true` → `restrict=on` | attach no network device at all |
| Internet, no inbound | `Mode: "Emulated"`, `PortForward: []` | `VZNATNetworkDeviceAttachment` |
| No directory sharing | `DirectoryShareMode: "None"` | construct no file-system device |
| No clipboard sharing | `ClipboardSharing: false` | no such feature exists |
| No USB sharing | `UsbSharing: false` | construct no USB controller |
| Per-instance identity | UUID + random MAC in the plist | `VZMACAddress.randomLocallyAdministered()` |

Read that table twice, because it cuts both ways. Most guarantees become
*absences* rather than settings, which is a stronger position — you cannot
misconfigure a device you never created, and offline stops depending on trusting
`restrict=on`. But every one of them needs its regression assertion rewritten
against a different mechanism, and `docs/security-model.md` becomes a different
document.

## Phases, if it is ever pursued

**Phase 0 — prove the scripting-targets grant.** A day. Build a sandboxed
throwaway that declares `com.utmapp.UTM.vm-access` and sends `UTMvstar` to a VM
that already exists. If it fails, the App Store is closed to the current
architecture and the only remaining route is Virtualization.framework. Nothing
else here is worth doing first, and it is the cheapest question to answer.

**Phase 1 — settle the bundle-access question.** Whether UTM can persistently
reopen a VM bundle living in another app's container. Empirical, not readable
from documentation.

**Phase 2 — first-run UTM detection**, and a decision about linking to it.

**Phase 3 — a sandboxed build**, with the download, disk, ISO, and launch paths
exercised inside the container.

The Virtualization.framework track is not a phase of this. It is a separate
project that happens to also solve it, and it should be evaluated on whether
owning the VM is the right product, not on whether it gets past review.

## Open questions

- **Does the `scripting-targets` grant deliver `UTMvstar` in practice?** Phase 0.
- **Can UTM persistently reopen a bundle inside Sandfort's container?** If not,
  is a user-chosen shared location acceptable, or does that sink it?
- **Does UTM's App Store build behave identically?** The App Store version cannot
  use JIT, so its TCG emulation is limited or absent. Sandfort only ever runs
  native-architecture guests under the hypervisor, so this *should* be
  irrelevant — but "should" needs checking, and it interacts with
  [INTEL.md](INTEL.md), where an unaccelerable guest silently falls back to TCG.
- **Does the App Store's own update cadence break the pinned-image model?** The
  catalog pins immutable images by checksum; nothing about review changes that,
  but a release cycle gated on review is slower than the one in
  [releasing.md](releasing.md), and image URLs do eventually rot.
- **Is the sandbox container an acceptable home for tens of gigabytes?** Users
  cannot relocate it, and the deferred sizing plan raises the per-environment
  disk to 96 GiB.
- **What does this do to the qualification apps?** Four separately identified
  builds with isolated state are a development tool, not something to ship, but
  they would need to keep working outside the App Store build.

## A note on the entitlements comment

`tools/packaging/Sandfort.entitlements` currently ends with "Nothing else belongs
here. Sandfort is not App Sandboxed." That remains true and should stay true
until a decision is made — but the comment reads as though sandboxing were
settled rather than unexamined. If this document changes anyone's mind, that
comment is the first thing that needs rewriting, and it is worth keeping accurate
either way: it is the file a future maintainer reads when wondering why the app
is not on the App Store.
