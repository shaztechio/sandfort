# UTM version audit: what Sandfort's claims were established against

Sandfort drives an application it does not ship. Its isolation guarantees are
keys in a property list that UTM parses, and its launch path is an Apple Event
that UTM implements. Both are UTM's to change. This document records **which
UTM version each claim was established against**, so a claim that quietly
became a claim about an old version can be found rather than trusted.

Audit date: 2026-08-07. Issue #25. Revised the same day after UTM 5.0.4 was
installed; the first pass had only 4.7.5 available. Live-run addendum:
2026-08-08, using Sandfort 0.16.2 build 101 and UTM 5.0.4 build 123.

## The versions in play

| | Version | Status |
|---|---|---|
| Installed at `/Applications/UTM.app` | **5.0.4** build 123, `LSMinimumSystemVersion` 13.0 | GitHub **prerelease**, release name `v5.0.4 (Beta)` |
| Also present, mounted at `/Volumes/UTM/UTM.app` | **4.7.5** | `releases/latest` on `utmapp/UTM`, and the newest release **not** flagged prerelease |

Every 5.0.x release — 5.0.0, 5.0.1, 5.0.2, 5.0.3, 5.0.4 — is a GitHub
prerelease. `GET /repos/utmapp/UTM/releases/latest` still returns **v4.7.5**.
UTM 5 is a beta line, not the shipped stable line, and UTM's own 5.0.4 notes
tell users on older macOS to "stay on the last stable release of UTM 4". So
both versions still matter: 5.0.4 is what this machine runs, 4.7.5 is what a
user who takes UTM's own advice runs.

## Evidence classes

Every claim below is tagged with how it was established. The classes are not
interchangeable, and nothing in this document upgrades one to another. In
particular, **a file existing or a string appearing in a binary is not a
booted VM** — that distinction is the whole point of the split.

- **[V4] Verified against UTM 4.7.5** — inspected on a 4.7.5 install
  (build 118, and the 4.7.5 bundle still mounted at `/Volumes/UTM`).
- **[V5] Verified against installed UTM 5.0.4** — inspected on
  `/Applications/UTM.app`, build 123. Static inspection of a real shipped,
  signed build: its files, its binary's string table, its `.sdef`, its
  entitlements, its Launch Services registration.
- **[S] Read in UTM 5 source or release notes** — read at the `v5.0.4` tag in
  `utmapp/UTM`, cited by file. Source-reading tells you what the code says, not
  what a shipped build does.
- **[R5] Live-run verified on UTM 5.0.4** — exercised through Sandfort 0.16.2
  build 101 against UTM build 123. All four production profiles booted both
  offline and Internet-enabled, and their terminals and Visual Studio Code
  launched. This was a compatibility smoke pass, not every item in each
  profile's qualification matrix.
- **[L] Needs a live run** — requires actually creating a baseline, booting a
  VM, resetting an instance, or inspecting a runtime guarantee not covered by
  the recorded [R5] pass. Nothing moves out of this class on the strength of
  static inspection alone.

### A methodological warning about `strings -a`

Checking key names against a binary's string table has **false negatives**.
Of the 62 key names Sandfort writes, 60 appear as exact-match lines in both
binaries and **two do not** — `CPU` and `TSO`. Both are nonetheless declared
in UTM 5.0.4's source (`UTMQemuConfigurationSystem.swift:51`,
`UTMQemuConfigurationQEMU.swift:89`), so the misses are artifacts of how short
Swift literals are emitted, not missing keys.

Two consequences, and the second is the important one:

1. Never report a strings-based key sweep as "all N present" without
   cross-checking every miss against source. A sweep that reports no misses at
   all is more likely to be a broken pattern than a clean result — `grep -E`
   does not understand `\s`, and a pattern that silently matches almost
   nothing will still happily print a pass.
2. **The authoritative evidence for key names is the byte-identical
   `Configuration/` source diff in §1, not the binary sweep.** The sweep is
   corroboration with known blind spots.

## 1. The isolation plist keys

This is the one that matters. `UTMBundleBuilder.writeConfiguration` and
`repairBundle` enforce the security model by writing keys into `config.plist`.
If UTM renamed one, UTM would fall back to its own default, Sandfort would
still write the old key, and every test would still pass — because the tests
assert what Sandfort *writes*, not what UTM *reads*. A renamed key is a
silently removed guarantee.

**Result: no key Sandfort writes changed between 4.7.5 and 5.0.4.**

