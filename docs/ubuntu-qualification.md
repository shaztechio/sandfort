# Ubuntu 24.04 LTS UTM qualification

Ubuntu is the default profile in production Sandfort. It is also the profile
that went longest without a written matrix: the other three each got one when
they were promoted, and Ubuntu predates that process. Build the isolated
verification app when repeating its release matrix without changing a
production baseline:

```sh
make ubuntu-qualification-app
codesign --verify --strict "dist/Sandfort Ubuntu Qualification.app"
```

The qualification app has bundle identifier
`app.sandfort.Sandfort.UbuntuQualification`, stores state under
`~/Library/Application Support/Sandfort Ubuntu Qualification`, and prefixes all
UTM names with `Sandfort Ubuntu Qualification`. It must never read, repair,
reset, rebuild, or delete production Sandfort state or VMs.

## What is most likely to fail here

Two Ubuntu-specific things deserve attention before the routine checks:

- **The browser check races snap seeding.** Ubuntu's Firefox is a snap, and
  `firefox` and `chromium-browser` are only transitional packages that pull it
  in. The browser verification runs during cloud-init, so if snap seeding has
  not finished, setup fails and **no baseline is produced at all**. This is the
  highest-risk item in the current revision. If it fails, capture
  `snap list`, `systemctl status snapd.seeded.service`, and the tail of
  `/var/log/sandfort-setup.log` before doing anything else.
- **VS Code's sandbox helper.** Electron refuses to start unless
  `chrome-sandbox` is owned by root and setuid, and Ubuntu 24.04 blocks the
  fallback path by restricting unprivileged user namespaces through AppArmor.

## Setup and baseline

1. Open **Sandfort Ubuntu Qualification**, confirm the orange Ubuntu
   qualification notice, and use **Check My Mac** (the stethoscope button in the
   toolbar).
2. Choose **Create Ubuntu Qualification VM**. Confirm the exact noble
   `release-20260725` AArch64 cloud image downloads with percentage progress and
   passes SHA-256 verification.
3. In UTM, confirm the clearly labeled Baseline Setup VM boots through AArch64
   UEFI, discovers CIDATA, suppresses the serial login prompt, and shows useful
   `[Sandfort]` status messages.
4. Leave setup running through all APT transactions. Confirm it either powers
   off automatically after verification or leaves a diagnostic login prompt with
   a clear failure message. Never click **Finish Setup** after a failure.
5. After automatic poweroff, click **Finish Setup**, then confirm Instance 1
   reaches graphical GDM and accepts the displayed credentials. Confirm no text
   `sandfort login:` prompt appears at any point during the boot; the profile
   masks `getty@tty1.service` so the greeter is the only login shown. Then press
   Ctrl+Alt+F2 and confirm a text console is still reachable for diagnostics, and
   Ctrl+Alt+F1 returns to the desktop.

Inside Ubuntu, verify:

```sh
cat /etc/os-release
cloud-init status --wait
sudo ufw status
sudo aa-status --enabled && echo apparmor-enabled
systemctl is-enabled gdm3.service
systemctl is-enabled unattended-upgrades.service
systemctl is-enabled ssh.service
systemctl is-active ssh.service
systemctl is-enabled getty@tty1.service
command -v firefox || snap list firefox
command -v gnome-terminal
ls -l /usr/local/lib/vscode/*/chrome-sandbox
code --version
git --version
curl --version
jq --version
python3 --version
node --version
npm --version
```

Expected results are UFW active, AppArmor enabled, GDM and unattended-upgrades
enabled, and a browser and terminal present. SSH must be masked and inactive and
`getty@tty1.service` must report `masked`; those three checks are expected to
return nonzero.

`chrome-sandbox` must be owned by **root** and show mode `-rwsr-xr-x`. Owned by
`sandfort` means the setuid bit is worthless and VS Code will not launch; that
was the failure in revision 3.

Also run `systemctl --failed` and inspect
`systemctl status systemd-networkd-wait-online.service`. Record which service
owns the active interface and whether wait-online delays a clean graphical boot.

## Clean-session matrix

1. Instance 1 initially starts offline. Confirm DNS, HTTPS, and a browser cannot
   reach the Internet.
2. Create a harmless marker file. Use **Reset & Run Clean** without Internet and
   confirm the marker is gone and the guest remains offline.
3. Use **Reset & Run Clean** with Internet and confirm outbound DNS and HTTPS
   work, and that Firefox loads a page. Confirm UTM still has no shared
   directory, clipboard sharing, automatic USB sharing, bridged network, or port
   forward.
4. Create Instance 2, boot both instances independently, and confirm their files
   do not cross between guests.
5. Use **Resume** and confirm it preserves the selected instance's files and last
   network choice. Then reset it and confirm its disk state is discarded.
6. Delete an instance and confirm the app and UTM library agree. Exercise
   qualification **Rebuild** once with UTM open and once with UTM closed.
7. Keep a Fedora, Debian, or openSUSE production instance running while using the
   Ubuntu qualification instance. Confirm actions and credentials remain isolated
   between the two apps and UTM environments.

Record the macOS version, Mac model, UTM version, Sandfort version, setup
duration, network ownership, and result of every item. A regression failure
blocks release of Ubuntu revision 4. Revisions 1 to 3 are intentionally
incompatible: revision 1 predates the console-login fix, revision 2 shipped no
terminal or browser verification and no editor, and revision 3 installed a VS
Code that could not launch.
