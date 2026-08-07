# Your task

You are performing an independent security review of Sandfort, a macOS app that
creates disposable Linux virtual machines in UTM for running untrusted code.

This is a **read-only review**. Do not modify any source file. The only file you
create is `review-codex.md` in this directory.

## Read these first, in this order

1. `docs/security-model.md` — the threat model and the guarantees the app
   actually claims. **A review that skips this spends its output re-litigating
   decisions that are documented and deliberate**: that the guest password is
   shown in the app, that a VM is not a perfect boundary, that Resume knowingly
   preserves contamination. If you think a documented decision is wrong, argue it
   separately rather than filing it as a finding.
2. `docs/security-review.md` — the shared brief. Scope in priority order, what a
   finding must contain, and how findings are adjudicated.

## Where to spend your effort

The full scope is in `docs/security-review.md`. Two parts of it are yours,
because they reward close mechanical reasoning rather than breadth:

**1. The byte-level code.**

`sources/sandfortapp/DiskUtilities.swift` parses QCOW2 headers — including from
an image just downloaded off the Internet — and resizes them in place.
`sources/sandfortapp/ISO9660Writer.swift` generates the NoCloud seed image that
carries the guest's credentials and any custom setup script. Both do arithmetic
on lengths and offsets taken from data the app did not write. Look for integer
overflow, truncation, unchecked casts, off-by-one in sector maths, and any place
a length from the file decides how much memory is read or written.

**2. `sources/sandfortapp/SandfortWorkflow.swift`.**

It owns the destructive paths — rebuild, delete environment, delete instance —
and the window between verifying an image's SHA-256 and using it. Look for
places where a failure leaves state half-changed, where an error is swallowed
with `try?` and execution continues as though it succeeded, and where a name or
path derived from user input decides which VM gets removed.

## Then do the thing you are best at

**Turn every finding into a test that fails against the current code.** This is
the adjudication gate for all three reviews in this series, and it is where the
signal is: a finding that arrives with a failing test needs no further argument,
and one that cannot be written as a test is almost always wrong.

If you cannot express a finding that way, say so explicitly and explain why. That
is useful information, not a failure.

The house style is in `tests/sandfortapptests/` — see
`OpenPGPSignatureVerifierTests.swift` for how negative cases are written:
tampered payload, tampered signature, unpinned key, corrupted armor, truncated
packet, garbage input.

## Already known — do not spend the review re-finding these

You are reviewing `main` at 2f0707b, which is **after** two other passes in this
series landed. Their findings are fixed and in the history; you will not find
them, and that is expected rather than evidence the code is clean:

- `repairBundle` inferred a VM's isolation policy from its user-controlled
  display name (#19). It now takes a `VirtualMachineRole` from the caller. This
  changed `SandfortWorkflow.swift`, which is in your scope — read the role
  derivation in `currentState()` sceptically, it is new.
- `repairBundle` did not reassert the clipboard, directory-share, and USB keys
  (#17).
- `verifyClearsignedMessage` returned text it had not verified, and an oversized
  key packet trapped the process (#20).

One finding is **already filed and still open**: **#18**, the window between an
image's SHA-256 verification and its use. Your scope names that window
explicitly. Raise it only if you have something the issue does not already say —
a wider window than it describes, a second instance of the pattern elsewhere, or
a concrete exploitation path. "There is a TOCTOU here" is already recorded.

## What every finding must contain

- **Location** — file and line.
- **A concrete failure scenario** — specific inputs or state, and the wrong
  outcome. "This could be unsafe" is not a finding.
- **Severity**, argued in terms of the threat model, not in the abstract. An
  attack requiring capabilities that already defeat the app is not a finding
  about this code.
- **Reachability** — can this be reached from the app's own flows, and how?
- **A failing test**, not a patch.

## Output

Write `review-codex.md` in this directory. Order findings by severity, worst
first. If a scope area yields nothing, say so explicitly — a clean result on
code that fails open is a real finding, not an empty one.

End with a short section listing what you did **not** examine closely, so the
gaps are known rather than assumed covered.