[S] The strongest evidence, and the reason this is settled rather than merely
suggestive: the declaring source files are **byte-identical** between the
`v4.7.5` and `v5.0.4` tags. Fetched both tags and diffed:

| File | 4.7.5 → 5.0.4 |
|---|---|
| `Configuration/UTMQemuConfigurationNetwork.swift` | identical |
| `Configuration/UTMQemuConfigurationSharing.swift` | identical |
| `Configuration/UTMQemuConfigurationInput.swift` | identical |
| `Configuration/UTMQemuConfigurationDisplay.swift` | identical |
| `Configuration/UTMQemuConfigurationDrive.swift` | identical |
| `Configuration/UTMQemuConfigurationSystem.swift` | identical |
| `Configuration/UTMQemuConfigurationQEMU.swift` | identical |
| `Configuration/UTMQemuConfigurationSerial.swift` | identical |
| `Configuration/UTMQemuConfigurationPortForward.swift` | identical |
| `Configuration/UTMConfiguration.swift` | identical |
| `Configuration/UTMConfigurationDrive.swift` | identical |
| `Configuration/UTMConfigurationInfo.swift` | identical |
| `Configuration/UTMQemuConfiguration.swift` | identical |
| `Configuration/UTMQemuConfiguration+Arguments.swift` | **changed** — see §3 |

The four load-bearing ones, still spelled exactly as Sandfort spells them:

- `IsolateFromHost` — `UTMQemuConfigurationNetwork.swift:95`
- `PortForward` — `UTMQemuConfigurationNetwork.swift:96`
- `DirectoryShareMode` — `UTMQemuConfigurationSharing.swift:34`
- `DirectoryShareReadOnly` — `UTMQemuConfigurationSharing.swift:35`
- `ClipboardSharing` — `UTMQemuConfigurationSharing.swift:36`
- `UsbSharing` — `UTMQemuConfigurationInput.swift:32`
- `MaximumUsbShare` — `UTMQemuConfigurationInput.swift:33`
- `UsbBusSupport` — `UTMQemuConfigurationInput.swift:31`

[S] `ConfigurationVersion` is still `4` at both tags
(`UTMConfiguration.swift:34`, `static var currentVersion: Int { 4 }`), so the
bundles Sandfort writes are not "too old" or "too new" for UTM 5. UTM rejects a
config whose version it does not know, with `versionTooLow` / `versionTooHigh`;
neither applies.

[V5] Corroborated against the shipped binary, with the caveat above: 60 of the
62 key names appear as exact-match strings in `/Applications/UTM.app`'s
executable, and the two that do not (`CPU`, `TSO`) are present in source.
Identical result against the 4.7.5 binary — same 60, same 2. Sixty-one of the
62 are keys Sandfort writes; `Removable` is one it *deletes* in `repairBundle`.

[V5] **The enum values are present too**, which the first pass did not check
and should have — a renamed value is exactly as silently breaking as a renamed
key. All 12 that Sandfort writes into value positions appear in both binaries:
`QEMU`, `Disk`, `VirtIO`, `Emulated`, `None`, `Terminal`, `Auto`, `Linear`,
`Nearest`, `virtio-gpu-pci`, `virtio-net-pci`, `default`. `None` is the one
that matters most — it is the value that turns directory sharing off.

[L] That a shipped UTM 5.0.4 honours those keys **at boot**. Every check above
is static. A key that is present in the binary and spelled correctly in the
plist can still be ignored, overridden by a cached configuration, or applied to
a device that is not the one the guest ends up using. The concrete check is
item 2 in §7.

[R5] The offline and Internet-enabled network modes behaved as selected for all
four profiles. The pass did not record UTM's settings UI for directory,
clipboard, USB, or port-forward state, so it does not close the broader key
inspection above.

**No security finding.** Had a key moved, this would have been filed as its own
issue rather than a documentation edit. It did not.

## 2. `utm://start?name=` and the Apple Event codes

`docs/security-model.md` records that `utm://start?name=` is a no-op, which is
why launch goes through registration polling plus the `UTMvstar` Apple Event.
That was measured against 4.7.5.

[V4] Measured on 4.7.5: opening the URL against a registered, stopped VM left
it stopped.

[S] The finding is not version-specific, and the source explains why. UTM's URL
handler is `Platform/Shared/ContentView.swift`, `handleURL(url:)` at line 146,
reached from `.onOpenURL(perform: handleURL)` at line 61. It accepts exactly
two things:

- `utm://downloadVM?url=…`
- a file URL, which it imports

