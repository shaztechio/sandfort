# Security review — Claude

Independent review against `docs/security-model.md` and the brief in
`docs/security-review.md`. Effort was concentrated on the two assigned areas:
`OpenPGPSignatureVerifier.swift`, and the guest-provisioning quoting in the four
cloud-init files plus `GuestProvisioningSupport.swift`. One finding outside those
two areas is included because it turned up while answering the brief's own
question about instance display names, and it is the most serious thing I found.

Every finding below was reproduced against a copy of the repository at `d18e2d6`.
Where I say a test fails, I ran it.

## Summary

| # | Severity | Location | Finding |
| --- | --- | --- | --- |
| 1 | Medium | `UTMBundleBuilder.swift:97-113` | `repairBundle` decides a VM's role by substring-matching a user-editable display name; an instance label containing `Baseline Setup` silently turns off `IsolateFromHost` on an offline instance |
| 2 | Low | `OpenPGPSignatureVerifier.swift:245-283` | `verifyClearsignedMessage` returns text that is not the text the signature covers; several materially different documents verify under one signature |
| 3 | Low | `OpenPGPSignatureVerifier.swift:167` | A public-key packet larger than 65535 bytes traps the process instead of throwing — a declared length used unchecked, inside a `try?` that cannot catch it |
| 4 | Informational | `SandfortWorkflow.swift:592-616` → `UTMBundleBuilder.swift:28` | Nothing re-verifies the cached image between its SHA-256 check and the copy into the bundle |

**Scope area 2 (guest provisioning quoting) produced no findings.** That is a
result, not an omission; the evidence is in its own section below.

---

## 1. `repairBundle` infers a VM's isolation policy from a user-controlled display name

**Severity: Medium.** High impact, low likelihood. It silently voids the app's
central claim — that a clean instance is isolated from host and Internet — and
the UI goes on reporting the opposite. It requires the user to type a particular
substring, and no attacker (guest malware included) can choose it for them.

**Location:** `sources/sandfortapp/UTMBundleBuilder.swift:97-113`.

```swift
let name = (plist["Information"] as? [String: Any])?["Name"] as? String
let isSetup = name?.hasPrefix("Sandbox Ubuntu Setup") == true
    || name?.contains("Baseline Setup") == true
let isProtectedBaseline = name?.contains("Protected Baseline") == true
let isBaseline = isSetup || isProtectedBaseline
plist["Display"] = isBaseline ? [] : [displayConfiguration]
plist["Serial"] = isBaseline ? [serialTerminalConfiguration] : []
...
if isSetup { networks[index]["IsolateFromHost"] = false }
else if isProtectedBaseline { networks[index]["IsolateFromHost"] = true }
```

`Information.Name` is not app-private. `SandfortWorkflow.swift:679-682` builds an
instance's VM name by interpolating the user's label:

```swift
private func instanceName(number: Int, label: String? = nil, tag: String) -> String {
    let labelComponent = label.map { " — \($0)" } ?? ""
    return "\(environment.vmNamePrefix) — Instance \(number)\(labelComponent) — \(tag)"
}
```

`SandboxInstance.normalizedLabel` (`SandfortConfiguration.swift:64-69`) only
collapses whitespace and caps the length at 48 characters. It does not constrain
the content.

**Failure scenario.**

1. The user creates Instance 2 **Offline**. `setCleanNetworkMode(.offline)` writes
   `IsolateFromHost = true`.
2. The user picks **Rename Instance…** (`EnvironmentDetailView.swift:268`, free-text
   `TextField` at `ContentView.swift:143`) and types `Baseline Setup` — or anything
   containing it, e.g. `repro for Baseline Setup bug`.
3. `renameInstance` (`SandfortWorkflow.swift:421-422`) writes the new name into the
   instance's `config.plist` through `setDisplayName`.
4. The next `currentState()` — which runs at the start of *every* workflow action,
   including `resumeInstance`, and calls `repairBundle` on each instance at
   `SandfortWorkflow.swift:138-141` — reclassifies that instance as the setup VM and
   sets `IsolateFromHost = false`.
5. `resumeInstance` (`SandfortWorkflow.swift:469-480`) launches the bundle as it
   stands. It never calls `setCleanNetworkMode`, deliberately: Resume is documented
   to preserve the instance's last explicit network mode.

