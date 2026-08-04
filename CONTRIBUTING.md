# Contributing to Sandfort

Thanks for your interest. Sandfort creates disposable Linux VMs for running
untrusted code, so most of its rules exist to keep that boundary honest rather
than to enforce style.

**Found a security problem? Do not open an issue.** See [SECURITY.md](SECURITY.md).

## Before you start

- Read [AGENTS.md](AGENTS.md). It is the contributor guide as much as the agent
  guide, and it states the invariants a change must not break.
- Read [docs/security-model.md](docs/security-model.md) before touching VM
  configuration, networking, sharing, downloads, cloud-init, or launch code.
- For a larger change, open an issue or discussion first. Adding a Linux
  distribution in particular has a process (below) that is worth agreeing on
  before you write code.

## Getting set up

You need macOS 13+ on Apple silicon, a recent Xcode toolchain, and
[UTM](https://mac.getutm.app/).

```sh
make test     # policy and format regression tests
make app      # release build into dist/Sandfort.app, ad-hoc signed
```

`make test` must pass for every change. Note that no workflow runs on pull
requests — `test.yml` is manual, and `release.yml` runs on version tags — so
opening a pull request does not run the suite for you. Run it locally and say so
in the pull request.

Editing `HELP.md` has a trap worth knowing. Help Viewer keeps its own copy of
the rendered Help Book under
`~/Library/Group Containers/group.com.apple.helpviewer.content/Library/Caches/`,
and the cache key uses `CFBundleShortVersionString` — **not** the build number.
Rebuilding with a new `CFBundleVersion` does not invalidate it, so help edits
appear to have no effect. Either bump the short version or clear that cache:

```sh
rm -rf ~/Library/Group\ Containers/group.com.apple.helpviewer.content/Library/Caches/app.sandfort.*
killall helpd
```

For packaging or UI changes, also run `make app` and verify the result:

```sh
codesign --verify --strict "dist/Sandfort.app"
```

`--deep` is deliberately absent. It is deprecated, and when signing it applies
the app's entitlements to the nested Help Book bundle; it has also been seen
sealing its own temporary file into the bundle, which then fails verification
with "a sealed resource is missing or invalid".

## Releasing

Cutting a release is `make release`, which bumps the version, tags it, and
pushes; the tag starts a signed, notarized build in GitHub Actions. The version
lives in `tools/packaging/Info.plist`, and the tag is derived from it rather than
the other way round.

Read [docs/releasing.md](docs/releasing.md) before the first one: it covers the
Developer ID certificate, the six repository secrets, and the Apple Events
entitlement that a notarized build silently needs in order to start a VM at all.

## What a good change looks like

- **Focused.** Preserve unrelated work; do not reformat files you are not
  changing.
- **Tested behaviorally.** Prefer a test that would fail if the behavior
  regressed over one that restates the implementation. Checksum failure, bundle
  isolation, both network modes, baseline restoration, cloud-init contents, and
  backward decoding of persisted state are the areas that matter most.
- **Documented where it changes intent.** The `docs/` files are the reasoning
  behind the code, not a summary of it. If your change makes one of them wrong,
  fix it in the same pull request.
- **Honest about verification.** Say what you actually ran. Never describe a
  live UTM boot as tested unless you booted it.

Every source file carries the Apache-2.0 header. A test enforces this, so new
files need it too.

## Things that will be rejected

These are not style preferences; they are the product:

- Shelling out at run time. Downloads, hashing, disk manipulation, ISO creation,
  UTM configuration, and launch all go through native Swift APIs. No
  AppleScript, `osascript`, UI scripting, or runtime command-line dependencies.
  Build scripts are exempt because they are build-time only.
- Arbitrary or user-supplied image URLs, or a remotely mutable catalog. Catalog
  entries stay bundled, reviewed, and version-controlled.
- Accepting an image whose pinned SHA-256 does not match.
- Bridged networking, inbound port forwarding, host directory sharing, clipboard
  sharing, or automatic USB sharing, in any network mode.
- Enabling SSH in a guest, or weakening the guest firewall.
- Telemetry, analytics, or anything that transmits a generated credential.
- Relaxing a check in `OpenPGPSignatureVerifier.swift` to make a new format
  parse. Add the format explicitly, or leave it unverified and say so in the
  provenance record.

## Changing guest provisioning

Anything embedded in the guest — `CloudInit.swift`, the per-distribution
cloud-init files, `GuestProvisioningSupport.swift`, packages, desktop or login
services, firewall, or the custom setup path — does not update an existing
baseline. Users must **Rebuild**.

That means such a change needs a **profile revision bump**, so the app detects
the incompatibility instead of silently assuming a guarantee the old baseline
does not have. Say so plainly in your pull request: a new binary alone is not
enough.

## Adding a Linux distribution

Summarized from AGENTS.md; read it there in full before starting.

1. Pin one official, immutable cloud image for the exact architecture, with its
   published SHA-256. Verify its signature if the distribution publishes one,
   and record what you verified in `docs/linux-profile-provenance.md`. If it is
   unverified, say so rather than implying otherwise.
2. Write the provisioner, keeping guest setup separate from UTM packaging.
3. Add contract tests.
4. Build the isolated qualification app for the profile and complete its real
   UTM matrix: setup, automatic poweroff, graphical login, offline reset,
   Internet-enabled reset, resume, deletion, and concurrent environments.
5. Only after the matrix passes may the profile move into production
   `profiles` and `supportedProfiles`.

## Pull requests

- Branch from `main`.
- Write a commit message explaining *why*, not only what. The history is used to
  reconstruct intent later.
- State the commands you ran and their results, and whether users must rebuild.
- Small, reviewable pull requests get merged faster, especially for anything
  touching security-critical code.

## Reporting bugs

Use the issue templates. For anything involving a VM, include the Sandfort
version, macOS and UTM versions, Mac model, and the guest profile and revision.
`/var/log/sandfort-setup.log` inside the guest is usually the fastest route to a
diagnosis. Redact credentials before pasting logs.
