# Repository guidance for coding agents

## Project and architecture

Sandfort is a native SwiftUI macOS 13+ app that creates disposable Ubuntu
24.04 ARM64 VMs for UTM on Apple silicon. Keep the current implementation
provider-oriented so Intel macOS, Windows, and Linux installers can be added
without weakening the common provisioning policy.

- `sources/sandfortapp/SandfortApp.swift`: SwiftUI views and user-facing state.
- `SandfortWorkflow.swift`: app-owned state, verified downloads, baseline/session
  lifecycle, and native UTM launch.
- `LinuxGuestCatalog.swift`: curated guest metadata, immutable verified images,
  hardware requirements, and the provisioning strategy boundary.
- `PlatformProvider.swift`: `VirtualMachineProvider` boundary for future hosts.
- `UTMBundleBuilder.swift`: UTM plist/bundle generation and clean-session reset.
- `CloudInit.swift`: current Ubuntu credentials, packages, hardening, and
  baseline setup behind the catalog profile.
- `NativeDownloader.swift`, `DiskUtilities.swift`, `ISO9660Writer.swift`: native
  download, verification, disk manipulation, and NoCloud ISO generation.
- `tests/sandfortapptests`: policy and bundle-format regression tests.
- `tools/packaging`: development app-bundle packaging metadata and script.
- `HELP.md`: canonical user help source. Packaging renders it into Sandfort's
  indexed native macOS Help Book; do not edit generated Help Book HTML directly.
- `docs/architecture.md`, `docs/security-model.md`, and
  `docs/adding-a-platform.md`: design intent and provider requirements.

## Planned Linux guest catalog work

The bundled catalog currently contains one proven profile: Ubuntu 24.04 LTS
ARM64. Extend this into a user-selectable Linux catalog without accepting
arbitrary downloads:

- Add curated Debian, Fedora, and other Linux profiles only after their official
  immutable cloud images, pinned SHA-256 values, ARM64 boot behavior, desktop,
  guest agents, package manager, firewall, and completion checks are tested.
- Add the distribution selector to Create/Rebuild, not the routine instance-run
  screen. Preserve the existing baseline and clean-instance flow after selection.
- Persist a profile revision and image checksum with the existing profile ID so
  an app update can detect baseline incompatibility instead of silently applying
  another distribution's provisioning or hardware assumptions.
- Keep distribution provisioning separate from the host provider: profiles own
  guest setup and verification; UTM and future hypervisors own VM packaging,
  isolation, firmware, launch, and reset behavior.
- Decide explicitly whether a selected distribution replaces the one protected
  baseline or whether a later release supports multiple independent baselines.
  Do not retain or delete old baselines implicitly.
- Require automated profile-contract tests plus a real UTM boot smoke test through
  setup, automatic poweroff, graphical login, offline reset, and Internet-enabled
  reset before exposing a profile in the UI.

Catalog entries must remain bundled, reviewed, and version-controlled. Never
populate the trusted catalog from an unsigned remote source or user-supplied URL.

## Build, test, and package

Run commands from the repository root:

```sh
make test
make app
codesign --verify --deep --strict "dist/Sandfort.app"
```

`make test` supplies repository-local Swift module-cache paths and runs
`swift test --disable-sandbox`. `make app` performs a release build, replaces
`dist/Sandfort.app`, and ad-hoc signs it when `codesign` is available. The app
still needs Developer ID signing and notarization for distribution. When
shipping a user-visible change, update both version values in
`tools/packaging/Info.plist` deliberately and rebuild the app.

## Security invariants

Treat these as requirements, not optional defaults:

- Download only an immutable official image for the exact guest architecture
  and verify its pinned SHA-256 before use. Never silently accept a mismatch.
- Restore both the selected instance's disk and UEFI state from the trusted
  setup baseline before every untrusted launch. Multiple numbered instances
  must remain independent and receive unique UUIDs and MAC addresses. Never
  copy or restore a running VM.
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
- Do not add AppleScript, `osascript`, UI scripting, or runtime shell-command
  dependencies. The distributed app must perform downloads, hashing, QCOW2
  changes, ISO creation, UTM configuration, and launch through native Swift APIs
  (`NSWorkspace` is used for launch). Packaging scripts are build-time only.

Read `docs/security-model.md` before changing VM, storage, networking, sharing,
download, cloud-init, or launch behavior. Add regression assertions for every
security-relevant configuration change.

## Baseline and compatibility implications

Changes embedded in the guest do not update an existing baseline. Any change to
`CloudInit.swift`, credentials, packages/tools, desktop/login services, firewall,
journald, wait-online behavior, or the custom setup path requires the user to
stop the VM and choose **Rebuild**. State this clearly in release notes and the
handoff. A new app binary alone is insufficient.

Host-side clean-bundle configuration in `UTMBundleBuilder.swift` is generally
reapplied by **Run Clean Sandbox**, but verify behavior for existing saved state
as well as newly rebuilt state. Changing image URL/hash, disk format, firmware,
or setup-bundle structure should be treated as baseline-incompatible unless
tests demonstrate a safe migration. Keep persisted `Codable` state backward
compatible when adding fields (optional fields with defaults are preferred).

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