Net result: an instance the user chose to run offline, and which the app still
lists as offline, boots with host and Internet reachability. In UTM's Emulated
mode `IsolateFromHost` is what produces the offline behaviour — the app's own
`setCleanNetworkMode` maps `mode == .offline` directly onto it — so clearing it is
exactly the Internet-enabled configuration. This contradicts
`security-model.md`: *"Clean instances default to isolation from both host and
Internet. Explicit Internet-enabled launches relax UTM's guest-to-host isolation
for that instance"* — here it is relaxed with no explicit choice at all.

Two secondary effects from the same branch, both reproduced:

- The instance loses its display (`Display = []`) and gains a serial terminal, so
  a disposable VM meant to present a GNOME desktop comes up as a root console.
  This one is at least visible to the user.
- A label containing `Protected Baseline` forces `IsolateFromHost = true` on an
  instance the user explicitly launched **Internet-enabled**, overriding that
  choice in the safe direction but still silently.

**Reachability:** entirely through the app's own UI. Rename Instance, and the same
label field on **New Clean Sandbox** (`SandfortViewModel.swift:456-458`). No
external attacker is involved; the user is the source of the string, which is why
this is Medium rather than High.

**Failing test** (add to `RepairBundleIsolationTests`). Fails against current code
on both assertions:

```swift
/// The label is user-supplied free text. It must not be able to reclassify an
/// instance as the setup VM and drop its isolation.
func testAnInstanceLabelCannotTurnOffHostIsolation() throws {
    let label = try XCTUnwrap(SandboxInstance.normalizedLabel("Baseline Setup"))
    let url = try bundle(
        named: "Sandfort — Ubuntu 24.04 LTS — Instance 2 — \(label) — A1B2C3",
        sharingEnabled: false
    )
    // Overwrite Network with what setCleanNetworkMode(.offline) actually writes.
    var plist = try repaired(url)
    plist["Network"] = [["IsolateFromHost": true, "PortForward": []]]
    plist["Display"] = [["Hardware": "virtio-gpu-pci"]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("config.plist"))

    try UTMBundleBuilder().repairBundle(at: url, profile: LinuxGuestCatalog.defaultProfile)

    let network = try XCTUnwrap((try repaired(url)["Network"] as? [[String: Any]])?.first)
    XCTAssertEqual(network["IsolateFromHost"] as? Bool, true)          // observed: false
    XCTAssertEqual((try repaired(url)["Display"] as? [Any])?.count, 1) // observed: 0
}
```

Observed output when I ran the equivalent:

```
LABEL 'Sandfort — Ubuntu 24.04 LTS — Instance 2 — Baseline Setup — A1B2C3'
    -> IsolateFromHost = Optional(0)
    Display entries: 0, Serial entries: 1
```

A control test with the label `malware triage` passes, which rules out the fixture
being wrong.

**Cost of the fix:** host-side only, no rebuild. `AGENTS.md` already states the
principle this violates — *"Pass the resolved profile explicitly to every
profile-sensitive workflow and provider operation. Never consult a process-wide
default"* — the same argument applies to a bundle's role. `repairBundle` should
take the role as a parameter from the caller, which already knows it
(`SandfortWorkflow.swift:138` is repairing `state.setupBundlePath`; line 140 is
repairing an instance). Sanitising the label is the weaker fix and would still
leave the classification depending on a string.

---

## 2. `verifyClearsignedMessage` returns text that is not the text it verified

**Severity: Low**, and it fails closed at the one call pattern that exists today.
It is filed because the function's own contract — *"Callers must read values from
the returned message"* — is not delivered, and because the verifier is the file
the brief singles out for fails-open risk.

**Location:** `sources/sandfortapp/OpenPGPSignatureVerifier.swift:245-283`, returned
at line 213.

`canonicalTextForSigning` is a many-to-one map (strips a leading `- `, strips
trailing spaces and tabs), and `splitClearsignedDocument` discards everything
between `-----BEGIN PGP SIGNED MESSAGE-----` and the first blank line without
checking that it is a well-formed armor header. The signature covers the
canonical form; `message` is the raw form. So a document can be modified, still
verify, and hand a caller different bytes than the distribution signed.

