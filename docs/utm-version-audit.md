# UTM version audit: what Sandfort's claims were established against

Sandfort drives an application it does not ship. Its isolation guarantees are
keys in a property list that UTM parses, and its launch path is an Apple Event
that UTM implements. Both are UTM's to change. This document records **which
UTM version each claim was established against**, so a claim that quietly
became a claim about an old version can be found rather than trusted.

Audit date: 2026-08-07. Issue #25.

## The versions in play

| | Version | Status |
|---|---|---|
| Installed on the audit machine | **4.7.5** | `releases/latest` on `utmapp/UTM`, and the newest release **not** flagged prerelease |
| Newest tag | **5.0.4**, 2026-08-01 | GitHub prerelease, release name `v5.0.4 (Beta)` |

Every 5.0.x release — 5.0.0, 5.0.1, 5.0.2, 5.0.3, 5.0.4 — is a GitHub
prerelease. `GET /repos/utmapp/UTM/releases/latest` still returns **v4.7.5**.
UTM 5 is a beta line, not the shipped stable line, and UTM's own 5.0.4 notes
tell users on older macOS to "stay on the last stable release of UTM 4".

That matters for the rest of this document: the version most Sandfort users
have is the version everything here was measured against.

## Evidence classes

Every claim below is tagged with how it was established. The three classes are
not interchangeable, and nothing in this document upgrades one to another.

- **[V] Verified on 4.7.5** — run, read, or inspected on the installed
  `/Applications/UTM.app` (`CFBundleShortVersionString` 4.7.5, build 118).
- **[S] Read in UTM 5 source or release notes** — read at the `v5.0.4` tag in
  `utmapp/UTM`, cited by file. Source-reading tells you what the code says, not
  what a signed, shipped build does.
- **[L] Needs a live check on UTM 5** — cannot be settled without installing
  UTM 5 and booting a VM. Nothing was installed for this audit.

## 1. The isolation plist keys

This is the one that matters. `UTMBundleBuilder.writeConfiguration` and
`repairBundle` enforce the security model by writing keys into `config.plist`.
If UTM renamed one, UTM would fall back to its own default, Sandfort would
still write the old key, and every test would still pass — because the tests
assert what Sandfort *writes*, not what UTM *reads*. A renamed key is a
silently removed guarantee.

**Result: no key Sandfort writes changed between 4.7.5 and 5.0.4.**

[V] All 38 key names Sandfort writes appear as literal strings in the installed
4.7.5 `UTM` binary.

[S] The declaring source files are **byte-identical** between the `v4.7.5` and
`v5.0.4` tags. Fetched both tags and diffed:

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

[L] That a shipped, signed UTM 5.0.4 build honours those keys at boot. Source
identity is strong evidence and not proof of runtime behaviour. The concrete
check is in §7.

**No security finding.** Had a key moved, this would have been filed as its own
issue rather than a documentation edit. It did not.

## 2. `utm://start?name=` and the Apple Event codes

`docs/security-model.md` records that `utm://start?name=` is a no-op, which is
why launch goes through registration polling plus the `UTMvstar` Apple Event.
That was measured against 4.7.5.

[V] Measured on 4.7.5: opening the URL against a registered, stopped VM left it
stopped.

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

[L] That a *notarized* Sandfort build's Apple Events reach a shipped UTM 5
under the hardened runtime and the current Automation prompt. Entitlements and
TCC are not readable from the UTM source tree.

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

[V] `UTMLauncher.resolveInstallation` reads `CFBundleShortVersionString` and
`doctor()` reports it — `SandfortWorkflow.swift:206`. Nothing compares it to a
floor. `README.md` says "Install UTM" with no version. `HELP.md` mentions only
which version Sandfort can see.

Recommendation, on the evidence in this document: **do not raise it, and do not
introduce one yet.**

- 4.7.5 is UTM's current stable release and the version everything here was
  verified against. Requiring 5.x would require a beta.