There is no `start` case, at either tag. **The file is byte-identical between
`v4.7.5` and `v5.0.4`.** `utm://start` does nothing on 5.0.4 for the same
reason it does nothing on 4.7.5: UTM never implemented it. The two-step
open-then-Apple-Event launch path remains the only mechanism.

One wording correction follows from this: the code comments described the URL
as "documented by UTM" but broken. It is more accurate to say UTM's macOS URL
handler implements only `downloadVM` and file import.

[S] The Apple Event codes are unchanged. `Scripting/UTM.sdef` was modified
between the tags (+27/−4), and the diff contains **no change to any code
Sandfort sends**:

- `start` = `UTMvstar` — unchanged
- `stop` = `UTMvstop`, parameter `by` = `StBy`, enumerator `request` = `ReQu` —
  unchanged
- `delete` = `coredelo` — unchanged
- the `com.utmapp.UTM.vm-access` access group — unchanged

The whole sdef diff is three typo fixes, one new command, and five new
properties. `Scripting/UTMScriptingVirtualMachineImpl.swift` gained
`reloadConfiguration` and an ARP-based `queryIp` for the Apple backend; the
`start`, `stop`, and `delete` implementations are untouched — `delete` still
calls `data.delete(vm: box, alsoRegistry: true)` with no added confirmation.

[V5] Confirmed in the **shipped** 5.0.4 dictionary,
`/Applications/UTM.app/Contents/Resources/UTM.sdef`. Not a tag — the file the
installed app actually publishes:

- `start` = `UTMvstar`, line 62
- `stop` = `UTMvstop`, line 79; `by` = `StBy`, line 81; `request` = `ReQu`, line 53
- `delete` = `coredelo`, line 86
- 8 `access-group` declarations, 6 of them `com.utmapp.UTM.vm-access`
- `reload configuration` = `UTMcReLd`, line 415 — the new command, as read in source

[L] That these commands *do the thing* when sent to a running 5.0.4. A code in
a dictionary is an interface UTM advertises, not an interface Sandfort has
exercised. A wrong or unhandled code is silently ignored rather than reported,
which is exactly how the URL scheme failed — so this class of claim cannot be
closed by reading the dictionary. Items 4 and 6 in §7.

[R5] Sandfort's normal launch path started all four profiles in both network
modes. A cold-UTM launch, polite stop, and delete/rebuild lifecycle were not all
recorded as part of that smoke pass.

[L] That a *notarized* Sandfort build's Apple Events reach a shipped UTM 5
under the hardened runtime and the current Automation prompt.

## 3. The graphics-backend rewrite and `virtio-gpu-pci`

UTM 5's headline feature is Venus/Vulkan and DirectX-over-Metal. Sandfort
writes `Hardware = virtio-gpu-pci` into every instance display.

[S] **The rewrite does not reach Sandfort's display, and the reason is precise.**
Every new code path in `UTMQemuConfiguration+Arguments.swift` is gated on a
single predicate added at that tag:

```swift
private func isDisplayGLSupported(_ display: UTMQemuConfigurationDisplay) -> Bool {
    display.hardware.rawValue.contains("-gl-") || display.hardware.rawValue.hasSuffix("-gl")
}
```

`virtio-gpu-pci` contains neither `-gl-` nor a `-gl` suffix. So for a Sandfort
bundle:

- `isDisplayGLSupported` is false, therefore `isGLSupported` is false
- `glBackend` returns `"off"`, so SPICE is started with `gl=off`
- `isVulkanSupported` and `isNeptuneSupported` are both false
- none of `hostmem=8G`, `blob=true`, `venus=true`, `neptune=true` is emitted
- the new `ipa-granule-size=0x1000` hypervisor argument is not emitted

`virtio-gpu-pci` itself is still a declared display device at `v5.0.4`
(`Configuration/QEMUConstantGenerated.swift:6482`), and that generated file is
unchanged between the tags despite QEMU moving from 10.0.2 to 10.0.12.

[V5] `virtio-gpu-pci` is present in the shipped 5.0.4 binary, and the rewrite
did ship: `Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app`
exists in the installed bundle, which is the new out-of-process renderer that
5.0.4 added. So this is not a case of reading source for a feature that was
cut — the feature is there, and the gating predicate is what keeps it away from
Sandfort's display.

[R5] `virtio-gpu-pci` rendered a usable GNOME desktop for all four profiles
under 5.0.4; each profile's terminal and Visual Studio Code launched. This is
the runtime evidence the device string alone could not provide. Item 7 in §7.

