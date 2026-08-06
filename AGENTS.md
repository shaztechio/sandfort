# Repository guidance for coding agents

## Project and architecture

Sandfort is a native SwiftUI macOS 13+ app that creates disposable Ubuntu 24.04,
Fedora 44, Debian 13, and openSUSE Leap 16 ARM64 VMs for UTM on Apple silicon. Keep the current implementation
provider-oriented so Intel macOS, Windows, and Linux installers can be added
without weakening the common provisioning policy.

- `sources/sandfortapp/`: the view layer is split by pane —
  `SandfortApp.swift` (App scene), `ContentView.swift` (window shell, sheets,
  dialogs), `SandfortViewModel.swift`, `EnvironmentSidebar.swift`,
  `EnvironmentDetailView.swift`, `ActivityLogView.swift`,
  `BaselineToolsSheet.swift`, and `SandfortSettingsView.swift`.
- `SandfortWorkflow.swift`: app-owned state, verified downloads, baseline/session
  lifecycle, and native UTM launch.
- `SandboxLibrary.swift`: multi-environment paths, shared cache, and preservation
  of the pre-Phase-7 singleton environment without moving or silently
  re-registering its VM bundles. New and rebuilt VMs include the distribution.
- `LinuxGuestCatalog.swift`: curated guest metadata, immutable verified images,
  hardware requirements, and the provisioning strategy boundary.
- `GuestProvisioningSupport.swift`: distribution-neutral credential validation,
  custom-script embedding, Node.js and Visual Studio Code installation, the
  terminal and browser verification commands, MOTD, and completion helpers. Both
  vendor downloads are checked against the vendor's published SHA-256, and VS
  Code uses the tarball so no third-party repository or key is added to a
  guest.
- `MemorablePasswordWords.swift`: reviewed 2,048-word list behind the generated
  guest password. Its size is an entropy claim documented in
  `docs/password-strength.md` and enforced by tests; do not add, remove, or
  reorder entries without updating both.
- `AppLifecycle.swift`: single-window quit behavior and the in-progress guard
  that warns before discarding a download. Sandfort quits when its window
  closes, the way System Settings does; a second window would race the first
  over the same baselines and instances.
- `PlatformProvider.swift`: `VirtualMachineProvider` boundary for future hosts.
- `SafetyAcknowledgement.swift`: first-run disclosure text and its stored record.
  It gates baseline creation. Keep the wording accurate and consistent with
  `docs/security-model.md`; it must never imply the sandbox makes the user safe.
  Raise `currentVersion` only when a user should genuinely see it again.
- `UTMBundleBuilder.swift`: UTM plist/bundle generation and clean-session reset.
- `CloudInit.swift`: current Ubuntu credentials, packages, hardening, and
  baseline setup behind the catalog profile.
- `FedoraCloudInit.swift`: Fedora 44 DNF5, Workstation, firewalld, SELinux,
  automatic-update, and completion policy.
- `DebianCloudInit.swift`: Debian 13 APT, GNOME/GDM, AppArmor, UFW,
  unattended-upgrade, and completion policy. Debian revision 7 is production-supported.
- `OpenSUSECloudInit.swift`: openSUSE Leap 16 Zypper, GNOME/GDM, Firefox,
  NetworkManager, firewalld, SELinux, security-patch timer, and completion
  policy. Leap's GNOME pattern pulls in neither a browser nor a terminal, unlike
  the other three desktop metapackages, so the profile installs both explicitly.
  Leap revision 5 is production-supported.
- `NativeDownloader.swift`, `DiskUtilities.swift`, `ISO9660Writer.swift`: native
  download, verification, disk manipulation, and NoCloud ISO generation.
