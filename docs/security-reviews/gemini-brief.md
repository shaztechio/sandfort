# Your task

You are performing an independent security review of Sandfort, a macOS app that
creates disposable Linux virtual machines in UTM for running untrusted code.

This is a **read-only review**. Do not modify any source file. The only file you
create is `review-gemini.md` in this directory.

## Read these first, in this order

1. `docs/security-model.md` — the threat model and the guarantees the app
   actually claims. **A review that skips this spends its output re-litigating
   decisions that are documented and deliberate**: that the guest password is
   shown in the app, that a VM is not a perfect boundary, that Resume knowingly
   preserves contamination. If you think a documented decision is wrong, say so
   as a separate argued point, not as a finding.
2. `docs/security-review.md` — the shared brief. Scope in priority order, what a
   finding must contain, and how findings will be adjudicated.

## Where to spend your effort

The whole scope is in `docs/security-review.md`. Two parts of it suit you
specifically, because they need a lot held in mind at once rather than pattern
matching:

**1. A specification-conformance pass on `sources/sandfortapp/OpenPGPSignatureVerifier.swift`.**

Load the implementation, all of `tests/sandfortapptests/OpenPGPSignatureVerifierTests.swift`,
and the relevant parts of RFC 4880 together, and check the parser against the
format rather than against intuition. Packet framing and length encodings, MPI
lengths, the algorithm allowlist, Radix-64 armor and CRC-24 handling, v3 versus
v4 signature bodies, and the difference between the stored left-16 digest bits
and real verification.

**This code fails open.** A bounds or parsing mistake turns "invalid signature"
into "accepted", silently, and it is the check that decides whether a downloaded
Linux image is the one the distribution signed. It is the highest value target
in the repository.

**2. Cross-reference the guarantees against what is actually written.**

`docs/security-model.md` lists isolation guarantees: no shared folders, no
clipboard sharing, no automatic USB, no bridged networking, no inbound port
forwarding, offline by default, SSH disabled. For each one, find the key in
`sources/sandfortapp/UTMBundleBuilder.swift` that enforces it in the bundle the
app actually writes — not merely a test asserting it. A guarantee with no
corresponding key is a real finding.

## What every finding must contain

- **Location** — file and line.
- **A concrete failure scenario** — specific inputs or state, and the wrong
  outcome they produce. "This could be unsafe" is not a finding.
- **Severity**, argued in terms of the threat model in `security-model.md`.
- **Reachability** — can this be reached from the app's own flows, and how?
- **A failing test**, not a patch. Propose a test that fails against the current
  code. `OpenPGPSignatureVerifierTests.swift` shows the house style, including a
  negative set covering tampered payload, tampered signature, unpinned key,
  corrupted armor, truncated packet, and garbage input. **A finding that cannot
  be written as a failing test is almost always wrong**, and trying is the
  cheapest way to find out.

## Output

Write `review-gemini.md` in this directory. Order findings by severity, worst
first. If you find nothing in a scope area, say so explicitly — that is useful
information, and more honest than padding.

End with a short section listing what you did **not** examine closely, so the
gaps are known rather than assumed covered.