**This is worth keeping true deliberately, not by accident.** Switching the
display to a `-gl` variant would, on UTM 5, silently opt every sandbox into a
host GPU acceleration path with an 8 GiB host memory window — new attack
surface between guest and host, acquired through a one-word configuration
change. `UTMDisplayHardwareTests` now asserts the non-GL spelling for exactly
this reason.

[S] One caveat that is *not* display-gated. `UTMQemuVirtualMachine.swift:355`
now runs `system.vulkanDriver = try vulkanDriver` unconditionally at start, and
that getter throws `vulkanNotCompatible` or `vulkanVersionNotSupported` for
some combinations of UTM's **global** `QEMURendererBackend` and
`QEMUVulkanDriver` user defaults. Stock defaults pass. A user who has changed
UTM's renderer settings could see a start failure that has nothing to do with
their VM's configuration. [L] to confirm, and only reachable via non-default
UTM settings.

## 4. Minimum UTM version

The issue asks whether the documented minimum should be raised. **There is no
documented minimum, and no enforced one.**

[V4] [V5] `UTMLauncher.resolveInstallation` reads `CFBundleShortVersionString`
and `doctor()` reports it — `SandfortWorkflow.swift:206`. Nothing compares it to
a floor. `README.md` says "Install UTM" with no version. `HELP.md` mentions only
which version Sandfort can see.

Recommendation, on the evidence in this document: **do not introduce one yet.**

- 4.7.5 is UTM's current stable release. Requiring 5.x would mean requiring a
  beta, which UTM's own release notes advise some users against.
- Every interface Sandfort depends on is unchanged in 5.0.4 — by source, and
  corroborated against the shipped 5.0.4 build — so there is nothing to raise a
  floor *for*.
- Neither direction excludes anyone. Sandfort's floor is macOS 13. UTM 4.7.5
  declares `LSMinimumSystemVersion` 11.3 [V4]; UTM 5.0.4 declares 13.0 [V5] —
  exactly Sandfort's own floor, so UTM 5's raised requirement cannot exclude a
  Mac that already runs Sandfort.

The version worth stating in documentation is not a minimum but a
**verified-against**, and it is now two: static compatibility confirmed against
4.7.5 and 5.0.4, full runtime qualification against 4.7.5, and the scoped [R5]
runtime smoke pass against 5.0.4.

### The resolver pins nothing, and that is now demonstrably a hazard

Not a version question, but found while answering one, and it outranks the
version question in practice.

[V5] Sandfort resolves UTM **by bundle identifier alone**
(`NSWorkspace.urlForApplication(withBundleIdentifier: "com.utmapp.UTM")`), with
no version comparison and no path pin. On this machine that identifier
currently resolves to **two** live bundles:

```
urlForApplication  -> /Applications/UTM.app   5.0.4
urlsForApplications:  /Applications/UTM.app   5.0.4
                      /Volumes/UTM/UTM.app    4.7.5   ← mounted installer DMG
```

Launch Services picks 5.0.4 today. Nothing guarantees it always will, and the
second bundle arrived through the most ordinary action there is: leaving the
installer disk image mounted after upgrading. Trashed copies linger in the
Launch Services database too — `~/.Trash/UTM-4.7.5.app` and `~/.Trash/UTM.app`
are both still registered.

Two consequences:

- Sandfort could drive a different UTM than the user believes, and the UI
  surfaces the version only in `doctor()`, which nobody runs by habit.
- `Installation.firmwareURL` is derived from whatever was resolved. If that is a
  mounted DMG, baseline creation reads `edk2-arm-vars.fd` from a **read-only
  volume the user can eject at any moment**.

This is a behaviour question, not a documentation one, so it is filed as
issue #35 rather than fixed here. Recorded because it is verified, not
hypothesised.

## 5. Things UTM 5 adds that Sandfort may want later

Not adopted here — recorded so they are not rediscovered.

[S] `reload configuration` (`UTMcReLd`), new in 5.0.4, described in UTM's sdef
as being for when "the `.utm` bundle has been modified externally (e.g. by an
automation tool) and UTM's cached configuration needs to be refreshed."

That describes Sandfort exactly. `repairBundle` reasserts isolation by writing
`config.plist` underneath a bundle UTM may already have registered and cached.
Today the app relies on unregistering before recreating; on UTM 5 there would
be an explicit way to force a reload. It is also an admission from upstream
that a cached configuration *can* diverge from the file on disk — which is
worth confirming for 4.7.5 too, since that risk is not new. See §7.

