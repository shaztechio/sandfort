# A core-language spike

[WINDOWS.md](WINDOWS.md) lists the core language as the first open question and
warns it is expensive to revisit. It is also the rare architectural decision that
is **testable rather than arguable**, because this repository already contains
the thing a port would have to reproduce exactly.

Run this before phase 0. It changes what phase 0 is for.

## What is actually being decided

Not the UI. SwiftUI does not exist on Windows, so the shell is WinUI 3 or
Avalonia whichever way this goes. What is being decided is who owns roughly
3,800 lines of portable core — the guest contract in `CloudInit.swift` and its
three siblings, `GuestProvisioningSupport.swift`, `LinuxGuestCatalog.swift`, the
OpenPGP verifier, and the QCOW2 and ISO writers.

**Swift** shares those files. **C#** or **Rust** rewrites them.

## Why the rewrite option has a hard test

`GuestArchitectureTests` pins a SHA-256 of every profile's generated
`user-data`, per tool selection. [AGENTS.md](../AGENTS.md) calls it the only
assertion in the suite that can prove a guest did *not* change; everything else
is a `contains`.

That test turns "can we hand-port the guest contract?" into a yes-or-no
question. A second implementation does not merely need to produce working
cloud-init — it needs to produce **byte-identical** cloud-init, because the same
profile revision must mean the same guest on every host. A stray space is a
different guest, and a guest change forces every user to Rebuild.

So the spike is: **reproduce one pinned digest in the candidate language.**

## The target

Use `ubuntu-24.04-arm64` with the `bare` tool selection. It is the smallest
generated output — no Node.js, no VS Code, no custom script — so it exercises
the structure without the vendor-download machinery.

Read the expected digest from
`tests/sandfortapptests/GuestArchitectureTests.swift`, in
`goldenUserDataDigests`. **Do not copy it into this page or into the spike's
code.** It moves when a profile revision moves, and a second copy is a second
thing to forget.

The test also defines what is hashed, and the definition is load bearing:

- credentials fixed at username `sandfort`, password `golden-test-password`
- the seed ISO generated, then the substring from `#cloud-config` through the
  first occurrence of `$UPTIME seconds`
- that substring hashed as UTF-8

`meta-data` carries a fresh UUID per call and is deliberately outside the hash.

## Step 0, on the Mac: get the text, not just the digest

Do this first. A digest tells you that you failed and nothing about where.

Dump the reference `user-data` to a file from the macOS side — a scratch test or
a few lines in a throwaway target is enough — and carry that file to the machine
you are porting on. Then you are diffing two texts instead of bisecting blind
against 64 hex characters.

Do not commit the dump. It is derived, and a checked-in copy is a third place
the guest contract lives.

## Step 1: port the smallest slice

Port only what `bare` reaches. In practice that is the package list, the
verification commands, the logging preamble, and the completion message —
`GuestProvisioningSupport`'s vendor downloads are entirely skipped in this
variant, which is why it is the right first target.

Hash your output the same way and compare. Then diff against the reference when
it does not match, which it will not on the first attempt.

## Step 2: the traps, in the order they will bite

These are the differences that produce a working guest and a different hash.

1. **Line endings.** The output must be LF. A Windows port is the single most
   likely place in this project to emit CRLF, and it will be invisible in every
   editor you check it in.
2. **Encoding.** UTF-8, no BOM. .NET has historically been happy to add one.
3. **Multiline string literals.** Swift's `"""` strips indentation relative to
   the closing delimiter. C#'s raw string literals have a similar rule that is
   not the same rule, and Rust's has neither. This is the most likely source of
   a real divergence rather than a mechanical one.
4. **Escaping.** The generated script contains `printf '\n[Sandfort] %s\n'`. The
   backslashes are literal in the output; how many you write in source differs
   per language.
5. **Empty-to-blank-line collapse.** `customSetup?.writeFileEntry ?? ""`
   contributes an empty string in the `bare` case. Whether that leaves a blank
   line or nothing is a byte-level decision the Swift source makes implicitly.
6. **List joining.** `packages.map { "  - \($0)" }.joined(separator: "\n")` —
   two-space indent, no trailing newline from the join itself.

## Step 3: only then, `recommended`

If `bare` reproduces, try `recommended`. It adds the Node.js and VS Code
installers, their checksum verification, and `curlRetryOptions`, so it is a
fairer sample of the whole contract's difficulty. `custom` adds the script
embedding and the rewritten logging preamble and is the hardest of the three.

Getting all three is not required to decide. Getting `bare` and failing to see a
path to the others is already an answer.

## If you are evaluating Swift instead

The spike is a different shape, because reproducibility is not in question —
sharing the file guarantees it. What is in question is whether the toolchain
carries its weight.

Build the portable core on Windows with no UI, in a scratch SwiftPM package
outside this repository, and see how far Foundation gets you. `NSFileCoordinator`
is already known absent. Note what else is, and how the Windows toolchain
behaves on a 733-line bounds-checked parser.

That is the same question phase 0's package split would answer properly, done
cheaply and without committing to the split first.

## Reading the result

| Outcome | What it means |
| --- | --- |
| `bare` reproduces in a day, traps are mechanical | Hand-porting is viable. The decision becomes a genuine trade-off between one-time rewrite cost and a permanent FFI seam. |
| `bare` reproduces only after fighting the string literals | Every future guest change will fight them too, in two languages. Weigh that against the seam. |
| `bare` does not reproduce | On the easiest of four profiles, in the smallest of three variants. That is the answer. |
| Swift core builds cleanly on Windows | The FFI seam is the only real cost, and phase 0's split is clearly worth doing. |
| Swift core does not build | Say so plainly in `WINDOWS.md`. It is the load-bearing assumption under "what ports unchanged". |

## What this does not settle

The FFI seam. A Swift core on Windows still needs a boundary to a C# or C++ UI,
because every Windows UI toolkit lives on the other side of one. The plan's
phrasing — that only the view layer needs writing — is true and quietly includes
that marshalling work. This spike does not measure it, and it should not be
discovered in phase 5.

## Afterwards

The answer belongs in `WINDOWS.md`, as a decision with the evidence attached
rather than as a preference. It also decides how much of phase 0's package split
pays for itself: splitting the package so a Windows runner can build a Swift core
is worth little if no Windows runner will ever build one.
