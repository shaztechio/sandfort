# Materials: getting a file into an offline sandbox

A sandbox has no shared folders, no clipboard, no USB, and no SSH. That is the
point, and it leaves a real gap: someone doing a coding challenge whose files are
already on their Mac has no way to hand them over. Before this existed the only
route was pasting text into the 64 KiB custom setup script and rebuilding the
baseline — twenty to forty-five minutes, at entirely the wrong granularity.

Materials close that gap in one direction only.

## What happens

The user picks a file or a folder. Sandfort packs it into an ISO 9660 image and
attaches it to **one clean instance** as read-only optical media. A folder is
archived first, by `NSFileCoordinator`'s `.forUploading` option — a system API,
so no archive format is implemented here.

The guest is handed **an image Sandfort built from a copy**, never the user's
file. That is the whole security argument, and it is worth being precise about
why: guest-to-host is impossible *by construction*. It does not depend on
`ReadOnly` reaching QEMU, on a plist key surviving a UTM upgrade, or on any
promise UTM makes. `ReadOnly: true`, reasserted on every state read, adds that
the guest cannot write to the copy either.

## Why optical media on SCSI

The obvious implementation — another VirtIO disk, like the NoCloud seed — makes
the volume nearly unreachable. `udisks2` decides whether something is removable
from its bus, and a virtio-blk device has no hotpluggable one, so GNOME classes
it as an internal system drive: buried under "Other Locations", never
auto-mounted, and not what anyone would call clicking a file.

`ImageType: "CD"` is unambiguously removable media, and the desktop offers it in
the sidebar.

**The interface was measured, not chosen.** USB was tried first and worked on
Ubuntu — but on Debian the device was never enumerated at all: `lsblk -f` showed
the VirtIO seed as `vdb iso9660 CIDATA` and no optical device whatsoever. Two of
the four guests could not have seen materials however their desktop was
configured. A virtio-scsi CD-ROM is still genuine removable optical media, and it
rides the transport every one of these cloud kernels already uses for its root
disk.

That failure was nearly misdiagnosed. openSUSE failed first, and its package list
lacks `gvfs` — exactly the shape of the two defects that profile has already
shipped, where `patterns-gnome-gnome` omitted a browser and then a terminal. The
fix would have been a guest-side package addition costing every openSUSE user a
rebuild. Debian failing too is what ruled it out, since `task-gnome-desktop`
brings complete desktop plumbing: two profiles failing where one has `gvfs`
cannot be about `gvfs`.

## Limits, and why they are what they are

**512 MB.** The binding constraint is memory, not disk: `ISO9660Writer.make`
builds the whole image at once while the caller still holds the payload, so peak
use is roughly twice the limit — on a Mac that is simultaneously running a 4 GiB
guest. Raising it means streaming the writer to a `FileHandle` first, with its
own test. Anything much larger is also a sign the user wants an Internet-enabled
launch and a `git clone`, which this feature does not replace.

**One file on the image.** `ISO9660Writer` writes a flat directory that must fit
one 2048-byte sector, and its bounds are interdependent — see the note on it in
`AGENTS.md` before changing any of them.

**Names are bounded at 64 bytes** and reduced to `[A-Za-z0-9._-]`. The Rock Ridge
name is parsed by the guest kernel and becomes a filename; overlong names are
truncated rather than refused, because the user picked a legitimate file and its
name is not a problem they should have to solve.

## The store, and why Reset does not re-read the source

Packed images live at `Materials/instance-<n>.iso`, beside the VMs rather than
inside them, because **Reset & Run Clean deletes and recreates the whole bundle**.
Reset re-attaches from that store.

It never re-reads the source path, and that is deliberate. Pick `~/Downloads` in
March, reset in June, and re-reading would send whatever is there now — a bank
statement, say — into a sandbox about to run hostile code. Re-packing is
something the user asks for, through **Replace…**.

A missing stored image is reported and the record cleared rather than failing the
launch: materials are a convenience, and a convenience that has gone missing must
not strand an instance someone is trying to run.

Instance numbers are never reused, so a stored image cannot be inherited by a
later instance.

## Where materials may not go

Clean instances only. Four independent gates:

1. `createSetupBundle` has no materials parameter — the call is inexpressible.
2. `attachMaterials` is called only for clean instances.
3. `repairBundle` removes the drive **and the file** for `.setup` and
   `.protectedBaseline`. This is the enforcement point that matters, because
   `currentState()` runs it on every state read.
4. `createCleanBundle` drops an image inherited from the baseline clone, which
   would otherwise reach every future instance as an orphaned payload.

Removing the file matters as much as removing the entry: an orphaned image with
nothing pointing at it is still the user's file inside a bundle.

## Using it

The instance must be **fully powered off**, not suspended — attaching rewrites
its configuration, and a suspended VM still holds its disk lock. Afterwards
**Resume** is enough; resetting would discard everything else in that instance to
deliver a file that is already attached.

In the guest, open Files and look for `SANDFORT_MATERIALS`. Ubuntu lists it as a
CD in the sidebar; Debian shows it in Files but not as a sidebar CD, which is a
difference between Ubuntu's patched GNOME and stock upstream rather than anything
about the drive — both guests enumerate the same device from the same
configuration. From a terminal:

```sh
lsblk -f
ls /run/media/$USER/SANDFORT_MATERIALS
```

and if it is not mounted:

```sh
sudo mount -o ro /dev/disk/by-label/SANDFORT_MATERIALS /mnt
```

## What is verified, and what is not

Verified on a live run against **UTM 5.0.4** with **Ubuntu 24.04**: the drive is
accepted as a SCSI CD, the guest exposes an ISO 9660 volume labelled
`SANDFORT_MATERIALS`, and it appears as a CD in the GNOME Files sidebar with the
expected contents.

**Attaching** materials to a stopped instance needs only a Resume — UTM picks up
a newly added drive. **Changing how an existing drive is attached** does not:
UTM caches a VM's configuration, and an interface change is invisible to it until
the app is quit and relaunched. That distinction cost an afternoon of measuring
against stale state.

Not yet verified, and recorded as such in `utm-version-audit.md` rather than
assumed:

- Fedora and openSUSE. Debian is confirmed: UTM lists the SCSI CD, the guest
  enumerates `sr0`, the volume appears in Files, and its contents are correct —
  but it gets no sidebar icon, so the wording above avoids promising one.
- openSUSE's GNOME pattern has already surprised this project twice, so it is
  worth checking rather than assuming it follows Debian.
- Whether the volume auto-mounts or needs the click.
- That `ReadOnly: true` genuinely reaches QEMU — i.e. that writing to the mounted
  volume fails. The stronger guarantee, that the user's original is untouchable,
  does not depend on this.

## Automount is deliberately not implemented

Mounting at a fixed path with no user action would need a guest-side systemd
mount unit keyed on the volume label. That is a guest change: a profile revision
bump, a `BREAKING CHANGE:` footer, and every existing user rebuilding a baseline
— twenty to forty-five minutes each — for convenience. If it is ever done, fold
it into a revision that is already forcing a rebuild for another reason.