- Every interface Sandfort depends on is unchanged in 5.0.4 by source, so there
  is nothing to raise a floor *for*.
- Sandfort's own floor is macOS 13. UTM 4.7.5 declares
  `LSMinimumSystemVersion` 11.3 [V] and UTM 5 requires macOS 13, so UTM 5's
  raised floor cannot exclude a Mac that can already run Sandfort.

The version worth stating in documentation is not a minimum but a
**verified-against**: 4.7.5.

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

## 6. The firmware file

`UTMLauncher.Installation.firmwareURL` reads
`Contents/Resources/qemu/edk2-arm-vars.fd` out of UTM's own bundle, and
`createSetupBundle` fails with `utmResourcesMissing` if it is absent. This is a
hard dependency on UTM's internal layout.

[V] Present in 4.7.5 at that exact path, 329,216 bytes.

[S] Ambiguous, and deliberately reported as such. The `v4.7.5` tree carried
`patches/data/qemu-10.0.2-utm/pc-bios/edk2-arm-vars.fd.bz2`; at `v5.0.4` the
entire `patches/data/` directory is gone, alongside the move to
`qemu-10.0.12-utm`. Neither `build_dependencies.sh` nor `build_utm.sh`
references `patches/data` or `edk2` at either tag, which suggests those blobs
were build inputs superseded by the newer QEMU tarball rather than a decision
to stop shipping the firmware. That is an inference, not a finding.

[L] **Confirm `Contents/Resources/qemu/edk2-arm-vars.fd` exists in a shipped
UTM 5.0.4.** If it moved or was renamed, baseline creation fails outright with
"UTM resources missing" — loud, not silent, but a total stop.

## 7. What still needs a live UTM 5 check

Nothing below was settled by this audit. Each is written so it can be run.

1. **The firmware path.** `ls "/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd"`
   on UTM 5.0.4. Highest priority: it gates baseline creation entirely (§6).
2. **The isolation keys at runtime.** Build a clean instance, boot it under UTM
   5, then confirm in UTM's own settings UI that network isolation is on,
   directory sharing is None, clipboard sharing is off, USB sharing is off, and
   no port forward exists. Reading the plist back is not sufficient — the
   question is what UTM *did* with it (§1).
3. **The offline guarantee end to end.** Offline clean instance on UTM 5: no
   route off the guest. This is the guarantee, and it is the one worth spending
   a boot on.
4. **Launch.** Create an environment on UTM 5 and confirm the open-register-poll
   `UTMvstar` sequence starts the VM, including from a cold UTM (§2).
5. **`utm://start` on 5.0.4.** Expected to remain a no-op, and now with a source
   explanation. Cheap to confirm while UTM 5 is installed.
6. **Stop and delete.** `UTMvstop`/`ReQu` powers a guest down politely, and
   Rebuild's `coredelo` still unregisters by exact name (§2).
7. **`virtio-gpu-pci` renders.** The graphics rewrite should not touch a non-GL
   display; confirm the GNOME greeter appears and is usable (§3).
8. **Bundle re-registration.** Reset an instance and confirm UTM 5 does not end
   up with a duplicate or stale library entry, given the new inode-based
   identity check (§5).
9. **Config caching.** After `repairBundle` rewrites `config.plist` under a
   registered VM, does UTM 5 use the new file or a cached one? Worth asking of
   4.7.5 as well (§5).
10. **A non-default renderer backend.** Only if reproducing a user report:
    whether UTM's global Vulkan/renderer defaults can fail a start for a
    non-GL VM (§3).

Until items 1–4 are done, the honest statement is the one this repository now
makes: **Sandfort is verified against UTM 4.7.5, and its UTM 5 compatibility is
argued from UTM's source rather than observed.**

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
grep -c IsolateFromHost <(strings -a /Applications/UTM.app/Contents/MacOS/UTM)
```
