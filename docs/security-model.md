# Security model

## Enforced boundaries

- Official immutable cloud images with profile-specific pinned SHA-256 values.
  Ubuntu 24.04, Fedora 44, and Debian 13 are currently supported.
- UTM QEMU backend with Apple Hypervisor acceleration.
- An independent protected setup baseline per Linux environment, used to restore
  that environment's selected instance disk and UEFI state before every clean run.
- Trusted setup uses temporary NAT internet access to download signed
  distribution packages. Clean instances default to isolation from both host and Internet.
  Explicit Internet-enabled launches relax UTM's guest-to-host isolation for
  that instance; no bridged networking is used.
- No port forwards, host directory sharing, synchronized clipboard, or automatic
  USB sharing.
- Distribution-specific cloud-init disables SSH, denies unsolicited inbound
  traffic, applies upgrades, and enables unattended security updates. Ubuntu
  uses UFW and unattended-upgrades; Fedora uses firewalld and
  security-only DNF5 automatic updates while requiring SELinux enforcing mode.
- A unique initial guest password is generated locally and shown in the app.
  Rebuild allows an explicit replacement after local validation; cloud-init
  safely quotes it before embedding it in the NoCloud seed. Its authentication
  quality and limitations are documented in `password-strength.md`.
- Distribution qualification uses a separately signed app identity, Application
  Support root, allowed-profile set, and UTM name prefix. Fedora and Debian
  verification builds cannot resolve production state. Production baselines
  persist their exact Ubuntu, Fedora, or Debian profile identity and checksum.

The initial provisioning VM becomes the persistent, clearly labeled Protected
Baseline. The user must wait for cloud-init to finish and shut it down before
**Finish Setup** creates Instance 1. Additional numbered instances are full,
independent copies with unique VM identifiers, MAC addresses, disks, and UEFI
state, so they can run concurrently. Changes remain only in that instance until
**Reset & Run Clean** unregisters the stopped VM and recreates its bundle from
the baseline so an open UTM library cannot reuse a cached network setting. The
permanent app-level number and optional label remain, while the disposable VM
UUID, MAC address, disk, and UEFI state are replaced. **Resume Instance** deliberately preserves
the instance's files, processes, suspended state, and last explicit network mode;
it must be treated as contaminated. Users must never run the Protected Baseline
or relaunch an instance directly from UTM.

Multiple Linux environments share only verified source-image downloads. Their
mutable state, baselines, instances, credentials, VM identifiers, MAC addresses,
disks, and UEFI state are separate. Rebuild and Delete Environment resolve the
selected environment before unregistering any exact UTM names; they never infer
another environment from a global default.

Instance deletion is app-owned and allowed only when the instance disk is not
locked by a running VM. Sandfort asks UTM to unregister the exact saved VM name,
waits for UTM to confirm its removal, moves the bundle to macOS Trash, and only
then updates app state. **Rebuild** is the only app action that deletes the Protected Baseline.
After its destructive confirmation, rebuild uses a native Apple Event addressed
to UTM to remove only the exact baseline and instance names held in app state;
it does not invoke AppleScript, a shell command, or UI automation. A denied
macOS Automation permission aborts before local VM data is deleted. If UTM is not
running, Sandfort launches it with `NSWorkspace` and waits for its Apple Event
interface to become ready. The workflow also waits until UTM can no longer resolve
each exact VM name before removing the parent directory, so UTM cannot race the
filesystem cleanup or retain a stale registration.

## Residual risk

A VM reduces risk; it is not a perfect malware boundary. Connected malware can
still contact Internet services, steal anything entered into the guest, attack
other systems, or exploit a vulnerability in the guest OS, QEMU, UTM, or macOS. Never
put personal accounts, SSH keys, cloud credentials, password managers, wallets,
work files, or secrets in this VM. Keep UTM and macOS updated.
