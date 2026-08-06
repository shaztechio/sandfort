# Security review

The brief for an external security review of Sandfort, run independently by more
than one model. Each reviewer gets the same scope and the same output format, so
their findings can be compared rather than merely collected.

The point of running several is **disagreement**. Three reviewers agreeing
usually means they share a blind spot; a finding only one of them raises is the
interesting case.

## Read this first

A review that does not know the threat model spends most of its output
re-litigating decisions that are already documented and deliberate — that the
guest password is displayed in the app, that a VM is not a perfect boundary,
that Resume deliberately preserves contamination.

Read [security-model.md](security-model.md) before starting. Review Sandfort
against the guarantees it actually makes. If you believe a documented decision is
wrong, say so as a separate argued point rather than as a finding.

## Scope, in priority order

Depth on the right files beats coverage. The app is about 7,000 lines; this is
where the risk is concentrated.

| Priority | Target | Why |
| --- | --- | --- |
| 1 | `OpenPGPSignatureVerifier.swift` | Hand-written OpenPGP parsing, and **it fails open**. A bounds or packet-parsing mistake turns "invalid signature" into "accepted", with nothing visibly wrong. Highest value per line in the repository. |
| 2 | `CloudInit.swift`, `FedoraCloudInit.swift`, `DebianCloudInit.swift`, `OpenSUSECloudInit.swift`, `GuestProvisioningSupport.swift` | A user-supplied password and an optional custom script are embedded into YAML that runs as **root** inside the guest. Quoting and escaping are the entire defence. |
| 3 | `UTMBundleBuilder.swift` | The isolation configuration itself. A missing or wrong key silently enables sharing, clipboard, USB, or bridged networking, and nothing appears broken. |
| 4 | `DiskUtilities.swift`, `ISO9660Writer.swift` | Byte-level parsing and generation, including headers read from a downloaded image. |
| 5 | `SandfortWorkflow.swift` | Owns the destructive paths — rebuild, delete environment, delete instance — and the window between verifying an image and using it. |
| 6 | `UTMRegistryController.swift`, `TrustedSigningKeys.swift` | VM targeting by name, and fingerprint pinning of bundled signing keys. |

**Out of scope:** the SwiftUI view layer. It is a large share of the remaining
lines and has almost no security surface. Skip it unless something in scope
leads there.

## What a finding must contain

Findings without these are not actionable and will be closed:

- **Location** — file and line.
- **A concrete failure scenario** — specific inputs or state, and the wrong
  outcome they produce. "This could be unsafe" is not a finding.
- **Severity**, with the reasoning behind it, in terms of the threat model.
- **Whether it is reachable** from the app's own flows, and how.

Propose **a failing test rather than a patch.** The repository already works this
way: `OpenPGPSignatureVerifierTests` keeps a negative set covering tampered
payload, tampered signature, unpinned key, corrupted armor, truncated packet, and
garbage input. A finding that cannot be expressed as a test that fails against
current code is almost always wrong, and writing that test is the cheapest way to
find out.

Write findings to `review-<tool>.md` at the repository root, and do not commit
it. Work in a separate git worktree so reviewers cannot see each other's output.

## Questions worth asking

Not a checklist to be answered in order — the interesting bugs will be elsewhere.
These are the ones a reader of this codebase should be curious about:

- Can any input make the verifier accept a signature it should reject? Truncated
  packets, absurd MPI lengths, unexpected algorithm identifiers, a key whose
  fingerprint matches by prefix rather than in full.
- Can a password or custom script that passes validation still break out of its
  quoting in cloud-init? What about one that is valid YAML but changes the
  meaning of the document?
- Does every isolation guarantee in `security-model.md` have a corresponding
  assertion in the bundle the app actually writes — not merely in a test?
- Between verifying an image's SHA-256 and using it, what could change on disk,
  and would anything notice?
- Can an instance's optional display name influence which VM gets deleted?
- Does anything fail **open**? Where a check cannot complete, does the code
  continue as though it passed?

## Adjudication

Expect 30 to 60 raw findings across three reviewers, most of them wrong. Without
a filter, triage costs more than the review saves.

1. Collect each reviewer's file separately.
2. Merge into one table, deduplicated by file and line.
3. **Attempt a failing test for each finding.** This is the gate. Findings that
   survive are real; most of the rest evaporate at this step.
4. Survivors become issues, with the `security-model` label where they touch a
   guarantee.

## The outputs

Each reviewer's brief and the review it produced are archived verbatim in
[`security-reviews/`](security-reviews/), alongside what came of each finding.
The reviews are the raw material; the adjudication comment on each tracking
issue is the authoritative outcome, and in two cases it differs from what the
reviewer proposed.

## Two constraints specific to this repository

**Never expose the signing material.** The Developer ID `.p12`, the 1Password
export, and the app-specific password must not go near any review tool. The
source is public; those are not.

**Guest-side fixes are expensive.** Anything embedded in the guest — cloud-init,
provisioning, credentials, services — forces every existing user to Rebuild, and
a new app binary alone is not enough. Host-side fixes in the verifier or the
bundle builder cost nothing. Where a finding admits both, that difference is
worth stating in the writeup.