- `OpenPGPSignatureVerifier.swift`: **security-critical.** Minimal OpenPGP
  detached-signature verifier used during profile intake, so a pinned checksum
  can be confirmed as a value the distribution actually signed without
  depending on the `gpg` tool. A verifier fails open when it is wrong, so a
  parsing mistake turns "invalid signature" into "accepted". Keep it strictly
  bounds-checked, keep the algorithm allowlist narrow, and never let the stored
  left-16 digest bits stand in for real verification. Whatever it hands back as
  verified must be the bytes it actually hashed, not the slice of the document
  they came from; a `try?` around a parser cannot catch a Swift trap, so a
  declared length that overflows a conversion ends the process instead of
  failing the key.
- `TrustedSigningKeys.swift`: **security-critical data.** Reviewed, bundled
  Ubuntu, Fedora, and openSUSE signing keys with their pinned fingerprints. The
  fingerprint is the trust anchor, and keys are selected from vendor key files by
  fingerprint rather than by position; never fetch a key from a keyserver,
  mirror, or any runtime source at run time. Debian publishes no signature for
  its cloud manifest and stays hash-only.
- `tests/sandfortapptests`: policy and bundle-format regression tests.
- `tools/packaging`: development app-bundle packaging metadata and script.
- `HELP.md`: canonical user help source. Packaging renders it into Sandfort's
  indexed native macOS Help Book; do not edit generated Help Book HTML directly.
  Verify a help change by reading the rendered HTML in the built app, not by
  opening Help Viewer: it caches its own copy keyed on
  `CFBundleShortVersionString`, so a new build number serves stale content and a
  fixed bug still looks broken. See CONTRIBUTING.md for the cache path.
- `docs/architecture.md`, `docs/security-model.md`, and
  `docs/adding-a-platform.md`: design intent and provider requirements.
- `docs/password-strength.md`: generated guest-password entropy, storage,
  threat-model limitations, and stronger user-selected password guidance.
- `docs/custom-setup-scripts.md`: how the advanced custom setup script runs,
  its constraints, worked scenarios, and what such a script must never do.
  Package names in its examples are verified against official repository
  metadata; keep that true when editing them.
- `docs/linux-profile-provenance.md`: immutable guest-image intake records and
  qualification status.
- `docs/releasing.md`: cutting a release, the Developer ID and notarization
  setup, and the entitlement a notarized build needs to drive UTM.
- `docs/security-review.md`: the brief for an external security review. Scope in
  priority order, what a finding must contain, and the adjudication gate — a
  finding that cannot be written as a failing test is almost always wrong.
- `docs/LINUX.md`: plan only, nothing built. QEMU/KVM, and the finding that
  matters beyond Linux: starting, stopping, and unregistering a VM live outside
  `VirtualMachineProvider`, so the contract has to grow before any second host.
- `docs/WINDOWS.md`: plan only, nothing built. The concrete Windows instance of
  `adding-a-platform.md`, including why it recommends QEMU over the Hyper-V that
  document assumes, and the open questions to settle before phase 1.
- `docs/index.html` and `docs/assets/`: the public project site, served by GitHub
  Pages from `main` and `/docs`. It shares this folder with the documentation, so
  `docs/.nojekyll` must stay: without it Jekyll renders every `.md` here into a
  page and treats `{{` and `{%` as Liquid. Never add a `docs/README.md`. The
  site's claims are drawn from `security-model.md` and `LinuxGuestCatalog.swift`,
  including its residual-risk panel; update it in the same commit that changes
  the security model. See `docs/project-site.md`.

## Planned Linux guest catalog work

The bundled production catalog contains proven Ubuntu 24.04 LTS, Fedora 44,
Debian 13, and openSUSE Leap 16 ARM64 profiles. Continue extending the curated Linux catalog without accepting
arbitrary downloads:

- Add curated Debian, Fedora, and other Linux profiles only after their official
  immutable cloud images, pinned SHA-256 values, ARM64 boot behavior, desktop,
  guest agents, package manager, firewall, and completion checks are tested.
- Add new distributions as independent environments. Rebuild and routine
  instance actions must remain scoped to the selected environment.
