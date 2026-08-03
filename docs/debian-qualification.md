# Debian 13 UTM qualification

Debian is selectable in production Sandfort. Build the isolated verification
app when repeating its release matrix without changing a production baseline:

```sh
make debian-qualification-app
codesign --verify --deep --strict "dist/Sandfort Debian Qualification.app"
```

The qualification app has bundle identifier
`app.sandfort.Sandfort.DebianQualification`, stores state under
`~/Library/Application Support/Sandfort Debian Qualification`, and prefixes all
UTM names with `Sandfort Debian Qualification`. It must never read, repair,
reset, rebuild, or delete production Sandfort state or VMs.

## What is most likely to fail here

Debian's history is networking, and revision 6 adds two untested paths:

- **Networking is this profile's weak spot.** Two revisions were spent on it:
  revision 1 kept first-boot ENI state and revision 2 let Netplan generate a udev
  rule that marked UTM's `enp0s1` unmanaged, so a clean instance with a fresh MAC
  had no Internet. Re-check it rather than assuming: after a reset with Internet,
  `nmcli device status` must show Ethernet connected on the `sandfort`
  connection, not tied to the baseline's original MAC.
- **The browser check expects `firefox-esr`.** Debian's GNOME task installs
  Firefox ESR rather than `firefox`. The shared check accepts either name, but
  that branch has not run; a miss fails setup and produces no baseline.
- **VS Code's sandbox helper.** Debian enables AppArmor but does not restrict
  unprivileged user namespaces the way Ubuntu 24.04 does, so this is less likely
  to bite here than it did there. Confirm anyway that
  `ls -l /usr/local/lib/vscode/*/chrome-sandbox` shows `root root` and mode
  `-rwsr-xr-x`, and that the editor starts.

## Setup and baseline

1. Open **Sandfort Debian Qualification**, confirm the orange Debian
   qualification notice, and use **Check My Mac** (the stethoscope button in the toolbar).
2. Choose **Create Debian Qualification VM**. Confirm the exact Debian 13
   (Trixie) image downloads with percentage progress and passes SHA-256
   verification.
3. In UTM, confirm the clearly labeled Baseline Setup VM boots through AArch64
   UEFI, discovers CIDATA, suppresses the serial login prompt, and shows useful
   `[Sandfort]` status messages.
4. Leave setup running through all APT transactions. Confirm it either powers
   off automatically after verification or leaves a diagnostic login prompt
   with a clear failure message. Never click **Finish Setup** after a failure.
5. After automatic poweroff, click **Finish Setup**, then confirm Instance 1
   reaches graphical GDM and accepts the displayed credentials.

Inside Debian, verify:

```sh
cat /etc/debian_version
cloud-init status --wait
aa-enabled
systemctl is-enabled gdm3.service
systemctl is-enabled NetworkManager.service
systemctl is-enabled qemu-guest-agent.service
systemctl is-enabled unattended-upgrades.service
ufw status verbose
systemctl is-enabled ssh.service
systemctl is-active ssh.service
git --version
curl --version
jq --version
python3 --version
pip3 --version
node --version
npm --version
```

Expected security results are enabled AppArmor, GDM, NetworkManager, guest
agent, unattended upgrades, active UFW with deny-incoming/allow-outgoing
defaults, and masked/inactive SSH. The expected SSH checks return nonzero.

Also run `systemctl --failed` and inspect
`systemctl status systemd-networkd-wait-online.service NetworkManager-wait-online.service`.
Record which service owns the active interface and whether either wait service
delays a clean graphical boot. Do not copy Ubuntu's masking policy into Debian
without this evidence.

## Clean-session matrix

1. Instance 1 initially starts offline. Confirm DNS, HTTPS, and a browser cannot
   reach the Internet.
2. Create a harmless marker file. Use **Reset & Run Clean** without Internet and
   confirm the marker is gone and the guest remains offline.
3. Use **Reset & Run Clean** with Internet and confirm outbound DNS and HTTPS
   work. Confirm UTM still has no shared directory, clipboard sharing,
   automatic USB sharing, bridged network, or port forward.
   Confirm `nmcli device status` reports the Ethernet device as connected and
   `nmcli -g GENERAL.CONNECTION device show` reports the `sandfort` profile.
4. Create Instance 2, boot both instances independently, and confirm their files
   do not cross between guests.
5. Use **Resume** and confirm it preserves the selected instance's files and
   last network choice. Then reset it and confirm its disk state is discarded.
6. Delete an instance and confirm the app and UTM library agree. Exercise
   qualification **Rebuild** once with UTM open and once with UTM closed.

Record the macOS version, Mac model, UTM version, Sandfort version, setup
duration, networking ownership, and result of every item. A regression failure
blocks release of Debian revision 6. Revisions 1 to 5 are intentionally
incompatible: revision 1 retained first-boot ENI state, revision 2 still allowed
Netplan to generate a udev rule that marked UTM's `enp0s1` adapter unmanaged,
revision 3 still showed a console login prompt before the greeter, revision 4
added no editor and no terminal or browser verification, and revision 5 installed
a Visual Studio Code that could not launch.

Revision 4 masks `getty@tty1.service`. Confirm no text `sandfort login:` prompt
appears during boot, that `systemctl is-enabled getty@tty1.service` reports
`masked`, and that Ctrl+Alt+F2 still reaches a rescue console.