[S] `isolate from host` (`IsFh`) is now settable through the scripting
interface as a `qemu configuration` property. Sandfort sets it by writing the
plist. No change proposed; noted because it is a second, UTM-blessed route to
the single most important guarantee in the security model.

[S] `Platform/UTMData.swift` now identifies an already-known VM by
`fileResourceIdentifier` (inode) rather than by standardized path, to stop
duplicate library entries. Sandfort recreates bundles externally, so how UTM 5
treats a bundle recreated at a known path is worth a live check. [L]

[R5] A related cache split was observed during **Delete Environment**. UTM had
imported Ubuntu's setup VM under its `Baseline Setup` name; after Sandfort
rewrote `config.plist` to label the same bundle `Protected Baseline`, UTM kept
the imported name in its open library. Sandfort 0.16.2 asked UTM to delete only
the new name, accepted “not found” as already removed, then deleted its local
state. The baseline registration was left orphaned in UTM. Sandfort now persists
the imported setup name and, for existing state, reconstructs it from the
environment's unique tag; Rebuild and Delete Environment remove both exact
names before local data. This fix still needs a live re-check against 5.0.4.

### `docs/APP-STORE.md`'s premises still hold

That document reasons from two facts about UTM 4.7.5's code signature. Both
were re-checked against the installed 5.0.4 rather than assumed forward.

[V5] `codesign -d --entitlements -` on `/Applications/UTM.app` reports
`com.apple.security.app-sandbox` **true** and
`com.apple.security.virtualization` **true**, alongside
`application-groups`, `device.usb`, `device.audio-input`,
`files.user-selected.read-write`, `network.client`, and `network.server`.

[V5] The scripting access group `com.utmapp.UTM.vm-access` is declared 6 times
across 8 `access-group` elements in the shipped 5.0.4 dictionary — so the
finding that a sandboxed app could target UTM via
`com.apple.security.scripting-targets`, rather than needing a temporary
exception, survives into UTM 5. No change to `APP-STORE.md` is needed; this
paragraph is the record that its foundations were re-checked.

## 6. The firmware file

`UTMLauncher.Installation.firmwareURL` reads
`Contents/Resources/qemu/edk2-arm-vars.fd` out of UTM's own bundle, and
`createSetupBundle` fails with `utmResourcesMissing` if it is absent. This is a
hard dependency on UTM's internal layout.

This was the first pass's highest-consequence open question. **It is now
answered, and the answer is that nothing moved.**

[V4] Present in 4.7.5 at that exact path, 329,216 bytes.

[V5] **Present in installed 5.0.4 at the identical path, identical size** —
`/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd`, 329,216
bytes. The whole firmware set is intact and byte-for-byte the same sizes as
4.7.5, checked rather than assumed: `edk2-aarch64-code.fd` and
`edk2-aarch64-secure-code.fd` and `edk2-arm-code.fd` at 67,108,864;
`edk2-arm-secure-vars.fd` at 340,992; `edk2-i386-vars.fd` at 328,704;
`edk2-i386-code.fd`, `edk2-i386-secure-code.fd`, `edk2-x86_64-code.fd` and
`edk2-x86_64-secure-code.fd` at 3,653,632. The last four matter to
`docs/INTEL.md`, which assumes them.

[S] The `patches/data` disappearance was therefore what it looked like:
superseded build inputs, not a decision to stop shipping firmware. Recording
the resolution because the inference was flagged as an inference, and it
happened to be right — which is not the same as having been safe to rely on.

[L] That a baseline **built from this firmware actually boots** under 5.0.4.
The file being present and the right size is not the same as UEFI variables
that a guest initialises and reuses across a reset. Items 1 and 3 in §7.

## 7. What the live run established and what remains

The 2026-08-08 [R5] pass established that every production profile boots in
both network modes and provides a usable desktop, terminal, and Visual Studio
Code under UTM 5.0.4. It did not repeat every qualification step. Static
evidence remains static, and unrecorded runtime guarantees remain open.

The one item that static inspection *did* close is the old #1, the firmware
path (§6). The rest stand, renumbered.

1. **A baseline builds and boots.** Create an environment under 5.0.4 and run
   setup to completion. Exercises the firmware, the seed ISO, the serial
   console, and cloud-init in one go (§6).
2. **The isolation keys at runtime.** With a clean instance running, confirm in
   UTM's own settings UI that network isolation is on, directory sharing is
   None, clipboard sharing is off, USB sharing is off, and no port forward
   exists. Reading the plist back is *not* sufficient — the question is what
   UTM did with it (§1). This is the item the whole security model rests on.