- Preserve the persisted profile revision and image checksum alongside the
  profile ID. Keep explicit legacy mappings and supported old revisions so an
  app update detects baseline incompatibility instead of silently applying
  another distribution's provisioning or hardware assumptions.
- Keep distribution provisioning separate from the host provider: profiles own
  guest setup and verification; UTM and future hypervisors own VM packaging,
  isolation, firmware, launch, and reset behavior.
- Pass the resolved profile explicitly to every profile-sensitive workflow and
  provider operation. Never consult a process-wide default while repairing,
  resetting, or recreating a baseline or instance identified by saved state.
- Preserve one independently managed protected baseline per selected profile.
  Never delete or rebuild another environment implicitly.
- Require automated profile-contract tests plus a real UTM boot smoke test through
  setup, automatic poweroff, graphical login, offline reset, and Internet-enabled
  reset before exposing a profile in the UI.

Catalog entries must remain bundled, reviewed, and version-controlled. Never
populate the trusted catalog from an unsigned remote source or user-supplied URL.

### Console login prompt before the greeter

All four profiles mask `getty@tty1.service`. Instances are built with a display
and no serial device, so a VT1 getty parks a text `sandfort login:` prompt on
the framebuffer from multi-user.target until the greeter starts, which reads as
though the sandbox must be driven from a command line.

Mask only that one unit. Never mask the `getty@` or `autovt@` templates: logind
still spawns a console on demand, so Ctrl+Alt+F2 stays available as a rescue
path when the desktop fails. These guests have no SSH and no serial device, so
removing every text console would leave a broken instance unreachable.

Baseline setup is unaffected. The setup VM is built with a serial device and no
display, and its failure path still unmasks `serial-getty@ttyAMA0`.

### Every profile verifies a terminal and a browser

openSUSE shipped two versions of the same defect: revision 1 had no browser and
revision 3 had no terminal, because Leap's `patterns-gnome-gnome` requires only
`gnome-session-wayland` and declares no recommends. Both look like a complete
desktop until someone tries to use one.

All four profiles now verify that a terminal and a browser exist, through
`GuestProvisioningSupport.terminalVerificationCommand` and
`browserVerificationCommand`. Keep three things true when editing them:

- Check the **binary**, not the package. On Ubuntu both `firefox` and
  `chromium-browser` are transitional packages for snaps, so a package query can
  succeed while nothing usable is installed.
- Keep the alternatives. Distributions disagree: Fedora ships Ptyxis, GNOME
  ships Console, the others ship Terminal.
- openSUSE installs `gnome-terminal` and `MozillaFirefox` explicitly, because
  its pattern provides neither. The other three inherit both from their desktop
  metapackage and only verify them.

### Deferred: remaining clean-instance boot time

Masking `systemd-networkd-wait-online` removed two minutes from a Debian clean
boot. `systemd-analyze blame` on the resulting instance still shows two costs
worth roughly 13 seconds together, both deliberately left alone:

- `plymouth-quit-wait.service`, 11.5s, and on the critical chain. This waits for
  the boot splash to hand off to the display manager. Disabling it is the obvious
  win and the obvious risk: the complaint that started this was a black screen,
  and interfering with the splash handoff is a good way to produce another one.
- `fwupd.service`, 1.9s. A firmware updater with no firmware to update in a VM.
  Safe to mask, but not worth a rebuild-forcing revision on its own.

Fold these into a revision that is already forcing a rebuild for another reason,
rather than spending one on 13 seconds. Measure with `systemd-analyze blame` and
`systemd-analyze critical-chain graphical.target` inside an offline clean
instance before and after, and check the other three profiles rather than
assuming Debian's numbers transfer: the wait-online problem turned out to be
Debian-only because systemd-networkd is a separate package on Fedora and
openSUSE.

### Deferred: per-environment RAM and disk sizing

