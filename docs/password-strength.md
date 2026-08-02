# Sandbox login password strength

## Summary

Sandfort's generated sandbox password is designed for memorable local guest
login, not as a high-entropy secret protecting valuable data. It is adequate
against casual guessing at the VM's graphical or serial login prompt, especially
because Sandfort disables SSH and unsolicited inbound connections. It is weak
against a determined attacker who can copy the VM disk or otherwise obtain the
guest's password hash and perform offline guesses.

The password must not be treated as a security boundary between hostile guest
code and the macOS host. VM isolation, UTM configuration, host-sharing controls,
and clean baseline restoration provide that boundary. Nor should the password
be reused for any personal account or contain a personal secret.

## Current generated format

`GuestProvisioningSupport.credentials()` constructs the default password by:

1. Shuffling the reviewed 2,048-word list in `MemorablePasswordWords.swift`
   using Swift's `SystemRandomNumberGenerator`, which is cryptographically
   secure on Apple platforms.
2. Taking the first four distinct words.
3. Joining them with hyphens.

An example format is `mica-capsule-plough-forelock`. Examples in documentation
and screenshots are not fixed passwords; each new generation chooses another
phrase. Phrases average about 27 characters.

Because words are selected without replacement and order matters, the number of
possible generated phrases is:

```text
2048 × 2047 × 2046 × 2045 = 17,540,692,561,920
log2(17,540,692,561,920) = 44.00 bits
```

This estimate assumes the operating system random source and Swift's shuffle are
working correctly and each ordered selection is effectively equally likely. The
hyphens, known four-word structure, and word lengths improve usability but add no
meaningful entropy once an attacker knows Sandfort's generation algorithm.

## The algorithm and word list are public

Sandfort is open source, so an attacker is assumed to know the generation
algorithm and to have the complete word list. That assumption is deliberate and
costs nothing: the list was always recoverable from any distributed copy of the
app with `strings`, so its secrecy was never a control. Strength comes from the
size of the search space, and the figures here already assume full knowledge of
how phrases are built.

The list is fixed, reviewed, and version-controlled for the same reason the
image catalog is. `MemorablePasswordWordsTests` enforces its properties, so the
entropy claim above cannot regress unnoticed through an edit.

## Practical assessment

### Interactive login guessing

The generated phrase is reasonable for its present convenience role. The guest
normally exposes only its graphical and serial login prompts. SSH is disabled
and masked, the guest firewall denies unsolicited inbound traffic, UTM has no
incoming port forwards, and clean runs default to offline. Those controls make
large-scale remote password guessing substantially less practical.

The password still should not be considered strong authentication. Someone with
interactive access to the VM can try guesses, and rate limiting is provided by
the selected Linux distribution rather than by Sandfort itself.

### Offline password guessing

Forty-four bits puts exhaustive offline search out of reach for the attackers
this tool plausibly faces. All four supported distributions hash the guest
password with yescrypt, which is memory-hard and therefore slow to attack in
bulk. Exhausting 17.5 trillion candidates takes roughly:

| attacker | time to exhaust |
| --- | --- |
| yescrypt, single GPU | decades |
| yescrypt, large GPU cluster | months |
| a fast hash such as sha512crypt, single GPU | months |
| a fast hash, large GPU cluster | days |

The earlier 64-word format gave 23.86 bits, about 15.2 million candidates, which
fell in minutes. Four words from 2,048 is roughly 1.15 million times larger.

Offline strength is worth keeping in perspective. Anyone able to attack the hash
already has the virtual disk, and the disk is not encrypted: they can read and
modify every file in the guest without recovering the password at all. A stronger
password does not change that, and it is not intended to. What it does is remove
password recovery as a cheap side effect of obtaining a disk, which matters most
when a user has reused the phrase somewhere it should not have been.

## Storage and lifetime

- A password is created when an environment's baseline is first created.
- Rebuild prefills the existing password and lets the user keep it, replace it,
  or generate a new four-word phrase with the recycle button.
- Every numbered instance created from one protected baseline inherits the same
  username and password.
- Different Linux environments have independent credentials.
- Sandfort stores the credentials in its app-owned environment state so it can
  display them later. The cloud-init seed used to create the baseline also
  necessarily contains the initial credential material. The password is not a
  macOS Keychain secret and should not be treated like one.
- Sandfort does not intentionally transmit the password or include it in the
  activity log. Copying or sharing app state, VM bundles, diagnostic material,
  or screenshots can nevertheless disclose it.
- Resetting an instance from its baseline does not rotate the password. Rebuild
  the environment and choose a new password to rotate credentials.

## User-selected rebuild passwords

During Rebuild, Sandfort accepts 8 to 128 visible ASCII characters with no spaces
or line breaks. This validation prevents malformed cloud-init input; it is not a
strength meter. An eight-character dictionary word can satisfy the syntax rule
while remaining weaker than the generated phrase.

For a stronger guest login password:

- Use a password generated by a password manager.
- Prefer at least 16 random characters, or a passphrase generated from a much
  larger word list.
- Use a new value that is unique to this Sandfort environment.
- Do not reuse a macOS, email, source-control, cloud, or work-account password.
- Do not enter a valuable password into an instance that has run untrusted code;
  set it only through Sandfort's trusted baseline rebuild flow.

## Security conclusion

The four-word generator provides good memorability and 44.00 bits of
theoretical entropy. That is sufficient for convenient local access to a
disposable guest under Sandfort's network and sharing restrictions, and it makes
exhaustive offline recovery impractical rather than trivial.

It is still not a disk-protection mechanism, and it should never be reused for a
personal account or a remote service. If a future change exposes an
authenticated network service from the guest, revisit this document rather than
assuming the current figure remains adequate.

Four words rather than five or six is a deliberate trade. Sandfort disables
clipboard sharing, so this password is typed by hand at the VM console on every
login. Five words from the same list would give 55 bits, which defends against
no attacker that 44 bits does not already stop in this threat model, at a real
cost in typing.

Changing the generator affects only newly created baselines. Existing baselines
keep their stored password, and the guest profile contract is unchanged, so no
profile revision bump or rebuild is required to adopt a new format.