3. **The offline guarantee end to end — smoke-pass complete.** [R5] All four
   profiles ran without Internet and with Internet when selected. The full
   settings inspection in item 2 remains separate.
4. **Launch — normal path complete, cold UTM remains.** [R5] The
   open-register-poll-`UTMvstar` sequence started all four profiles. A launch
   beginning with UTM closed was not recorded (§2).
5. **`utm://start` on 5.0.4.** Expected to remain a no-op, now with a source
   explanation. Cheap to confirm while 5.0.4 is installed.
6. **Stop and delete.** `UTMvstop`/`ReQu` powers a guest down politely, and
   Rebuild's `coredelo` still unregisters by exact name (§2).
7. **`virtio-gpu-pci` renders — complete.** [R5] All four GNOME desktops were
   usable enough to launch their terminals and Visual Studio Code (§3).
8. **Bundle re-registration.** Reset an instance and confirm UTM 5 does not end
   up with a duplicate or stale library entry, given the new inode-based
   identity check. Also re-check the two-name baseline cleanup fix (§5).
9. **Config caching — name caching observed, policy caching remains.** [R5] UTM
   retained the baseline's imported name after Sandfort rewrote its display
   name. Whether UTM also caches isolation policy changed by `repairBundle`
   remains open and is the higher-consequence question (§5).
10. **A non-default renderer backend.** Only when reproducing a user report:
    whether UTM's global Vulkan/renderer defaults can fail a start for a
    non-GL VM (§3).

The honest statement is now narrower: **Sandfort's UTM 5 compatibility is
established statically, and boot, network-mode selection, desktop rendering,
terminal launch, and Visual Studio Code launch are verified across all four
profiles on 5.0.4. The full isolation and lifecycle qualification remains
verified against 4.7.5 only.**

## 8. The materials drive

Added after the audit's first pass, and the only claim here established by a
**live run** rather than by reading.

**Verified against UTM 5.0.4 on all four profiles, 2026-08-08 and 2026-08-09.**
A third `Drive` entry with `ImageType: "CD"`, `InterfaceVersion: 1`,
`ReadOnly: true`, and an image inside the bundle is accepted everywhere, and the
contents are readable in every guest. Presentation and transport differ:

| Profile | Interface | In GNOME Files |
| --- | --- | --- |
| Ubuntu 24.04 | `SCSI` | CD in the sidebar |
| openSUSE Leap 16 | `SCSI` | CD in the sidebar |
| Debian 13 | `SCSI` | listed, no sidebar CD |
| Fedora 44 | `USB` | listed as a CD |

openSUSE additionally needed `gvfs-backends` installed explicitly. Without it the
disc enumerated as `/dev/sr0` and the desktop offered nothing at all, because
core `gvfs` does not carry the udisks2 volume monitor. That is a guest packaging
gap, not a UTM behaviour.

The Ubuntu run below was the original, taken with `Interface: "USB"`:

- UTM accepts the bundle and does not reorder or renumber the existing two drives.
- The guest exposes an ISO 9660 volume labelled `SANDFORT_MATERIALS`.
- GNOME Files shows it in the sidebar as a CD.
- A **newly attached** drive is picked up by Resume with UTM already running —
  no quit, no re-import.

**UTM caches a VM's configuration, and it caches an addition as readily as an
edit.** Verified 2026-08-09: an instance whose `config.plist` held
`materials.iso` as a SCSI CD, with the image in `Data/` and the store copy
intact, resumed with no disc in the guest while UTM was running. Quitting UTM and
resuming the same instance produced it, with nothing else changed.

An in-place *edit* behaves the same way — changing this entry's interface from
`USB` to `SCSI` left UTM's own settings reporting `CD/DVD (ISO) Image (USB)`
until the app was quit and relaunched.

**This section has now been wrong twice, in opposite directions.** It first
claimed "no cache to defeat". It was then corrected to say that an *addition* is
picked up on Resume and only an *edit* is cached — a distinction drawn from a
single Ubuntu run that happened to follow a UTM restart, and which two later
observations contradicted. There is no add/edit distinction: what varies is
whether UTM has re-read the bundle since the change.

The lesson is about method rather than UTM. Both wrong versions came from
generalising a mechanism out of one successful observation, and both survived
because the success is indistinguishable from a correct implementation. A claim
about caching needs the negative case — the same instance failing, then
succeeding after a restart, with nothing else altered.

So: **an instance whose drives changed needs UTM to re-read the bundle.** Reset &
Run Clean is exempt, because it deletes the registration and rebuilds the bundle.

