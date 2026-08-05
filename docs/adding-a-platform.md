# Adding a platform

1. Add a new app/package target for the host OS and CPU architecture.
2. Implement `VirtualMachineProvider` for that hypervisor's native bundle format.
3. Add an immutable official image URL and SHA-256 for the guest architecture.
4. Reuse the cloud-init policy and ISO fixtures where the guest supports NoCloud.
5. Prove in tests that sharing, clipboard, USB auto-capture, bridging, inbound port
   forwards, and persistent untrusted writes are disabled.
6. Add a native launcher for the host. Runtime shell or UI scripting is not part of
   the provider contract.
7. Add a host-specific CI job and a real hypervisor smoke-test matrix.

Likely next targets are Intel macOS with UTM, Windows, and Linux with QEMU/KVM.
Do not reuse ARM64 disk images or checksums on x86_64.

`WINDOWS.md` and `LINUX.md` work this checklist through in detail. Read
`LINUX.md` first whichever host you are adding: it records that starting,
stopping, and unregistering a VM are not part of `VirtualMachineProvider` at all,
so the contract has to grow before a second host can exist.

`WINDOWS.md` works this checklist through for Windows in detail. It recommends
QEMU rather than Hyper-V, because Hyper-V cannot express "Internet but no host
access" without host firewall rules the user could undo.
