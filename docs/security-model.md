# Security model

## Enforced boundaries

- Official immutable cloud images with profile-specific pinned SHA-256 values.
  Ubuntu 24.04, Fedora 44, Debian 13, and openSUSE Leap 16 are currently
  supported.
- UTM QEMU backend with Apple Hypervisor acceleration.
- An independent protected setup baseline per Linux environment, used to restore
  that environment's selected instance disk and UEFI state before every clean run.
- Trusted setup uses temporary NAT internet access to download signed
  distribution packages. Clean instances default to isolation from both host and Internet.
  Explicit Internet-enabled launches relax UTM's guest-to-host isolation for
  that instance; no bridged networking is used.
- No port forwards, host directory sharing, synchronized clipboard, or automatic
  USB sharing.
- Distribution-specific cloud-init disables SSH, denies unsolicited inbound
  traffic, applies upgrades, and enables unattended security updates. Ubuntu
  uses UFW and unattended-upgrades; Fedora uses firewalld and
  security-only DNF5 automatic updates while requiring SELinux enforcing mode;
  Debian uses UFW, AppArmor, and unattended-upgrades; openSUSE Leap uses
  firewalld and an app-owned daily `zypper patch --category security` timer
  while requiring SELinux enforcing mode.
- A unique initial guest password is generated locally and shown in the app.
  Rebuild allows an explicit replacement after local validation; cloud-init
  safely quotes it before embedding it in the NoCloud seed. Its authentication
  quality and limitations are documented in `password-strength.md`.
- Distribution qualification uses a separately signed app identity, Application
  Support root, allowed-profile set, and UTM name prefix. Fedora, Debian, and
  openSUSE verification builds cannot resolve production state. Production
  baselines persist their exact Ubuntu, Fedora, Debian, or openSUSE profile
  identity and checksum.

The initial provisioning VM becomes the persistent, clearly labeled Protected
Baseline. The user must wait for cloud-init to finish and shut it down before
**Finish Setup** creates Instance 1. Additional numbered instances are full,
independent copies with unique VM identifiers, MAC addresses, disks, and UEFI
state, so they can run concurrently. Changes remain only in that instance until
**Reset & Run Clean** unregisters the stopped VM and recreates its bundle from
the baseline so an open UTM library cannot reuse a cached network setting. The
permanent app-level number and optional label remain, while the disposable VM
UUID, MAC address, disk, and UEFI state are replaced. **Resume Instance** deliberately preserves
the instance's files, processes, suspended state, and last explicit network mode;
it must be treated as contaminated. Users must never run the Protected Baseline
or relaunch an instance directly from UTM.

Multiple Linux environments share only verified source-image downloads. Their
mutable state, baselines, instances, credentials, VM identifiers, MAC addresses,
disks, and UEFI state are separate. Rebuild and Delete Environment resolve the
selected environment before unregistering any exact UTM names; they never infer
another environment from a global default.

Instance deletion is app-owned and allowed only when the instance disk is not
locked by a running VM. Sandfort asks UTM to unregister the exact saved VM name,
waits for UTM to confirm its removal, moves the bundle to macOS Trash, and only
then updates app state. **Rebuild** is the only app action that deletes the Protected Baseline.
After its destructive confirmation, rebuild uses a native Apple Event addressed
to UTM to remove only the exact baseline and instance names held in app state;
it does not invoke AppleScript, a shell command, or UI automation. A denied
macOS Automation permission aborts before local VM data is deleted. If UTM is not
running, Sandfort launches it with `NSWorkspace` and waits for its Apple Event
interface to become ready. The workflow also waits until UTM can no longer resolve
each exact VM name before removing the parent directory, so UTM cannot race the
filesystem cleanup or retain a stale registration.

## Third-party software installed into a guest

Two tools are downloaded from their vendors during baseline setup rather than
coming from the distribution: the Node.js LTS archive and Visual Studio Code.
Both are fetched over HTTPS and verified against the vendor's own published
SHA-256, and a mismatch fails the build so no baseline is created.

Visual Studio Code is installed from Microsoft's tarball, never from their
`.deb` or `.rpm`. Those packages add Microsoft's repository and signing key to
the guest in their post-install scripts, which would give every sandbox a
standing auto-update channel to a third party and a new trusted key. The
tarball adds neither, and a test asserts no repository or key is introduced.

Visual Studio Code is proprietary Microsoft software, it is optional, and it is
installed with stock settings, so its telemetry is on by default. An
Internet-enabled instance running it can therefore report usage to Microsoft.
Clean instances default to offline, where it cannot.

## Image signature verification (security-critical code)

`OpenPGPSignatureVerifier.swift` and `TrustedSigningKeys.swift` are
security-critical and are called out as such here because a signature verifier
has an asymmetric failure mode: a bug makes it accept a signature it should
reject, and nothing downstream notices. Treat both files as review-gated.

The verifier parses OpenPGP detached signatures and checks them with
Security.framework RSA PKCS#1 v1.5, so no `gpg` dependency or other runtime
shell tool is introduced. Its rules are deliberate:

- Every read is bounds-checked; declared lengths are never trusted.
- Only what is needed is accepted. Unknown packet versions, non-RSA algorithms,
  SHA-1 and MD5, text-mode signatures, and partial or indeterminate packet
  lengths are refused rather than skipped or guessed.
- The stored left-16 digest bits are a corruption check only, never proof.
- The trust anchor is the pinned fingerprint in `TrustedSigningKeys.swift`. A
  signature verifies against a key; only a pinned fingerprint makes it the right
  key. Keys are bundled and reviewed, never fetched at runtime, because a key
  retrieved alongside a signature proves nothing about who built the artifact.

Coverage is per profile and deliberately recorded rather than assumed. Ubuntu
and openSUSE publish detached signatures; Fedora publishes a clearsigned
manifest, which is verified over canonicalized text with values read only from
the verified message; Debian publishes no signature alongside its cloud manifest,
so that profile remains hash-only and `linux-profile-provenance.md` says so
plainly. The two signature forms are kept strictly apart: each entry point
demands the signature type it prepared its payload for, so a text-mode signature
can never be verified as raw bytes.

This runs at profile intake, not in the download path. The pinned SHA-256 in
reviewed source is already the stronger runtime anchor: an attacker who can
substitute an image still cannot match the pinned hash. What the signature adds
is provenance, confirming that the pinned value is one the distribution signed
rather than one merely observed at a URL. Signature coverage is therefore
recorded per profile in `linux-profile-provenance.md`, and a profile whose
signature has not been verified must say so rather than imply that it was.

## First-run disclosure

Before any baseline can be created, Sandfort presents the limits in
`SafetyAcknowledgement.swift` and requires an explicit acknowledgement, stored
per app identity so a qualification build never inherits the production answer.
An unreadable or older record re-prompts rather than passing.

This is a safety disclosure first: the residual risks below are of little use to
a user who only meets them in a document they never open. It is also the notice
that accompanies the Apache-2.0 warranty disclaimer. It must stay accurate, and
must never suggest the sandbox makes the user safe.

## Residual risk

A VM reduces risk; it is not a perfect malware boundary. Connected malware can
still contact Internet services, steal anything entered into the guest, attack
other systems, or exploit a vulnerability in the guest OS, QEMU, UTM, or macOS. Never
put personal accounts, SSH keys, cloud credentials, password managers, wallets,
work files, or secrets in this VM. Keep UTM and macOS updated.
