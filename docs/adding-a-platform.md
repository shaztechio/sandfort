# Adding a platform

1. Add a new app/package target for the host OS and CPU architecture.
2. Implement `VirtualMachineProvider` for that hypervisor's native bundle format.
   All nine methods, `attachMaterials` and `detachMaterials` among them. Neither
   of those has a default implementation, deliberately: a provider that quietly
   ignored materials would compile, pass its bundle tests, and tell a user their
   files are in a sandbox that does not have them.
3. Add an immutable official image URL and SHA-256 for the guest architecture.
   Re-verify that SHA-256 against the disk **inside the bundle you just built**,
   before anything modifies it, and delete what you created if it fails. The
   download check alone verifies a cache entry, not the bytes your hypervisor
   boots.
4. Reuse the cloud-init policy and ISO fixtures where the guest supports NoCloud.
5. Prove in tests that sharing, clipboard, USB auto-capture, bridging, inbound port
   forwards, and persistent untrusted writes are disabled, and that materials are
   read-only, reach clean instances only, and are built from a copy rather than
   the user's own file. Assert attach and repair write the same drive shape;
   repair silently undoing an attach is a bug that has already happened once.
6. Add a native launcher for the host. Runtime shell or UI scripting is not part of
   the provider contract.
7. Add a host-specific CI job and a real hypervisor smoke-test matrix.

Likely next targets are Intel macOS with UTM, Windows, and Linux with QEMU/KVM.
Do not reuse ARM64 disk images or checksums on x86_64. A profile's
`materialsInterface` is the same kind of per-architecture fact: Fedora's `USB` is
a property of the ARM64 Cloud Base kernel's module set — it ships no
`sym53c8xx` — not of Fedora, and it fails silently when wrong, because the
desktop simply never offers the drive.

`WINDOWS.md`, `LINUX.md`, and `INTEL.md` each work this checklist through for one
host in detail:

- Read `LINUX.md` first whichever host you are adding. It records that starting,
  stopping, and unregistering a VM are not part of `VirtualMachineProvider` at
  all, so the contract has to grow before a second host can exist.
- `WINDOWS.md` recommends QEMU rather than Hyper-V, because Hyper-V cannot
  express "Internet but no host access" without host firewall rules the user
  could undo.
- `INTEL.md` is the one plan that argues against itself, on hardware arithmetic
  rather than engineering. Its Phase 0 is already done, so the architecture axis
  the other two plans both need is in the code today.
