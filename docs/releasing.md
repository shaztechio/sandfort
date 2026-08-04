# Releasing

Cutting a release is one command:

```sh
make release
```

That bumps the patch version, runs the tests, commits, tags, and pushes. Pushing
the tag starts the signed build in GitHub Actions, which notarizes the app and
publishes a GitHub Release with the archive and its SHA-256.

For a version that is not a patch bump:

```sh
make release VERSION=1.3.0
```

Preview without changing anything:

```sh
./tools/packaging/release.sh --dry-run
```

## Releasing from a browser

`make release` needs a laptop. To cut a release from the GitHub web UI — after
merging pull requests from a phone, say — use the workflow itself:

**Actions → Signed release → Run workflow**, then set **bump** to `patch`,
`minor`, or `major`, and **Run workflow**.

The run does exactly what `make release` does, in this order: bump
`Info.plist`, commit it, tag it, push both, then test, build, sign, notarize,
and publish the Release. The bump happens before the build, so the app that gets
signed already carries the new version. Leave **version** empty unless you want
an exact number, which overrides the bump.

Leaving **bump** at `none` builds, signs, and notarizes without publishing
anything, and uploads the result as an artifact. That is the way to prove the
signing secrets work before cutting anything public.

Two things this depends on, worth checking once:

- **`main` must not be protected**, or the bump commit cannot be pushed. Add an
  exception for `github-actions[bot]` if you protect it later.
- **Actions needs write access to the repository.** The workflow asks for
  `contents: write` explicitly, but if the bump push or the Release creation
  fails with a 403, set Settings → Actions → General → Workflow permissions to
  **Read and write permissions**.

Do not create the Release through **Releases → Draft a new release**. That page
creates the Release itself, and the workflow then fails trying to create one for
a tag that already has it. It also cannot bump the version, so the tag would not
match what is inside the app.

## The version lives in Info.plist, not in the tag

`tools/packaging/Info.plist` is the single source of truth. The tag is derived
from it, never the reverse.

That direction is deliberate. A tag cannot change what is inside a built app, so
letting the tag lead would allow a release named `v1.2.3` containing an app that
reports `0.16.0`. The workflow fails the build when the two disagree; `make
release` makes them agree by construction.

Two values change on every release:

- `CFBundleShortVersionString` — the visible version, `x.y.z`.
- `CFBundleVersion` — the build number, which only ever increases, across every
  version. macOS treats a lower build number as a downgrade even when the
  visible version went up.

The short version also keys Help Viewer's cache, which is why a help change can
look like it did not take effect until the version moves. See
[CONTRIBUTING.md](../CONTRIBUTING.md).

## What `make release` refuses to do

It stops before changing anything if:

- the current branch is not `main`,
- the working tree has uncommitted changes,
- `main` and `origin/main` differ,
- the tag already exists.

Tests run before the version is committed, so a failing test leaves nothing
behind. The push is confirmed interactively, because it publishes publicly;
answering anything but `y` deletes the local commit and tag.

## One-time setup

The signed build needs six repository secrets. Without them the workflow builds
and then fails in the signing step.

1. **Enrol in the Apple Developer Program** and create a **Developer ID
   Application** certificate: Xcode → Settings → Accounts → Manage Certificates
   → **+**. An "Apple Development" certificate is a different type and cannot
   sign for distribution.
2. **Export it as a .p12** from Keychain Access, expanding the certificate first
   to confirm its private key is included. Exporting the certificate without the
   key is the usual mistake; it signs nothing.
