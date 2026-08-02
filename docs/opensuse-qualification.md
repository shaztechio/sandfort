# openSUSE Leap 16 UTM qualification

openSUSE Leap is selectable in production Sandfort. Build the isolated
verification app when repeating its release matrix without changing a
production baseline:

```sh
make opensuse-qualification-app
codesign --verify --deep --strict "dist/Sandfort openSUSE Qualification.app"
```

The qualification app has bundle identifier
`app.sandfort.Sandfort.openSUSEQualification`, stores state under
`~/Library/Application Support/Sandfort openSUSE Qualification`, and prefixes
all UTM names with `Sandfort openSUSE Qualification`. It must never read,
repair, reset, rebuild, or delete production Sandfort state or VMs.

## Setup and baseline

1. Open **Sandfort openSUSE Qualification**, confirm the orange openSUSE
   qualification notice, and use **Check My Mac**.
2. Choose **Create openSUSE Qualification VM**. Confirm the exact Leap 16.0
   Build 18.7 AArch64 cloud QCOW2 downloads with percentage progress and passes
   SHA-256 verification.
3. In UTM, confirm the clearly labeled Baseline Setup VM boots through AArch64
   UEFI, discovers CIDATA, suppresses the serial login prompt, and shows useful
   `[Sandfort]` status messages.
4. Leave setup running through all Zypper transactions. Confirm it either powers
   off automatically after verification or leaves a diagnostic login prompt
   with a clear failure message. Never click **Finish Setup** after a failure.
5. After automatic poweroff, click **Finish Setup**, then confirm Instance 1
   reaches graphical GDM and accepts the displayed credentials. Confirm no text
   `sandfort login:` prompt appears on the console at any point during the boot;
   revision 3 masks `getty@tty1.service` so the graphical greeter is the only
   login shown. Then press Ctrl+Alt+F2 and confirm a text console is still
   reachable for diagnostics, and Ctrl+Alt+F1 returns to the desktop.

Inside openSUSE, verify:

```sh
cat /etc/os-release
cloud-init status --wait
getenforce
systemctl is-enabled gdm.service || systemctl is-enabled display-manager.service
systemctl is-enabled NetworkManager.service
systemctl is-enabled qemu-guest-agent.service
systemctl is-enabled firewalld.service
systemctl is-enabled sandfort-security-update.timer
firewall-cmd --get-default-zone
firewall-cmd --zone=sandfort --list-all
systemctl is-enabled sshd.service
systemctl is-active sshd.service
systemctl is-enabled getty@tty1.service
rpm -q MozillaFirefox
command -v firefox
git --version
curl --version
jq --version
python3 --version
python3.13 -m pip --version
node --version
npm --version
```

Expected security results are enforcing SELinux, GDM, NetworkManager, guest
agent, active firewalld with the empty `sandfort` DROP zone, and an enabled
security-patch timer. SSH must be masked and inactive; those SSH checks are
expected to return nonzero. Confirm the firewall lists no services or ports.
`getty@tty1.service` must report `masked`, which also returns nonzero.

Also confirm Firefox appears in the GNOME activities overview and launches.
Leap's GNOME pattern ships no browser, so the profile installs one explicitly;
a missing browser means the package step regressed, not that the image is
merely minimal. Confirm the sandbox did **not** also acquire a mail client,
IRC client, or BitTorrent client:

```sh
rpm -q evolution polari transmission-gtk
```

Every one of those must report that the package is not installed.

Also run `systemctl --failed` and inspect
`systemctl status NetworkManager-wait-online.service`. Record which service owns
the active interface and whether wait-online delays a clean graphical boot.

## Clean-session matrix

1. Instance 1 initially starts offline. Confirm DNS, HTTPS, and a browser cannot
   reach the Internet.
2. Create a harmless marker file. Use **Reset & Run Clean** without Internet and
   confirm the marker is gone and the guest remains offline.
3. Use **Reset & Run Clean** with Internet and confirm outbound DNS and HTTPS
   work, and that Firefox loads a page. Confirm UTM still has no shared
   directory, clipboard sharing, automatic USB sharing, bridged network, or
   port forward. Confirm
   `nmcli device status` reports Ethernet connected and the active connection is
   `sandfort`; it must not be tied to the baseline's original MAC address.
4. Create Instance 2, boot both instances independently, and confirm their files
   do not cross between guests.
5. Use **Resume** and confirm it preserves the selected instance's files and
   last network choice. Then reset it and confirm its disk state is discarded.
6. Delete an instance and confirm the app and UTM library agree. Exercise
   qualification **Rebuild** once with UTM open and once with UTM closed.
7. Keep an Ubuntu, Fedora, or Debian production instance running while using the
   openSUSE qualification instance. Confirm actions and credentials remain
   isolated between the two apps and UTM environments.

Record the macOS version, Mac model, UTM version, Sandfort version, setup
duration, network ownership, and result of every item. A regression failure
blocks release of openSUSE revision 3. Revisions 1 and 2 are intentionally
incompatible: revision 1 installed no web browser at all, while revision 2 still
left `getty@tty1.service` showing a console login prompt before the graphical
greeter.
