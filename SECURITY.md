# Security policy

Sandfort builds disposable virtual machines for running untrusted code. A flaw
in it can cause someone to trust a sandbox that is not actually isolated, so
security reports are welcome and taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting instead:

1. Go to the [Security tab](https://github.com/shaztechio/sandfort/security).
2. Choose **Report a vulnerability**.

That opens a private advisory visible only to you and the maintainers. If
private reporting is unavailable to you, contact the maintainer through their
GitHub profile and ask for a private channel before sending details.

Please include:

- What an attacker gains, not only what is technically wrong.
- The Sandfort version (**Sandfort → About**) and the guest profile and revision
  involved, if any.
- macOS and UTM versions, and the Mac model.
- Steps to reproduce, or a proof of concept.
- Any relevant part of `/var/log/sandfort-setup.log` from inside the guest.

**Never include a real password, key, token, or anything else sensitive.** If a
guest password is relevant, rebuild the environment first so the value you share
no longer protects anything.

## What to expect

- An acknowledgement within roughly a week.
- An assessment of whether the report is in scope, with reasoning.
- Credit in the advisory and release notes, unless you prefer otherwise.

Sandfort has no paid bounty program.

## In scope

Anything that weakens the boundary the tool claims to provide:

- Escaping guest isolation, or reaching the macOS host from a sandbox instance.
- Defeating image verification: accepting a mismatched checksum, or a flaw in
  `OpenPGPSignatureVerifier.swift` that makes an invalid signature verify. This
  code fails open when it is wrong, so parsing bugs there matter.
- A clean instance that is not actually clean: baseline state surviving a
  **Reset & Run Clean**, or one instance reaching another's disk.
- Network isolation failures: an offline instance reaching the network, or
  unexpected inbound reachability.
- Unintended host exposure — shared directories, clipboard, USB, port forwards,
  or bridged networking appearing in a generated UTM configuration.
- Credential disclosure beyond what `docs/password-strength.md` documents.
- Anything letting a guest modify the protected baseline.

## Known limitations, not vulnerabilities

These are documented design decisions. Reports about them are welcome as
discussion, but they are not treated as vulnerabilities:

- **A VM is not a perfect malware boundary.** A guest escape in QEMU, UTM, or
  macOS itself affects Sandfort but is not a Sandfort flaw. Report those
  upstream. See `docs/security-model.md`.
- **The generated guest password is not a security boundary.** It protects a
  local login on a disposable guest, not the disk. Anyone holding the virtual
  disk can read it without any password. See `docs/password-strength.md`.
- **The virtual disk is not encrypted.**
- **Debian images are verified by pinned checksum only.** Debian publishes no
  signature alongside its cloud manifest. This is recorded in
  `docs/linux-profile-provenance.md` rather than implied to be otherwise.
- **Custom setup scripts run as root in the guest during baseline creation.**
  That is their purpose. They never run on the host.
- **Internet-enabled instances can reach the Internet**, including by malware
  running inside them. Offline is the default for clean runs.

## Supported versions

Sandfort is pre-1.0 and moves fast. Only the latest `main` receives fixes.
There are no backports to earlier versions or to already-built baselines; a
guest-side fix requires a **Rebuild**, which is why profile revisions exist.
