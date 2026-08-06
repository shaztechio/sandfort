# Security review outputs

The briefs handed to each reviewer and the reviews they produced, kept verbatim.
The shared scope and the adjudication gate are in
[`../security-review.md`](../security-review.md).

These are the raw outputs, archived as written. They are **not** the record of
what was decided — every finding was adjudicated separately, and two were
adjudicated differently from how their reviewer proposed. The adjudication
comment on each tracking issue is the authoritative outcome.

| Reviewer | Model | Brief | Review | Issue | Findings |
| --- | --- | --- | --- | --- | --- |
| Claude | Opus 5 | [claude-brief.md](claude-brief.md) | [claude-review.md](claude-review.md) | [#9](https://github.com/shaztechio/sandfort/issues/9) | 1 Medium, 2 Low, 1 informational |
| Gemini | 3.1 Pro | [gemini-brief.md](gemini-brief.md) | [gemini-review.md](gemini-review.md) | [#11](https://github.com/shaztechio/sandfort/issues/11) | 1 confirmed, 1 downgraded |
| Codex | — | [codex-brief.md](codex-brief.md) | pending | [#10](https://github.com/shaztechio/sandfort/issues/10) | — |

## What came of it

| Finding | Outcome |
| --- | --- |
| `repairBundle` inferred isolation policy from a user-controlled display name | Fixed, [#19](https://github.com/shaztechio/sandfort/pull/19) |
| `repairBundle` did not reassert the clipboard, directory-share, and USB keys | Fixed, [#17](https://github.com/shaztechio/sandfort/pull/17) |
| `verifyClearsignedMessage` returned text it had not verified | Fixed, [#20](https://github.com/shaztechio/sandfort/pull/20) |
| An oversized public-key packet trapped the process | Fixed, [#20](https://github.com/shaztechio/sandfort/pull/20) |
| Clearsigned documents with CRLF line endings were rejected | Fixed, [#20](https://github.com/shaztechio/sandfort/pull/20) |
| Verify-then-use window on the image cache | Open, [#18](https://github.com/shaztechio/sandfort/issues/18) |

## Three things worth keeping from how this went

**The reviews did not overlap at all.** Gemini found `repairBundle` failing to
reassert isolation keys; Claude found `repairBundle` deriving policy from a
display name. Same function, same underlying shape — *reset paths reconstruct
less state than creation paths, and infer what they do not carry* — reached from
two directions, with neither reviewer seeing the other's half. That is the
entire argument for running more than one.

**A correct finding does not imply a correct fix.** Claude's finding 2 was right
that the verifier returned bytes it had not verified, and its proposed test
asserted that dash-escaped and trailing-whitespace documents must be rejected.
They must not: RFC 4880 §7.1 *requires* a line beginning with `-` to be escaped,
and excludes trailing whitespace from the hash precisely so transport may add it.
Taking the remedy as given would have broken conformant vendor manifests. The
finding was kept and the remedy replaced.

**The clean results are findings too.** Both briefs asked reviewers to say so
explicitly when a scope area yielded nothing, and the cloud-init quoting pass
came back clean with its evidence shown. On code that embeds a password and a
custom script into a document that runs as root, that is the more valuable half
of the result, and it is the half a review normally leaves unsaid.