3. **Create an app-specific password** at
   [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security. A
   normal Apple ID password will not notarize.
4. **Set the secrets.** Put the values in a 1Password item with one field per
   secret name, export it as JSON, then:

   ```sh
   ./tools/packaging/set-release-secrets.sh <export.json>
   ```

   It validates everything before sending any of it, passes values over stdin
   rather than as arguments, and prints only names and lengths. Delete the export
   afterwards: it holds a signing key and an app-specific password.

   Or set them by hand under Settings → Secrets and variables → Actions:

   | Secret | Value |
   | --- | --- |
   | `APPLE_CERTIFICATE_P12` | the .p12, base64 encoded |
   | `APPLE_CERTIFICATE_PASSWORD` | the .p12 export password |
   | `APPLE_SIGN_IDENTITY` | `Developer ID Application: NAME (TEAMID)` |
   | `APPLE_ID` | the Apple ID email |
   | `APPLE_TEAM_ID` | the Developer Team ID |
   | `APPLE_APP_PASSWORD` | the app-specific password |

## Signing locally

`make signed-app` does the same signing and notarization on your Mac, against
whatever `make app` last built. It expects notarization credentials in a
keychain profile:

```sh
xcrun notarytool store-credentials sandfort --apple-id you@example.com --team-id TEAMID
```

## The Apple Events entitlement is load-bearing

Notarization requires the hardened runtime, and the hardened runtime refuses to
send Apple Events unless the app carries
`com.apple.security.automation.apple-events`. Sandfort drives UTM entirely
through Apple Events: starting a VM, stopping one, and removing old
registrations during Rebuild. Measured against UTM 4.7.5 with a signed app
bundle:

| Signing | Result |
| --- | --- |
| hardened runtime, no entitlement | `-1743` `errAEEventNotPermitted`, no prompt |
| hardened runtime, with the entitlement | delivered normally |

Without it a notarized build installs, launches, and never starts a VM, silently:
`-1743` is treated as "the user declined Automation", so the app falls back
rather than reporting an error. The entitlement lives in
`tools/packaging/Sandfort.entitlements`, and both the local script and the
workflow refuse to continue if it is missing from the signed app.

## Where to download from

A tagged build publishes a **GitHub Release** carrying two forms of the same
app:

- `Sandfort-x.y.z-NN.dmg` — the download. Open it and drag Sandfort to the
  Applications alias beside it.
- `Sandfort-x.y.z-NN.zip` — the same app for anyone scripting an install, where
  mounting an image is friction rather than affordance.

Do not use the Actions **artifact** for a release. Artifacts are zipped by GitHub
on the way out, so an artifact containing an archive arrives as a zip inside a
zip. Tag builds therefore skip the artifact entirely; only manual runs produce
one, because they have no Release to publish to.

The archive inside that artifact is not redundant packaging. Artifacts do not
preserve the executable bit, so uploading `Sandfort.app` as a directory would
hand back a bundle whose binary cannot run.

## The disk image

`make dmg` builds it from whatever `make app` last produced; `make signed-app`
does it as part of the release path.

**The window layout comes from a committed `.DS_Store`**, not from driving Finder
with AppleScript at build time. Finder scripting needs a real desktop session
and a volume mounted where Finder can see it, which on a CI runner is flaky at
best. Capturing the arrangement once and replaying it needs nothing but
`hdiutil`.

To change it, edit the values at the top of
`tools/packaging/capture-dmg-layout.sh` and run it. It builds a scratch image,
arranges it in Finder, checks that Finder stored what it was told, and only then
overwrites `dmg-layout.DS_Store`. Icon positions are keyed by filename, so
`Sandfort.app` and `Applications` must keep exactly those names.

Two Finder quirks the script exists to survive, both of which produce a layout
that looks captured and is not:

- **Assign through the window, never a variable.** `set opts to the icon view
  options of container window` takes a snapshot; later assignments to `opts`
  report success and change nothing. The first captured layout had 48-point
  icons for this reason.
- **Read the value back before closing the window.** Asking a second Finder
  session afterwards reports defaults rather than what was stored, so the check
  passes or fails at random.

**The app and the image are notarized separately**, which means two submissions
and roughly twice the wait. That is deliberate. Notarizing only the image would
leave the app itself without a ticket, so dragging it to Applications and
launching it offline would fail its first check. The app is stapled before it
goes into the image; the image is stapled after.

## After a release

The workflow verifies the notarized bundle before publishing — `codesign
--verify --strict`, `spctl --assess`, `stapler validate`, and the entitlement
check. None of that proves the app still works.

Download the published archive and confirm the thing only a real run can show:
**quit UTM, create an environment, and watch the VM start on its own.** That is
the behaviour the hardened runtime can silently break.
