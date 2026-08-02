# Repository guidance for coding agents

## Project and architecture

Sandfort is a native SwiftUI macOS 13+ app that creates disposable Ubuntu 24.04,
Fedora 44, Debian 13, and openSUSE Leap 16 ARM64 VMs for UTM on Apple silicon. Keep the current implementation
provider-oriented so Intel macOS, Windows, and Linux installers can be added
without weakening the common provisioning policy.

- `sources/sandfortapp/SandfortApp.swift`: SwiftUI views and user-facing state.
- `SandfortWorkflow.swift`: app-owned state, verified downloads, baseline/session
  lifecycle, and native UTM launch.
- `SandboxLibrary.swift`: multi-environment paths, shared cache, and preservation
  of the pre-Phase-7 singleton environment without moving or silently
  re-registering its VM bundles. New and rebuilt VMs include the distribution.
- `LinuxGuestCatalog.swift`: curated guest metadata, immutable verified images,
  hardware requirements, and the provisioning strategy boundary.
- `GuestProvisioningSupport.swift`: distribution-neutral credential validation,
  custom-script embedding, Node.js verification, MOTD, and completion helpers.
- `MemorablePasswordWords.swift`: reviewed 2,048-word list behind the generated
  guest password. Its size is an entropy claim documented in
  `docs/password-strength.md` and enforced by tests; do not add, remove, or
  reorder entries without updating both.
- `PlatformProvider.swift`: `VirtualMachineProvider` boundary for future hosts.
- `UTMBundleBuilder.swift`: UTM plist/bundle generation and clean-session reset.
- `CloudInit.swift`: current Ubuntu credentials, packages, hardening, and
  baseline setup behind the catalog profile.
- `FedoraCloudInit.swift`: Fedora 44 DNF5, Workstation, firewalld, SELinux,
  automatic-update, and completion policy.
- `DebianCloudInit.swift`: Debian 13 APT, GNOME/GDM, AppArmor, UFW,
  unattended-upgrade, and completion policy. Debian revision 4 is production-supported.
- `OpenSUSECloudInit.swift`: openSUSE Leap 16 Zypper, GNOME/GDM, Firefox,
  NetworkManager, firewalld, SELinux, security-patch timer, and completion
  policy. Leap's GNOME pattern pulls in no browser, unlike the other three
  desktop metapackages, so the profile installs one explicitly. Leap revision 3
  is production-supported.
- `NativeDownloader.swift`, `DiskUtilities.swift`, `ISO9660Writer.swift`: native
  download, verification, disk manipulation, and NoCloud ISO generation.
- `OpenPGPSignatureVerifier.swift`: **security-critical.** Minimal OpenPGP
  detached-signature verifier used during profile intake, so a pinned checksum
  can be confirmed as a value the distribution actually signed without
  depending on the `gpg` tool. A verifier fails open when it is wrong, so a
  parsing mistake turns "invalid signature" into "accepted". Keep it strictly
  bounds-checked, keep the algorithm allowlist narrow, and never let the stored
  left-16 digest bits stand in for real verification.
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
- `docs/architecture.md`, `docs/security-model.md`, and
  `docs/adding-a-platform.md`: design intent and provider requirements.
- `docs/password-strength.md`: generated guest-password entropy, storage,
  threat-model limitations, and stronger user-selected password guidance.
- `docs/linux-profile-provenance.md`: immutable guest-image intake records and
  qualification status.

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
codesign --verify --deep --strict "dist/Sandfort.app"
make qualification-app
codesign --verify --deep --strict "dist/Sandfort Fedora Qualification.app"
make debian-qualification-app
codesign --verify --deep --strict "dist/Sandfort Debian Qualification.app"
make opensuse-qualification-app
codesign --verify --deep --strict "dist/Sandfort openSUSE Qualification.app"
```

`make test` supplies repository-local Swift module-cache paths and runs
`swift test --disable-sandbox`. `make app` performs a release build, replaces
`dist/Sandfort.app`, and ad-hoc signs it when `codesign` is available. The app
still needs Developer ID signing and notarization for distribution. When
shipping a user-visible change, update both version values in
`tools/packaging/Info.plist` deliberately and rebuild the app.

`make qualification-app` creates a separately identified Fedora-only regression
app with isolated Application Support state and clearly prefixed UTM names. It
is a development verification tool, not the production profile selector. Follow
`docs/fedora-qualification.md`; never use production state for qualification.

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