**Three transformations, all reproduced against the real Fedora 44 aarch64
`CHECKSUM` fixture and the pinned Fedora key.**

**(a) Dash-escaping a line.** Rewrite

```
SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = 55c60a3b…
```

as

```
- SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = 55c60a3b…
```

Line 277 removes the `- ` before hashing, so the signature still verifies — but
`message` keeps it. The caller pattern used in
`testFedoraSignedChecksumIsTheValuePinnedInTheCatalog`
(`.first { $0.hasPrefix("SHA256 (\(fileName)) = ") }`) then returns `nil`.

**(b) Trailing whitespace.** Append spaces and tabs to that line. Line 278 strips
them before hashing; `message` keeps them. Observed extraction:

```
P2 extracted value = >>>Optional("55c60a3b…a72fa0d5b   \t ")<<<
P2 equals pinned? false
```

**(c) Arbitrary unsigned text inside the signed-message section.** Insert a line
immediately after `Hash: SHA256`:

```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256
SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = 0000000000000000…

# Fedora-Cloud-Base-AmazonEC2-…
```

The loop at lines 258-261 skips to the first blank line regardless of content, so
the injected line is neither hashed nor returned. `verifyClearsignedMessage`
returns success. RFC 4880 §7 permits only `Hash` armor headers there, and GnuPG
rejects a malformed armor header rather than skipping it — I could not run `gpg`
in this environment to compare directly, so treat that half as an argued
divergence rather than a measured one.

**What this does not allow.** I could not construct a document that makes the
verifier hand back a *different checksum value* for a given filename. The
canonicalisation only adds or removes a `- ` prefix and trailing whitespace, and
neither can synthesise a new line or alter a hex digit. Every corruption I could
build causes the current caller to fail closed. That is why this is Low and not
higher — but it rests on a property of today's caller, not on the verifier.

**Failing test** (add to `OpenPGPSignatureVerifierTests`). Fails against current
code; the verification currently succeeds:

```swift
/// The signature covers the canonical text. Anything the verifier hands back as
/// "the verified message" must be that same text, or a caller is reading bytes
/// nobody signed.
func testClearsignedVerificationRejectsDocumentsThatAreNotTheSignedBytes() throws {
    let key = try fedoraKey()
    let target = "SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = "
        + LinuxGuestCatalog.fedora44ARM64.image.sha256

    for forged in [
        fedoraChecksumDocument.replacingOccurrences(of: target, with: "- " + target),
        fedoraChecksumDocument.replacingOccurrences(of: target, with: target + "   \t"),
        fedoraChecksumDocument.replacingOccurrences(
            of: "Hash: SHA256\n",
            with: "Hash: SHA256\n" + target.replacingOccurrences(
                of: LinuxGuestCatalog.fedora44ARM64.image.sha256,
                with: String(repeating: "0", count: 64)) + "\n")
    ] {
        XCTAssertNotEqual(forged, fedoraChecksumDocument)
        XCTAssertThrowsError(try OpenPGPSignatureVerifier.verifyClearsignedMessage(
            armored: forged, using: key
        ), "A document that is not the signed bytes must not verify")
    }
}
```

**Cost of the fix:** host-side only, no rebuild. Either return the canonical text
that was actually hashed (dash-unescaped, trailing whitespace stripped) instead of
the raw slice, or require the header region to contain only `Key: Value` lines and
reject a document whose re-serialised canonical form does not round-trip.

---

## 3. An oversized public-key packet traps the process instead of throwing

**Severity: Low.** Availability, not fail-open, and not reachable from
attacker-controlled input today. It is filed because it is precisely the class of
bug the file's own header says must not exist — *"Every read is bounds-checked and
every length is validated against the remaining buffer. Never trust a declared
length"* — and because it is uncatchable.

**Location:** `sources/sandfortapp/OpenPGPSignatureVerifier.swift:167`.

```swift
fingerprintInput.append(contentsOf: withUnsafeBytes(of: UInt16(body.count).bigEndian, Array.init))
```

`body.count` comes from the packet's declared length, honoured by `parsePackets`
up to the size of the buffer. A tag-6 or tag-14 packet whose body exceeds 65535
bytes makes `UInt16(_:)` overflow-trap. The call site at line 143 is
`try? parseKeyPacket(packet.body)` — a `try?` cannot catch a Swift runtime trap,
so the process dies rather than the candidate key being skipped.