Every profile is fixed at 4 GiB RAM, 4 CPUs, and a 64 GiB disk in
`LinuxGuestProfile.Hardware`. With VS Code installed beside GNOME and a browser
that is tight. The agreed direction is to make RAM and disk configurable **per
environment**, with defaults of **6 GiB and 96 GiB**. CPU count stays at 4.

**There is no per-distribution work.** `Hardware` is uniform across the four
profiles, and guest-side growth already works everywhere: baselines start from a
2–4 GiB cloud image and end up with usable 64 GiB filesystems, which only
happens because cloud-init's `growpart` and `resizefs` run. Filesystems differ
(ext4 on Ubuntu and Debian, btrfs on Fedora and openSUSE) and cloud-init handles
both; openSUSE's SBOM ships `growpart` plus `btrfsprogs`, `e2fsprogs`, and
`xfsprogs`.

Most of the plumbing exists:

- `DiskUtilities.resizeQCOW2` grows and refuses to shrink, which is correct;
  shrinking a qcow2 under a live filesystem is not safe.
- `UTMBundleBuilder.repairBundle` already resizes the disk and runs on every
  **Reset & Run Clean**, so a larger disk reaches existing instances already.
- `growpart` and `resizefs` are `PER_ALWAYS`, so a guest picks up a larger disk
  on its next boot rather than only at first boot.
- **The gap:** `repairBundle` never writes `MemorySize` or `CPUCount`. Those are
  set only by `writeConfiguration` at bundle creation, so an existing instance
  would keep its old RAM forever. Reset must update them, and that deserves its
  own regression test because it is invisible in the UI.

Design notes for whoever picks this up:

- Store optional `memoryMiB` and `diskSizeGiB` beside `SandboxToolSelection`,
  falling back to the profile's values, so older state still decodes. Same
  pattern as the VS Code toggle.
- Pass the resolved hardware into `UTMBundleBuilder` instead of letting it read
  `profile.hardware`, matching the rule that a resolved profile is passed
  explicitly rather than looked up.
- Validate before anything destructive: disk may only grow, so reject a value
  below the environment's current size with a clear message instead of failing
  inside `resizeQCOW2`. RAM needs a floor near 2 GiB, below which the GNOME
  desktop is unusable, and a ceiling well under
  `ProcessInfo.processInfo.physicalMemory` because instances run concurrently.
- Put it in its own sheet, not the development-tools sheet. Tool selections apply
  only to the next baseline; these apply to instances on reset, and mixing them
  misrepresents when each takes effect.
- `doctor()` reports only UTM, architecture, and sandbox state. It should also
  report host RAM and free space and flag a configuration the Mac cannot afford;
  nothing warns today.
- No profile revision bump and no rebuild: nothing inside the guest changes and
  the disk format is untouched, only its virtual size, through a path that
  already runs. That is the judgment call in this plan most worth challenging
  before implementing.

Verify with a real UTM boot on at least one ext4 and one btrfs profile: after a
reset, `free -h` should show the new RAM and `df -h /` the larger root.

## Planned network observability and filtering

Future work may add per-sandbox egress monitoring and filtering. Treat this as a
separate signed Network Extension/system-extension project, not as a small UTM
configuration change. Follow Apple's supported Network Extension content-filter
APIs; do not modify Packet Filter rules, routing tables, install packet-capture
shell tools, or add unreviewed QEMU arguments.

Implementation plan:

1. Prototype a macOS `NEFilterDataProvider` and, if required for pre-NAT
   attribution, `NEFilterPacketProvider`. Package it as an app or system
   extension with the required entitlements, Developer ID signing, user consent,
   and documented uninstall behavior.
2. Prove attribution with two concurrently running Internet-enabled UTM/QEMU
   instances. UTM's Emulated VLAN traffic is presented to macOS as originating
   from the UTM process, so process identity alone is insufficient. Correlate
   only with stable, observed VM metadata such as the instance's unique MAC,
   subnet, or pre-NAT packet context. Never guess the environment from timing.