### `reload configuration` (`UTMcReLd`) — new in 5.0.4

UTM 5.0.4 adds a command for exactly this: *"Reload the configuration of the
virtual machine from disk, discarding any unsaved in-memory changes. Useful when
the .utm bundle has been modified externally (e.g. by an automation tool) and
UTM's cached configuration needs to be refreshed. The VM must be in the stopped
state."*

Note the event class differs from the VM commands: `UTMc`, not `UTMv`.

**Version support, read from each tag's `Scripting/UTM.sdef`:**

| Tag | `UTMcReLd` |
| --- | --- |
| v4.7.5 | absent |
| v5.0.0 – v5.0.3 | absent |
| v5.0.4 | **present** |

4.7.5 is still the newest release **not** flagged prerelease, so most installs
will not have this. Sandfort treats it as an optimisation with a fallback and
never as a requirement — see §4 on the minimum version.

**Verified against UTM 5.0.4 on 2026-08-09.** With UTM running throughout, a
materials image was attached to a stopped instance; the app reported that UTM had
re-read it; resuming that instance — without quitting UTM — showed the disc in
the guest with the expected contents.

That is the whole claim, end to end: the command is understood, it refreshes the
drive list rather than merely returning success, and the drive reaches the guest.
Worth stating explicitly because this section has already carried two claims that
were wrong from exactly the gap between reading a dictionary and running it.

Still unverified: the 4.7.5 fallback. It is inferred from the command's absence
in that tag's `sdef`, not observed, and the app has no 4.7.5 to test against on
this machine. The consequence of being wrong is small — the user is told to quit
UTM when they might not have needed to — but it is inference, not evidence.

The drive is deliberately not marked external: in UTM that means the image lives
outside the bundle with a security-scoped bookmark, which is the opposite of what
materials are.

**USB does not work on every guest, and the interface changed because of it.**
On Debian the drive was never enumerated: `lsblk -f` reported the VirtIO seed as
`vdb iso9660 CIDATA` and no optical device at all. openSUSE showed nothing
either. The interface is now `SCSI`, which keeps the drive as removable optical
media while using the transport these kernels already use for the root disk.
**Re-run against SCSI on Ubuntu 24.04, after quitting UTM:** the drive is listed
as SCSI in UTM's own settings, the guest exposes it, and GNOME Files shows it as
a CD with the expected contents. **Debian 13, with SCSI, after quitting UTM:** UTM lists
the drive, the guest enumerates `sr0`, the volume appears in Files, and its
contents are correct. It does **not** get a sidebar icon the way Ubuntu does.
That is a desktop presentation difference, not a drive one: both guests enumerate
the same device from an identical configuration.

Observed, per distribution:

| | Interface | Sidebar icon | In Files | Opening it |
| --- | --- | --- | --- | --- |
| Ubuntu 24.04 | SCSI | yes | yes | opens |
| Debian 13 | SCSI | no | yes | opens |
| openSUSE Leap 16 | SCSI | no | *pending revision 6* | *pending revision 6* |
| Fedora 44 | USB | no | yes, as a CD | opens |

All four now reach the image. Two findings are not about the drive at all:

- **openSUSE shipped no file manager.** `patterns-gnome-gnome` declares no
  recommends, and this was the third omission of that shape after the browser and
  the terminal. `sr0` was present; there was simply nothing to click with.
  Revision 6 installed `nautilus`, `gvfs`, and `udisks2`, and was **still not
  enough**: Files opened but showed no removable media, because core `gvfs` does
  not carry the udisks2 volume monitor. Revision 7 adds `gvfs-backends`.

  Four separate omissions from one pattern — browser, terminal, file manager,
  volume monitor — each found only by a user looking for something that was not
  there. The setup verification now checks for the monitor binary rather than the
  package name, so a fifth fails during setup instead of after a rebuild.

  Note also that GNOME 45 removed "Other Locations" from Files, so guidance
  written against older GNOME sends people looking for a menu that no longer
  exists; volumes appear directly in the sidebar.
- **Fedora took three interfaces to place.** SCSI leaves the controller unbound
  (no `sym53c8xx`). VirtIO works but is an internal system drive, so mounting
  prompts for the sandbox password. USB emits `usb-storage` with
  `removable=true` and `usb_storage` *is* present. Confirmed in a booted VM: the
  image mounts in Files as a CD, without the polkit prompt VirtIO required.
- Fedora was never tried on USB during the original round: the switch to SCSI
  happened before its materials were first attached, and USB was ruled out from
  Debian's failure alone.

**Still needs a live run:**

