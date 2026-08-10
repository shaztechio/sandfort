# Deferred: remaining clean-instance boot time


Masking `systemd-networkd-wait-online` removed two minutes from a Debian clean
boot. `systemd-analyze blame` on the resulting instance still shows two costs
worth roughly 13 seconds together, both deliberately left alone:

- `plymouth-quit-wait.service`, 11.5s, and on the critical chain. This waits for
  the boot splash to hand off to the display manager. Disabling it is the obvious
  win and the obvious risk: the complaint that started this was a black screen,
  and interfering with the splash handoff is a good way to produce another one.
- `fwupd.service`, 1.9s. A firmware updater with no firmware to update in a VM.
  Safe to mask, but not worth a rebuild-forcing revision on its own.

Fold these into a revision that is already forcing a rebuild for another reason,
rather than spending one on 13 seconds. Measure with `systemd-analyze blame` and
`systemd-analyze critical-chain graphical.target` inside an offline clean
instance before and after, and check the other three profiles rather than
assuming Debian's numbers transfer: the wait-online problem turned out to be
Debian-only because systemd-networkd is a separate package on Fedora and
openSUSE.

