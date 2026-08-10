# Deferred: per-environment RAM and disk sizing


Every profile is fixed at 4 GiB RAM, 4 CPUs, and a 64 GiB disk in
`LinuxGuestProfile.Hardware`. With VS Code installed beside GNOME and a browser
that is tight. The agreed direction is to make RAM and disk configurable **per
environment**, with defaults of **6 GiB and 96 GiB**. CPU count stays at 4.

**There is no per-distribution work.** `Hardware` is uniform across the four
profiles, and guest-side growth already works everywhere: baselines start from a
2–4 GiB cloud image and end up with usable 64 GiB filesystems, which only
happens because cloud-init's `growpart` and `resizefs` run. Filesystems differ
(ext4 on Ubuntu and Debian, btrfs on Fedora and openSUSE) and cloud-init handles
both; openSUSE's SBOM ships `growpart` plus `btrfsprogs`, `e2fsprogs`, and
`xfsprogs`.

Most of the plumbing exists:

- `DiskUtilities.resizeQCOW2` grows and refuses to shrink, which is correct;
  shrinking a qcow2 under a live filesystem is not safe.
- `UTMBundleBuilder.repairBundle` already resizes the disk and runs on every
  **Reset & Run Clean**, so a larger disk reaches existing instances already.
- `growpart` and `resizefs` are `PER_ALWAYS`, so a guest picks up a larger disk
  on its next boot rather than only at first boot.
- **The gap:** `repairBundle` never writes `MemorySize` or `CPUCount`. Those are
  set only by `writeConfiguration` at bundle creation, so an existing instance
  would keep its old RAM forever. Reset must update them, and that deserves its
  own regression test because it is invisible in the UI.

Design notes for whoever picks this up:

- Store optional `memoryMiB` and `diskSizeGiB` beside `SandboxToolSelection`,
  falling back to the profile's values, so older state still decodes. Same
  pattern as the VS Code toggle.
- Pass the resolved hardware into `UTMBundleBuilder` instead of letting it read
  `profile.hardware`, matching the rule that a resolved profile is passed
  explicitly rather than looked up.
- Validate before anything destructive: disk may only grow, so reject a value
  below the environment's current size with a clear message instead of failing
  inside `resizeQCOW2`. RAM needs a floor near 2 GiB, below which the GNOME
  desktop is unusable, and a ceiling well under
  `ProcessInfo.processInfo.physicalMemory` because instances run concurrently.
- Put it in its own sheet, not the development-tools sheet. Tool selections apply
  only to the next baseline; these apply to instances on reset, and mixing them
  misrepresents when each takes effect.
- `doctor()` now reports host RAM and free space alongside UTM, architecture,
  and sandbox state, and states what one baseline costs. It still does not flag
  a *configured* size the Mac cannot afford, because nothing is configurable
  yet; that check belongs with this work.
- No profile revision bump and no rebuild: nothing inside the guest changes and
  the disk format is untouched, only its virtual size, through a path that
  already runs. That is the judgment call in this plan most worth challenging
  before implementing.

Verify with a real UTM boot on at least one ext4 and one btrfs profile: after a
reset, `free -h` should show the new RAM and `df -h /` the larger root.

