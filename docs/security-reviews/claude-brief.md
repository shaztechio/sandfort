# Your task

You are performing an independent security review of Sandfort, a macOS app that
creates disposable Linux virtual machines in UTM for running untrusted code.

This is a **read-only review**. Do not modify any source file. The only file you
create is `review-claude.md` in this directory.

Two other models are reviewing the same code separately. Do not look for their
findings and do not try to guess them. The value of this exercise is
disagreement: a finding only one reviewer raises is the interesting case.

## Read these first, in this order

1. `docs/security-model.md` — the threat model and the guarantees the app
   actually claims. **A review that skips this spends its output re-litigating
   decisions that are documented and deliberate**: that the guest password is
   shown in the app, that a VM is not a perfect boundary, that Resume knowingly
   preserves contamination. If you think a documented decision is wrong, argue
   it separately rather than filing it as a finding.
2. `docs/security-review.md` — the shared brief. Scope in priority order, what a
   finding must contain, and how findings are adjudicated.

## Where to spend your effort

The full scope is in `docs/security-review.md`. Two parts of it are yours,
because they reward sustained reasoning over a long file rather than pattern
matching:

**1. `sources/sandfortapp/OpenPGPSignatureVerifier.swift`.**

687 lines of hand-written OpenPGP parsing, and **it fails open**: a bounds or
packet-parsing mistake turns "invalid signature" into "accepted", silently. It
is the check that decides whether a downloaded Linux image is the one the
distribution actually signed.

Read it against `tests/sandfortapptests/OpenPGPSignatureVerifierTests.swift` and
against RFC 4880. Packet framing and length encodings, MPI lengths, the
algorithm allowlist, Radix-64 armor and CRC-24, v3 versus v4 signature bodies,
and the difference between the stored left-16 digest bits and real verification.

**2. The guest provisioning quoting.**

`CloudInit.swift`, `FedoraCloudInit.swift`, `DebianCloudInit.swift`,
`OpenSUSECloudInit.swift`, and `GuestProvisioningSupport.swift`. A user-supplied
password and an optional custom script are embedded into YAML that runs as
**root** inside the guest. Quoting and escaping are the entire defence.

Ask whether anything that passes validation can still change the meaning of the
generated document — valid YAML that parses differently than intended is as bad
as YAML that breaks.

## What every finding must contain

- **Location** — file and line.
- **A concrete failure scenario** — specific inputs or state, and the wrong
  outcome. "This could be unsafe" is not a finding.
- **Severity**, argued in terms of the threat model, not in the abstract. An
  attack requiring capabilities that already defeat the app entirely is not a
  finding about this code.
- **Reachability** — can this be reached from the app's own flows, and how?
- **A failing test**, not a patch. A finding that cannot be written as a test
  that fails against current code is almost always wrong, and writing it is the
  cheapest way to find out.

## Output

Write `review-claude.md` in this directory. Order findings by severity, worst
first.

If a scope area yields nothing, **say so explicitly**. A clean result on code
that fails open is a real finding rather than an empty one, and it is the part
reviewers usually leave unsaid.

End with a short section listing what you did **not** examine closely, so the
gaps are known rather than assumed covered.