- Whether the volume auto-mounts or requires the click.
- That `ReadOnly: true` reaches QEMU as a genuinely read-only device — writing to
  the mounted volume must fail. Note the stronger guarantee, that the user's
  original file is untouchable, does not depend on this at all: the guest is
  handed an image built from a copy.
- UTM 4.7.5. The drive was only ever exercised against 5.0.4.

Fedora, Debian, and openSUSE were on this list and have since had live runs; the
results are in the table above. openSUSE took three attempts, and none of the
three failures were the drive — they were the guest's desktop packaging.

## 9. The distribution icon

`Information.Icon` names one of the 69 icons UTM ships in
`Contents/Resources/Icons`, as a **bare resource name with no extension** —
`"ubuntu"`, not `"ubuntu.png"`. UTM resolves it with
`Bundle.main.url(forResource:withExtension:"png",subdirectory:"Icons")`, and
`IconCustom: false` says it is one of UTM's rather than a file in the bundle.

**Verified against UTM 5.0.4 on 2026-08-09.** All four distributions render their
own icon in the UTM library list, on baselines and instances alike. Existing VMs
picked the icon up through `repairBundle` on the next state read, with no
rebuild, no re-import, and no UTM restart — so the retrofit path is confirmed and
not just the creation path.

The four files `ubuntu.png`, `fedora.png`, `debian.png`, and `opensuse.png` were
confirmed present in the installed app first, and `Information.Icon` was read in
UTM 5.0.4's source.

Note that a `strings` sweep of Sandfort's own binary **cannot** confirm the icon
names are compiled in: `"ubuntu"`, `"Icon"`, and `"IconCustom"` are all at or
under 15 UTF-8 bytes and are therefore stored inline by Swift's small-string
optimization rather than in the string table. An empty grep here means nothing.
Same false negative recorded in §1 and §7.

**The icon names are not the same across versions**, which the original entry
missed by checking only the installed 5.0.4:

| Icon file | 4.7.5 | 5.0.4 |
| --- | --- | --- |
| `ubuntu.png`, `fedora.png`, `debian.png` | present | present |
| `opensuse.png` | **absent** | present |
| openSUSE's actual file | `suse.png` | `SUSE.png` |

So `opensuse` gave every 4.7.5 install a generic openSUSE icon. Found by running
against a pinned 4.7.5 — the live verification that "all four icons render" was
done on 5.0.4, and the one distribution whose name differs is the one it could
not have caught.

The profile now carries candidates in preference order and the bundle writer
picks the first the installed UTM ships, by exact filename. Note that
`fileExists` is not sufficient: the default APFS volume is case-insensitive, so
it answers yes for `suse.png` when the file is `SUSE.png`, and a check built on
it would fail only on a case-sensitive volume.

## Reproducing this audit

Nothing here needs UTM 5 installed.

```sh
# Release status and dates
gh api repos/utmapp/UTM/releases --jq '.[] | "\(.tag_name) prerelease=\(.prerelease)"'
gh api repos/utmapp/UTM/releases/latest --jq .tag_name

# What actually changed between the tags
gh api repos/utmapp/UTM/compare/v4.7.5...v5.0.4 \
  --jq '.files[] | "\(.status)\t\(.filename)"'

# The scripting dictionary diff
gh api repos/utmapp/UTM/compare/v4.7.5...v5.0.4 \
  --jq '.files[] | select(.filename=="Scripting/UTM.sdef") | .patch'

# Any configuration file, at either tag
curl -sfL https://raw.githubusercontent.com/utmapp/UTM/v5.0.4/Configuration/UTMQemuConfigurationSharing.swift

# The installed version's own answer
defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString
defaults read /Applications/UTM.app/Contents/Info.plist LSMinimumSystemVersion

# Shipped scripting dictionary and entitlements
grep -nE 'code="(UTMvstar|UTMvstop|coredelo|StBy|ReQu)"' \
  /Applications/UTM.app/Contents/Resources/UTM.sdef
codesign -d --entitlements - --xml /Applications/UTM.app | plutil -p -

# Every bundle claiming the identifier Sandfort resolves by. Two is a hazard,
# not a curiosity: see §4.
mdfind "kMDItemCFBundleIdentifier == 'com.utmapp.UTM'"
```

The key sweep is deliberately not a one-liner. It unions two extraction
patterns, because the builder writes keys both as dictionary literals and via
subscript, and it must cross-check any miss against source rather than
reporting a count. See §"A methodological warning" — a sweep that reports a
clean pass is the failure mode to distrust.