3. If reliable concurrent attribution is not possible, either introduce a
   dedicated per-instance logging gateway or explicitly restrict monitored
   Internet access to one running instance. Do not show potentially incorrect
   instance attribution as authoritative.
4. Keep **Offline** unchanged as the safest mode. Add **Monitored Internet** only
   after the extension is active and healthy. Decide separately whether a
   direct, unmonitored Internet mode remains available.
5. Record metadata only: timestamp, environment ID, instance number, destination
   IP, destination port, protocol, allow/block verdict, byte counts, and a domain
   name only when it is genuinely observable from plaintext DNS or equivalent
   flow metadata.
6. Do not promise full URLs or complete domain visibility. HTTPS paths are
   encrypted; encrypted DNS and TLS ECH can hide hostnames. Never capture packet
   payloads, credentials, request bodies, cookies, or other content.
7. Add an in-app activity view with filters for environment, instance, time,
   domain, IP, protocol, and verdict. Include pause, clear, configurable
   retention, and metadata-only JSONL/CSV export.
8. Store logs under an app-owned `Network Logs/<environment-id>/<instance-id>`
   hierarchy with per-run identifiers. Apply bounded retention and make log
   deletion explicit and recoverable where practical. Never include the guest
   password or custom setup script.
9. Add reviewed allowlist and denylist policies with clear precedence and a safe
   failure mode. If the monitor/filter is unavailable, a requested monitored run
   must fail closed rather than silently launch with unrestricted Internet.
10. Test DNS, direct IP connections, TCP, UDP, ICMP, IPv4, IPv6, encrypted DNS,
    concurrent instances, extension restarts, app crashes, sleep/wake, and UTM
    upgrades before release.

A host content filter generally cannot observe attempts that UTM blocks inside a
truly offline network. Logging attempted offline connections would require
guest-side telemetry (tamperable by guest root) or a dedicated gateway that
receives, records, and denies traffic. Preserve this distinction in the UI:
"no observed traffic" must never be presented as proof that no connection was
attempted.

Primary references:

- UTM QEMU network behavior:
  <https://docs.getutm.app/settings-qemu/devices/network/network/>
- Apple Network Extension content filters:
  <https://developer.apple.com/documentation/networkextension/content-filter-providers>
- Apple TN3120, including why packet tunnels are not content filters:
  <https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers>
- Apple TN3134 provider deployment:
  <https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment>

## Build, test, and package

Run commands from the repository root:

```sh
make test
make app
codesign --verify --strict "dist/Sandfort.app"
make qualification-app
codesign --verify --strict "dist/Sandfort Fedora Qualification.app"
make ubuntu-qualification-app
codesign --verify --strict "dist/Sandfort Ubuntu Qualification.app"
make debian-qualification-app
codesign --verify --strict "dist/Sandfort Debian Qualification.app"
make opensuse-qualification-app
codesign --verify --strict "dist/Sandfort openSUSE Qualification.app"
```

`make test` supplies repository-local Swift module-cache paths and runs
`swift test --disable-sandbox`. `make app` performs a release build, replaces
`dist/Sandfort.app`, and ad-hoc signs it when `codesign` is available.

`make release` cuts a release: it bumps the version in
`tools/packaging/Info.plist`, commits, tags, and pushes, and the tag starts a
signed and notarized build in GitHub Actions. `make signed-app` does the same
signing locally. Do not hand-edit the version to ship something; the tag is
derived from the plist and the workflow fails when they disagree. Editing the
version by hand is still right for an ordinary user-visible change that is not
itself a release.

Read `docs/releasing.md` before changing anything about signing. The short
version: notarization requires the hardened runtime, the hardened runtime blocks
Apple Events without `com.apple.security.automation.apple-events`, and Sandfort
drives UTM entirely through Apple Events. A build missing that entitlement
installs, launches, and never starts a VM, without reporting an error.

