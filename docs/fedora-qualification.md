# Fedora 44 UTM qualification

Fedora is selectable in production Sandfort. Build the isolated verification app
when repeating its release matrix without changing a production baseline:

```sh
make qualification-app
codesign --verify --deep --strict "dist/Sandfort Fedora Qualification.app"
```

The qualification app has bundle identifier
`app.sandfort.Sandfort.FedoraQualification`, stores its state under
`~/Library/Application Support/Sandfort Fedora Qualification`, and prefixes all
of its UTM names with `Sandfort Fedora Qualification`. It must never read,
repair, reset, rebuild, or delete production Sandfort state or VMs.

## What is most likely to fail here

Two Fedora-specific risks in revision 4, neither yet exercised:

- **The terminal check has never run on Fedora.** Fedora ships Ptyxis as its
  terminal rather than GNOME Terminal. The shared check accepts either, but that
  branch is untested. If it fails, setup fails and no baseline is produced;
  record what `command -v ptyxis gnome-terminal kgx gnome-console` reports.
- **VS Code's sandbox helper under SELinux.** Electron needs
  `/usr/local/lib/vscode/<version>/chrome-sandbox` owned by root and setuid.
  Fedora runs SELinux in enforcing mode, and the file is installed outside the
  usual system paths, so a denial is plausible even when the ownership is right.
  If VS Code will not start, check `sudo ausearch -m avc -ts recent` before
  anything else, and confirm `ls -l /usr/local/lib/vscode/*/chrome-sandbox`
  shows `root root` with mode `-rwsr-xr-x`.

## Setup and baseline

1. Open **Sandfort Fedora Qualification**, confirm the orange qualification
   notice, and use **Check My Mac** (the stethoscope button in the toolbar).
2. Choose **Create Fedora Qualification VM**. Confirm the exact Fedora Cloud 44
   image downloads with percentage progress and passes SHA-256 verification.
3. In UTM, confirm the clearly labeled Baseline Setup VM boots through AArch64
   UEFI, discovers the CIDATA disk, suppresses the serial login prompt, and shows
   useful `[Sandfort]` status messages.
4. Leave setup running through all DNF5 transactions. Confirm it either powers
   off automatically after verification or leaves a diagnostic login prompt with
   a clear failure message. Never click **Finish Setup** after a failure.
5. After automatic poweroff, click **Finish Setup**, then confirm Instance 1
   reaches graphical GDM and accepts the credentials displayed by the
   qualification app.

Inside Fedora, verify:

```sh
cat /etc/fedora-release
cloud-init status --wait
getenforce
systemctl is-enabled gdm.service
systemctl is-enabled NetworkManager.service
systemctl is-enabled qemu-guest-agent.service
systemctl is-active firewalld.service
firewall-cmd --get-default-zone
firewall-cmd --zone=sandfort --list-all
systemctl is-enabled dnf5-automatic.timer
systemctl is-enabled sshd.service
systemctl is-active sshd.service
git --version
curl --version
jq --version
python3 --version
pip3 --version
node --version
npm --version
```

Expected security results are `Enforcing`, enabled GDM/NetworkManager/guest
agent/automatic-update services, active firewalld with default zone `sandfort`
and no allowed services or ports, and masked/inactive SSH. `systemctl` returns a
nonzero status for the expected masked/inactive SSH checks.

## Clean-session matrix

1. Instance 1 initially starts offline. Confirm DNS, HTTPS, and the browser
   cannot reach the Internet.
2. Create a harmless marker file. Use **Reset & Run Clean** without Internet and
   confirm the marker is gone and the guest remains offline.
3. Use **Reset & Run Clean** with Internet and confirm outbound DNS and HTTPS
   work. Confirm UTM still has no shared directory, clipboard sharing, automatic
   USB sharing, bridged network, or port forward.
4. Create Instance 2, boot both instances independently, and confirm their files
   do not cross between guests.
5. Use **Resume** and confirm it preserves the selected instance's files and last
   network choice. Then reset it and confirm its disk state is discarded.
6. Delete an instance and confirm the app and UTM library agree. Exercise
   qualification **Rebuild** once with UTM open and once with UTM closed.

Record the macOS version, Mac model, UTM version, Sandfort version, duration,
and result of every item. A regression failure blocks release of the affected
Fedora profile revision. Revision 4 adds Visual Studio Code and the terminal and
browser verification; revisions 1 to 3 are intentionally incompatible.
