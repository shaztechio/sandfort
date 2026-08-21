# A QEMU spike, before anything is built

The Windows plan rests on two claims that no Sandfort code is needed to test.
This page tests them on real hardware, in an afternoon, before
[phase 0](WINDOWS.md#phases) and before the core-language decision.

If either claim fails, that is worth knowing while the plan is still a document.

## What this is not

**Not a qualification run.** Nothing here produces a shippable profile. No
checksum enters `LinuxGuestCatalog.swift`, no provenance record is written, and
the bar in [AGENTS.md](../AGENTS.md) — automated contract tests plus a real boot
smoke test through setup, poweroff, graphical login, and both resets — is
untouched by anything below. Delete the working directory afterwards.

It is a hypervisor experiment that happens to use a Linux image.

## What it answers

1. **Does WHPX actually accelerate on this host?** The whole plan chose QEMU on
   WHPX. Guessing is how you find out in phase 3 instead of now.
2. **Is `-netdev user,restrict=on` really the offline guarantee?** It is the
   single most load-bearing row in the plan's invariants table. Everything else
   in the security model degrades gracefully; this one does not.
3. **Partially: what a materials CD looks like on x86-64.** See the caveat in
   step 5.

## Before you start

QEMU, per [windows-dev-setup.md](windows-dev-setup.md). The seed image in step 2
is easiest to build in WSL, which is likely already installed; any Linux shell
will do.

## 1. Get an image, and verify it

```powershell
curl.exe -O https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
curl.exe -O https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS
```

Check it before booting it. This is a throwaway spike and the habit is still
worth keeping — an image that fails here is a corrupted download, and you would
rather learn that than debug a hypervisor against bad bytes:

```powershell
(Get-FileHash ubuntu-24.04-server-cloudimg-amd64.img -Algorithm SHA256).Hash.ToLower()
Select-String -Path SHA256SUMS -Pattern 'cloudimg-amd64.img'
```

Cloud images are sparse-ish and grow. Give the overlay room:

```powershell
qemu-img resize ubuntu-24.04-server-cloudimg-amd64.img +16G
```

## 2. Build a NoCloud seed

The image has no password by design. In WSL or any Linux shell:

```sh
sudo apt install -y cloud-image-utils
cat > user-data <<'EOF'
#cloud-config
password: spike
chpasswd: { expire: false }
ssh_pwauth: false
EOF
echo 'instance-id: spike' > meta-data
cloud-localds seed.iso user-data meta-data
```

Copy `seed.iso` next to the image on the Windows side.

## 3. Does WHPX accelerate?

Ubuntu's cloud images enable a serial console, so `-nographic` gives a login
prompt without any display plumbing:

```powershell
qemu-system-x86_64.exe `
  -accel whpx `
  -M q35 -smp cores=4 -m 4G `
  -drive file=ubuntu-24.04-server-cloudimg-amd64.img,if=virtio `
  -drive file=seed.iso,media=cdrom `
  -nic none `
  -nographic
```

Log in as `ubuntu` / `spike`, then get a real number rather than an impression:

```sh
systemd-analyze
```

Now run the identical command with `-accel tcg` and compare. **The comparison is
the measurement** — an absolute figure tells you little, and the gap between
accelerated and emulated is unmistakable.

| Result | What it means |
| --- | --- |
| WHPX boots in seconds; TCG takes minutes | The plan's bet is sound. Proceed. |
| WHPX fails to initialise | Check the `HypervisorPlatform` feature and firmware virtualization first. If it is genuinely unavailable, the hypervisor decision reopens. |
| WHPX works but is close to TCG | The worst outcome, and the reason to measure. Record it and reopen the decision before phase 0. |

Exit `-nographic` with `Ctrl-a x`.

## 4. Is `restrict=on` the offline guarantee?

Boot again, with a network device this time:

```powershell
qemu-system-x86_64.exe `
  -accel whpx `
  -M q35 -smp cores=4 -m 4G `
  -drive file=ubuntu-24.04-server-cloudimg-amd64.img,if=virtio `
  -drive file=seed.iso,media=cdrom `
  -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0 `
  -nographic
```

Inside the guest:

```sh
ip addr
ip route
curl -sS --max-time 5 https://example.com ; echo "exit=$?"
ping -c2 -W2 10.0.2.2
```

**Expect the guest to hold an IP address, and do not read that as a failure.**
QEMU's user-mode DHCP server is internal to the network stack, so a lease and a
default route can both exist while every packet beyond them is dropped. What
matters is that nothing is reachable — not that nothing was configured.

Exactly how the built-in DHCP and DNS behave under `restrict=on` is part of what
this spike establishes. Record what answers and what does not, rather than
assuming it matches the macOS behaviour.

Then drop `restrict=on` and confirm the same commands succeed. A test that only
ever shows failure has not distinguished "isolated" from "broken", and that
distinction is the entire point.

## 5. What a materials CD looks like here

Partial, and worth being clear about why. Attach any ISO as a read-only SCSI
CD-ROM:

```powershell
  -device virtio-scsi-pci,id=scsi0 `
  -drive file=materials.iso,if=none,id=mat,media=cdrom,readonly=on `
  -device scsi-cd,drive=mat,bus=scsi0.0
```

`lsblk` and `dmesg | grep -i cdrom` tell you whether the kernel sees it, which
answers the half of the `materialsInterface` question that is about drivers.

**It cannot answer the other half.** The reason the catalog avoids VirtIO block
devices is that the *desktop* classes them as internal system drives and never
offers them. A server cloud image has no desktop, so whether GNOME presents this
drive to a user is untestable here and belongs in phase 3 with a real profile.
Do not record a conclusion this spike cannot support.

## Afterwards

Whatever you find belongs in `WINDOWS.md`, not in a commit message. The open
questions it answers are named there, and results 3 and 4 in particular decide
whether the hypervisor recommendation survives contact with hardware.

If the results are good, nothing changes and the plan proceeds. If they are not,
this cost an afternoon instead of a phase.