`make qualification-app` creates a separately identified Fedora-only regression
app with isolated Application Support state and clearly prefixed UTM names. It
is a development verification tool, not the production profile selector. Follow
`docs/fedora-qualification.md`; never use production state for qualification.

`make ubuntu-qualification-app` creates the corresponding isolated Ubuntu
regression build. Follow `docs/ubuntu-qualification.md`; never use production
state for qualification. Ubuntu is the default profile, so it is the one most
likely to be tested against production state by accident.

`make debian-qualification-app` creates the corresponding isolated Debian
regression build. Follow `docs/debian-qualification.md`; never use production
state for qualification.

`make opensuse-qualification-app` creates the corresponding isolated openSUSE
Leap 16 regression build. Follow `docs/opensuse-qualification.md`; never use
production state for qualification.

## Security invariants

Treat these as requirements, not optional defaults:

- Download only an immutable official image for the exact guest architecture
  and verify its pinned SHA-256 before use. Never silently accept a mismatch.
- Treat `OpenPGPSignatureVerifier.swift` and `TrustedSigningKeys.swift` as
  security-critical. Changes there need the full negative-test set kept green,
  not only the passing signature: tampered payload, tampered signature,
  unpinned key, corrupted armor checksum, truncated packet, and garbage input.
  Never relax a check to make a new distribution's signature parse; add the
  format explicitly or leave it unverified and say so in the provenance record.
- Restore both the selected instance's disk and UEFI state from the trusted
  setup baseline before every untrusted launch. Multiple numbered instances
  must remain independent and receive unique UUIDs and MAC addresses. Never
  copy or restore a running VM.
- Keep every Linux environment's state, VM directory, baseline, credentials, and
  instance numbering independent. Sharing the verified-image cache is allowed;
  sharing mutable guest disks or firmware is not.
- Treat optional instance labels as display metadata only. Renaming must preserve
  the permanent number, bundle path, UUID, MAC address, disk, and UEFI state.
- Keep instance deletion app-owned, recoverable through macOS Trash, and guarded
  by a disk-lock check. Never expose baseline deletion outside Rebuild, and never
  reuse a deleted instance number.
- Default clean runs to offline. Setup may use NAT for trusted provisioning.
  Internet-enabled clean runs may relax UTM guest-to-host network isolation only
  as required for outbound access and only after explicit user choice.
- Never enable bridged networking, inbound port forwarding, host directories,
  clipboard sharing, or automatic USB sharing. Preserve these restrictions in
  every network mode and future provider.
- Keep SSH disabled, unsolicited inbound traffic denied, and security updates
  enabled in the guest policy.
- Custom setup text runs as root during trusted baseline creation. Preserve its
  size limit, safe embedding, and UI warning; never execute it on the host.
- Credentials must be generated locally and shown to the user. Do not log or
  transmit them. Do not add telemetry or secret collection.
- Rebuild may accept a user-selected guest password, but validate it before any
  destructive work and safely quote it in cloud-init. All instances inherit the
  baseline credentials; do not imply per-instance passwords.
- Every source file carries the Apache-2.0 header, enforced by
  `LicenseHeaderTests`. New files need it too. In `Package.swift` the
  tools-version directive stays on line 1 and the header follows it; in shell
  scripts the shebang stays on line 1.
- Do not add AppleScript, `osascript`, UI scripting, or runtime shell-command
  dependencies. The distributed app must perform downloads, hashing, QCOW2
  changes, ISO creation, UTM configuration, and launch through native Swift APIs
  (`NSWorkspace` is used for launch). Packaging scripts are build-time only.

Read `docs/security-model.md` before changing VM, storage, networking, sharing,
download, cloud-init, or launch behavior. Add regression assertions for every
security-relevant configuration change.

## Baseline and compatibility implications