**Reproduced.** An old-format tag-6 packet with a 4-octet declared length of 70000
and a syntactically valid v4 RSA body:

```
Swift/arm64e-apple-macos.swiftinterface:13152: Fatal error: Not enough bits to represent the passed value
... exited with unexpected signal code 5
```

The same fixture at 60000 bytes returns a fingerprint normally, which confirms the
packet shape is right and the boundary is the `UInt16` conversion.

**Reachability:** `publicKey(armored:)` and `publicKey(binaryKeyring:)` are the two
public entry points, and both are today called only with the bundled constants in
`TrustedSigningKeys.swift`. So there is no live path; the exposure is that a
maintainer intaking a new distribution's key file gets a crash with no diagnostic
instead of a thrown error, in the one file where "it threw" and "it crashed" must
be distinguishable. Note also that `parseKeyPacket` never bounds `body.count` at
all — a v4 fingerprint is defined over a two-octet length, so a body that cannot
be expressed in two octets is not a v4 key packet and should be rejected on that
basis.

**Failing test** (add to `OpenPGPSignatureVerifierTests`). Crashes the test runner
against current code, which is the failure:

```swift
/// A declared packet length must never be able to end the process. `try?` at the
/// call site cannot catch a Swift trap.
func testOversizedKeyPacketThrowsRatherThanTrapping() throws {
    let bodyCount = 70_000
    var body = Data([0x04])                                   // v4
    body.append(contentsOf: [0, 0, 0, 0])                     // creation time
    body.append(0x01)                                         // RSA
    body.append(contentsOf: [0x00, 0x08]); body.append(0xFF)  // modulus MPI
    body.append(contentsOf: [0x00, 0x02]); body.append(0x03)  // exponent MPI
    body.append(Data(repeating: 0x41, count: bodyCount - body.count))

    var blob = Data([UInt8(0x80 | (6 << 2) | 2)])             // old format, tag 6, 4-octet length
    blob.append(contentsOf: withUnsafeBytes(of: UInt32(bodyCount).bigEndian, Array.init))
    blob.append(body)

    XCTAssertThrowsError(try OpenPGPSignatureVerifier.publicKey(
        binaryKeyring: blob,
        pinnedFingerprint: String(repeating: "0", count: 40)
    ))
}
```

**Cost of the fix:** host-side, one guard, no rebuild.

---

## 4. Nothing re-verifies the image between its checksum and its use

**Severity: Informational.** Included because the brief asks the question
directly.

`verifiedImage` (`SandfortWorkflow.swift:592-616`) hashes the file in the shared
cache and returns its URL. `createSetupBundle` then copies that URL
(`UTMBundleBuilder.swift:28`) and resizes the copy. Between those two points the
file is an ordinary path under `~/Library/Application Support/…/Cache/`, and
nothing re-hashes it. Any process running as the same user can replace it after
verification and before the copy; only `resizeQCOW2`'s header checks would notice,
and only if the substitute is not a valid QCOW2.

I am not filing this as a real finding: a same-user process that can win this race
can also rewrite `config.plist`, the state file, or the app bundle, which defeats
Sandfort entirely, and `security-review.md` excludes attacks of that shape. The
cache-hit path is handled correctly — a cached file is re-hashed against the
*profile's* pinned value on every reuse (line 596), so a cross-profile filename
collision or a stale file fails closed rather than being trusted.

Worth recording that the pinned SHA-256 does its job here: the window is between
verification and use of an already-verified local file, not in the download.

---

## Scope area 2: guest provisioning quoting — no findings

This is a clean result, and I want to be explicit about what was tested rather
than leave it implied.

**The two attacker-shaped inputs and where they land.**

- The guest password reaches YAML at exactly one place per distribution:
  `CloudInit.swift:158`, `FedoraCloudInit.swift:185`, `DebianCloudInit.swift:204`,
  `OpenSUSECloudInit.swift:211`, all of the form
  `password: '\(GuestProvisioningSupport.yamlSingleQuoted(credentials.password))'`.
- The custom setup script never reaches YAML as text. It is base64-encoded
  (`GuestProvisioningSupport.swift:61`) and referenced from the finalizer only as
  a fixed path, `/var/lib/sandfort/custom-setup.sh`. The finalizer script itself is
  also base64-encoded before embedding, so the interpolated `customCommand` and
  `verificationCommands` never touch the YAML surface either.

**Why the password quoting holds.** `credentials(password:)`
(`GuestProvisioningSupport.swift:48-51`) admits only 8–128 code points in
`0x21…0x7e`. That excludes `\n`, `\r`, tab, space and every control character, so
the value cannot leave its line, cannot start a new YAML node, and cannot form a
comment (`#` needs a preceding space) or a `key: value` pair (`:` needs a
following space). Within a single-quoted YAML scalar the only metacharacter is
`'`, and `yamlSingleQuoted` doubles it — which is the correct and complete
escaping rule for that style. Backslash is literal in single-quoted YAML, so no
escape sequence exists to abuse.

**What I ran.** 994 candidate passwords — every printable ASCII character in bulk
and in leading, interior and trailing position, 600 random strings over the full
alphabet at lengths 8–128, plus a hand-built set of YAML and shell metacharacter
soup (`''''''''`, 128 consecutive apostrophes, `!!python/object/apply:os.system`,
`&anchor*x`, `*aaaaaaaa`, `----------`, `~~~~~~~~`, `0x1234567`, `12345678`,
`$(id)'''`, `` `id`''' ``, `x'||true'`). 986 passed validation. Each was pushed
through the real `seedISO` for all four distributions — 3,944 generated NoCloud
images — the `user-data` extracted from each ISO, and parsed with PyYAML
(`yaml.safe_load`, the same loader family cloud-init uses).

```
checked=3944 mismatches=0 yaml_errors=0 distinct_shapes=4
```

Zero parse errors. Zero cases where the parsed
`chpasswd.users[0].password` differed from the input, including the all-digit and
all-apostrophe cases where a missing quote or a missed escape would show up
immediately as an `int` or a parse failure. Exactly four distinct document shapes
— one per distribution, differing only in `write_files` count — meaning no
password changed the structure of the document: same 11 top-level keys, same
`ssh_pwauth: false`, same `disable_root: true`, same single `runcmd`.

Custom scripts were checked separately (empty-ish, whitespace-padded, 60 KiB) and
round-trip to the correct bytes at `permissions: '0700'` with the expected
`write_files` count, so the two-space/four-space indentation of `writeFileEntry`
composes correctly with each distribution's template.

**The one theoretical gap, and why it is not a finding.** A base64 string is a
YAML plain scalar. If a script's base64 encoding happened to consist only of
digits, PyYAML would resolve it as an integer and cloud-init's b64 decode would
fail. That requires a script of length ≡ 0 mod 3 whose entire encoding lands in
the ten digit characters — vanishingly unlikely, self-inflicted (the user writes
the script), and fails closed. Not worth a change.

---

## Other observations from the verifier, none of them findings

Recorded so the next reviewer does not re-derive them.

- **Foundation's base64 decoder is strict.** `Data(base64Encoded:)` at line 532
  returns `nil` for junk after padding, internal spaces, a trailing NUL and
  invalid characters — I tested all four. There is no armor-smuggling path through
  it.
- **CRC-24 is optional and correctly so.** Removing the `=Me1A` line verifies
  fine. RFC 9580 makes the checksum optional and it is not a security control;
  the code says as much at lines 535-536.
- **Partial and indeterminate packet lengths are refused,** as documented. A
  new-format `0xE1` length byte throws `unsupportedPacketLength`.
- **A CRLF clearsigned document is rejected** with `malformedArmor`, because
  `splitClearsignedDocument` tests `isEmpty` on a line that is `"\r"`. Fail-closed,
  but it means a manifest that passes through anything that normalises line endings
  cannot be verified at intake. Worth knowing before the next profile.
- **`packets.first(where: { $0.tag == 2 })`** (line 222) takes the first signature
  packet only. A file carrying two signatures — Ubuntu has published such files —
  fails with `issuerMismatch` if the pinned key's signature is not first. Fail-closed,
  but it would read as "the signature is invalid" when it is not.
- **A critical-flagged issuer subpacket is not recognised.** `subpackets` returns
  the raw type byte, so type `16 | 0x80` does not match the `== 16` test at line 477
  and the issuer check is skipped. Harmless — the RSA verification against the
  pinned key is what binds, as the comment at lines 352-353 says.
- **A zero-length subpacket aborts the whole subpacket scan** (`guard length >= 1`,
  line 469), which can hide the issuer and creation-time subpackets. Same
  reasoning: cosmetic, since the issuer is a hint.
- **The verifier has no runtime caller.** `grep` finds no reference to
  `OpenPGPSignatureVerifier` in `sources/` outside its own file and a comment in
  `TrustedSigningKeys.swift`; it is exercised only by
  `OpenPGPSignatureVerifierTests` during `make test`. `security-model.md` says this
  plainly — *"This runs at profile intake, not in the download path"* — and the
  documentation is honest about it. The consequence for adjudication is that every
  finding in this file is a maintainer-facing intake risk with a `make test`-shaped
  blast radius, not an end-user runtime risk, and I have graded them accordingly.

I found no input that makes the verifier accept a signature it should reject. The
packet framing, both length encodings, MPI sizing, the algorithm allowlist (RSA
1 and 3, SHA-256/384/512, no SHA-1 or MD5), the v3 five-byte hashed-material
check, the v4 hashed-area and `0x04 0xFF` trailer construction, the full-length
constant-time fingerprint comparison, the signature-MPI zero-padding to the
modulus width, and the separation of binary (`0x00`) from text (`0x01`) signature
types all check out against RFC 4880. The stored left-16 digest prefix is used
only as a pre-check and never substitutes for `SecKeyVerifySignature`. On the
brief's question — does anything fail open — the answer for this file is no.

## Documented decisions I am not disputing

None. I read `security-model.md` first and found nothing in it I would argue
against: the displayed guest password, the VM-is-not-a-boundary framing, Resume
preserving contamination, Debian staying hash-only, and VS Code's default
telemetry are all stated accurately and for reasons I agree with. Finding 1 is not
a disagreement with the model — it is the model's own guarantee not holding in
code.

## What I did not examine closely

- **The SwiftUI view layer** — `ContentView`, `EnvironmentSidebar`,
  `EnvironmentDetailView`, `ActivityLogView`, `BaselineToolsSheet`,
  `SandfortSettingsView`, `SafetyAcknowledgementView`. Out of scope per the brief.
  I read only the two rename/create call sites needed to establish reachability for
  finding 1.
- **`SandfortViewModel.swift`** (828 lines) — read by grep for the label and
  password paths only. Its concurrency and state-refresh behaviour is unreviewed.
- **`UTMRegistryController.swift`** and `UTMLauncher` — I checked only that VM
  targeting is by exact saved name and that no user label can make two instance
  names collide (it cannot: the number and the tag both remain in the name). The
  Apple Event construction, the registration polling loop and the stop/wait logic
  are unreviewed.
- **`ISO9660Writer.swift`** — read once for injection potential in the cidata
  image, which is nil (fixed volume name, fixed identifiers, content is opaque
  bytes). Its descriptor and directory-record arithmetic is otherwise unverified;
  I did not check the `UInt8(length)` and single-block directory assumptions
  against anything but the two fixed filenames it is called with.
- **`DiskUtilities.resizeQCOW2`** — read, and its bounds look sound (magic,
  version, cluster-bits range, refusal to shrink, L1 allocation check, geometry
  re-validation after the write). I did not fuzz it against malformed QCOW2
  headers, which is the obvious next test since the header comes from a downloaded
  image. Priority 4 in the brief; another reviewer's area.
- **`SandfortWorkflow.swift`** — read the create, rebuild, delete, reset, resume
  and profile-resolution paths. I did not review `deleteEnvironment`, the
  legacy-directory migration in depth, or the running-VM scoping logic.
- **`TrustedSigningKeys.swift`** — I confirmed the fingerprints the tests assert
  and that selection is by full fingerprint rather than position, but I did not
  independently verify the bundled key bytes against the vendors' published files.
  That check needs network access to the distributions and is the kind of thing
  that should be done once, by hand, and recorded in
  `linux-profile-provenance.md`.
- **No live UTM boot was performed.** Every claim above is from source reading and
  from tests run against a copy of the repository.