Changes embedded in the guest do not update an existing baseline. Any change to
`CloudInit.swift`, `GuestProvisioningSupport.swift`, credentials, packages/tools,
desktop/login services, firewall, journald, wait-online behavior, or the custom
setup path requires the user to stop the VM and choose **Rebuild**. State this
clearly in release notes and the handoff. A new app binary alone is insufficient.

Host-side clean-bundle configuration in `UTMBundleBuilder.swift` is generally
reapplied by **Run Clean Sandbox**, but verify behavior for existing saved state
as well as newly rebuilt state. Changing image URL/hash, disk format, firmware,
or setup-bundle structure should be treated as baseline-incompatible unless
tests demonstrate a safe migration. Keep persisted `Codable` state backward
compatible when adding fields (optional fields with defaults are preferred).

## Every change goes through a pull request

Branch, open a pull request, let **Tests / macos-arm64** pass, then merge. Do not
push to `main` directly.

This is not ceremony. Release notes are generated from what merged since the
previous tag, so a change that bypasses a pull request is a change that silently
does not appear in any changelog. Direct pushes also skip the only automated
check the project has.

### Conventional Commits

Subject lines follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<optional scope>): <description>
```

Types in use: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`,
`chore`, `revert`. Useful scopes: `catalog`, `cloudinit`, `utm`, `verifier`,
`packaging`, `site`, `release`.

This governs the **subject line only**. The body still explains *why*, at
whatever length that takes; the two conventions compose rather than compete.

**A guest-side change is a breaking change.** Anything embedded in the guest —
cloud-init, provisioning, credentials, services — forces every existing user to
**Rebuild**, and a new binary alone is not enough. Mark those with `!` and a
`BREAKING CHANGE:` footer saying what to do:

```
feat(cloudinit)!: install a terminal and a browser on openSUSE

BREAKING CHANGE: openSUSE baselines must be rebuilt. Leap's GNOME pattern
requires neither, so existing baselines have neither.
```

That is the whole reason to adopt the convention here. "Users must Rebuild" is
the one consequence a reader cannot infer from a description, it is expensive to
miss, and the spec already has a marker for exactly this.

Because merges squash and the pull request title becomes the commit subject,
**the title is the thing that has to be conventional.** A branch's intermediate
commits matter less.

`tools/packaging/check-pull-request.py` enforces this in CI as **Tests /
pull-request**. It rejects a non-conventional title, an unknown type, a
capitalised or full-stopped description, and a subject over 72 characters. It
also refuses a change to cloud-init or `GuestProvisioningSupport.swift` that does
not declare its rebuild impact — either `!` with a `BREAKING CHANGE:` footer, or
`No rebuild required: <why>` in the description. Not every edit to those files
forces a rebuild; the check exists so the question is answered rather than
skipped.

Two exceptions, both mechanical:

- The version bump that `make release` and the release workflow commit. It is
  generated, it is the thing being released, and routing it through review would
  be circular.
- A revert of a broken `main`, which should be fast.

If `main` is ever protected to enforce this, `github-actions[bot]` needs an
exception or the browser release flow cannot push its bump commit. See
`docs/releasing.md`.

## Editing and verification expectations

- Inspect existing changes and preserve unrelated user work. Make focused edits;
  do not delete app-owned VM data or cached images during development.
- Use `apply_patch` for source and documentation edits.
- Keep user-visible progress explicit for downloads and long guest operations.
- Keep Resume distinct from Reset & Run Clean. Resume must not copy the baseline
  or silently alter the instance's last explicit network mode; reset must restore
  both its disk and UEFI state before launch.
- Test behavior rather than only implementation details: checksum failure,
  bundle isolation, both clean network modes, baseline restoration, cloud-init
  contents, and backward decoding are important coverage areas.
- Run `make test` for every code change. For packaging or UI changes, also run
  `make app` and verify the resulting signature. Report commands run and whether
  users must rebuild their baseline.
- Do not claim a live UTM boot was verified unless it was actually smoke-tested.
