<!--
Copyright 2026 Shazron Abdullah and Sandfort contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Sandfort Help

Sandfort creates disposable Linux virtual machines for work you do not trust. It uses UTM on Apple silicon Macs and keeps a protected baseline separate from the sandbox instances you run.

Sandfort reduces risk, but a virtual machine is not a perfect security boundary. Keep macOS, UTM, and the selected Linux distribution updated, and never put personal accounts, secrets, wallets, SSH keys, cloud credentials, or important files inside a sandbox.

## Start here

Before creating a sandbox:

- Install [UTM](https://mac.getutm.app/). Sandfort finds it wherever macOS has
  registered it, not only in your Applications folder. If it is missing, the
  main window offers a **Get UTM** button, and **Check My Mac** reports which
  UTM version Sandfort can see and where.
- Make sure the Mac has enough free space for the selected Linux download, protected baseline, and each independent instance.
- Quit or stop any Sandfort VMs before rebuilding or resetting them.

The first time you open Sandfort, it explains what a sandbox does and does not
protect and asks you to acknowledge those limits. You only see this once.
Updating Sandfort does not ask again; only a change to the notice itself does.
To read it again at any time, open **Sandfort → Settings → Safety** and choose
**Show Safety Notice Again**.

To create Sandfort for the first time:

1. Open Sandfort, choose an Ubuntu, Fedora, Debian, or openSUSE environment, and select the development tools you want.
2. Click the selected distribution's **Create Environment** action.
3. Leave the setup VM running in UTM while Linux updates itself and installs the desktop and selected tools.
4. Wait for the setup VM to power itself off automatically. Ubuntu commonly takes 10–30 minutes; Fedora, Debian, and openSUSE commonly take 20–45 minutes. Any distribution can take longer on a slow package mirror.
5. Return to Sandfort and click **Finish Setup**.
6. Sandfort protects the completed baseline and creates **Sandbox Instance 1**.

Do not manually shut down the setup VM. Do not click **Finish Setup** while Linux is still running or installing packages.

## Linux environments and protected baselines

Each Linux environment has its own **Protected Baseline**, credentials, development-tool configuration, and numbered instances. Never start a baseline directly in UTM and never use it for suspicious work.

Use **Add Linux Environment** at the bottom of the sidebar to create Ubuntu, Fedora, Debian, and openSUSE environments side by side. Select an environment in the sidebar to manage its instances. Instances from different environments can run at the same time because their disks, firmware state, VM identifiers, and network addresses are independent.

The selected environment's baseline contains its Linux distribution, desktop, security settings, updates, and development tools. Changes made inside an instance do not update the baseline. **Rebuild** replaces only the selected environment. **Delete Environment** removes only the selected environment after confirmation. Both leave other environments and verified image downloads unchanged.

## Run a sandbox instance

Every instance is listed as its own row, and each row's buttons act on that
instance. There is no separate selection step.

- **Resume** continues the instance exactly where you left it. Its files, changes, contamination, and last selected network mode remain.
- **Reset & Run Clean** deletes that instance's changes and restores it from the Protected Baseline.
- **Rename Instance**, in the row's **⋯** menu, adds or changes its descriptive label without changing its number, disk, or identity.
- **Shut Down Instance**, in the row's **⋯** menu, asks the guest to power itself down.
- **Delete Instance**, also in the row's **⋯** menu, unregisters the stopped instance from UTM, waits for UTM to confirm its removal, and moves its bundle to macOS Trash. It does not change the baseline or other instances.

**Shut Down Instance** asks the guest to power itself down, the same as choosing shut down inside the desktop. It waits until the instance has really stopped before reporting success. The instance's disk is untouched, so **Resume** reopens it exactly as it was.

A desktop guest can refuse. If something is unsaved, or a dialog is waiting for an answer, the guest will not power down and Sandfort says so rather than forcing it — a forced stop is a pulled power cable, and it can corrupt the filesystem. Answer the dialog in the VM, or stop it from UTM.

UTM leaves its window open showing the stopped machine. Close that window yourself; UTM does not close it, and no app can close it from outside.

### Something is still running

**Reset & Run Clean**, **Delete Instance**, **Rebuild**, and **Delete Environment** all need the virtual machine's disk to be idle, so none of them can run while the guest is on. Sandfort now says which machines are in the way and offers **Shut Down and Continue** instead of sending you to UTM.

Reset and Delete Instance only ever name the one instance. Rebuild and Delete Environment reach the Protected Baseline and every instance in that environment, so the list can be longer than you expect — read it before continuing.

Nothing is shut down unless you choose it, and nothing is forced. A guest with unsaved work can refuse, and Sandfort reports that rather than pulling its power.

Use **New Clean Sandbox** to create another independent numbered instance. Instances have separate disks, UEFI state, VM identifiers, and network addresses, so more than one can run at the same time.

Deleted instance numbers are not reused.

## Choose network access

Sandfort asks for a network mode when creating or resetting an instance.

- **Without Internet** is the default and safest option. The guest cannot reach the Internet or the Mac host.
- **With Internet** allows outbound access so the guest can download packages or reach websites. Untrusted software can also contact external systems.

Shared host folders, clipboard sharing, automatic USB sharing, bridged networking, incoming port forwarding, and SSH remain disabled in both modes. Optional **materials** are not an exception to that: Sandfort copies what you choose into a read-only disc image *before* the instance starts, so the guest reads a copy and has no path back to the original or to anything else on your Mac. See **Bring files into a sandbox** below.

Resume does not ask again because it preserves the instance's last explicit network mode. Use **Reset & Run Clean** to choose a different mode and start from the baseline.

## Bring files into a sandbox

A sandbox has no shared folders, clipboard, or USB, so there is otherwise no way to hand it a file that is already on your Mac. **Materials** are the one exception, and they only go one way.

Select an instance, then choose **Materials…** from the environment's actions menu. Pick a file or a folder and Sandfort packs it into a read-only disc image attached to that instance.

The instance must be **fully powered off**, not suspended — attaching rewrites its configuration, and Sandfort will not touch a VM whose disk is in use. Afterwards, **Resume** is enough; you do not need to reset, and resetting would throw away everything else in that instance to deliver a file you have already attached.

Inside the guest, open **Files** and look for **SANDFORT_MATERIALS**. Where it appears depends on the distribution: Ubuntu lists it as a CD in the sidebar, while others show it under **Other Locations**. Click it to open. From a terminal:

```
lsblk -f                     # look for an iso9660 volume, normally /dev/sr0
ls /run/media/$USER/SANDFORT_MATERIALS
```

If it is not mounted, mount it by label:

```
sudo mkdir -p /mnt/materials
sudo mount -o ro /dev/disk/by-label/SANDFORT_MATERIALS /mnt/materials
```

A **folder** is sent as a single `.zip` archive named after it — extract it inside the sandbox. `unzip` is not preinstalled on every distribution; Files' **Extract Here** works on the desktop, and `python3 -m zipfile -e archive.zip .` works in a terminal when Python is selected.

Materials are limited to 512 MB. For anything larger, run the instance with Internet access and download it inside the guest instead.

**Reset & Run Clean re-attaches the image you approved**, not a fresh copy of wherever it came from. If you picked a folder in March and reset in June, the sandbox gets what the folder held in March. Use **Materials… → Replace…** to send in the current contents. **Remove** detaches the image and deletes it.

Materials never reach a Protected Baseline. If one somehow appears there, Sandfort removes it — the drive and the file — the next time it reads its state.

### What read-only does and does not mean

The guest cannot change the image and cannot reach the original file, because it is handed a copy Sandfort built. That much does not depend on any setting.

It does **not** mean the contents are safe. Anything you send into a sandbox is readable by whatever runs there. Send a work file only if you accept that a hostile program in that instance can read it, and never a credential, key, wallet, or secret.

## Configure development tools

Open the environment's actions menu (**⋯**, beside the main button) and choose **Development Tools…** before creating or rebuilding the baseline.

Git, curl, and jq are always installed. Python development tools, the latest Node.js LTS with npm, and Visual Studio Code can be selected in the app. Visual Studio Code is on by default.

Visual Studio Code is downloaded from Microsoft during setup and checked against Microsoft's published SHA-256. It is Microsoft's own build with stock settings, so its telemetry is on by default; turn it off in the editor's settings if you would rather it did not report usage.

Advanced mode accepts a custom setup script. The script:

- Runs as root inside the selected Linux guest during trusted baseline creation.
- Never runs on the Mac host.
- Applies only to the next baseline rebuild.
- Must never contain code copied from an untrusted challenge.
- Fails the whole setup if it exits with an error, so no baseline is created.

Setup has Internet access even though clean instances start offline, so install
or cache anything you will need later while the script runs. The project's
`docs/custom-setup-scripts.md` covers the rules in full and has worked examples,
including caching dependencies for offline use, extra language toolchains,
rootless containers, and desktop settings.

Changing a tool option or script does not modify an existing baseline. Choose **Rebuild** to apply the new configuration.

## Linux sign-in

Each sandbox instance is a row with its own **Resume** and **Reset & Run Clean** buttons, and a **⋯** menu holding **Shut Down Instance**, **Rename Instance**, and **Delete Instance**. **Rebuild** and **Delete Environment** are in the environment's **⋯** menu beside the main button, away from everyday actions.


Sandfort displays the guest username and password in the app. The password is hidden until you click the eye button, so it is not exposed in screenshots or screen sharing; a copy button puts it on the clipboard without revealing it. New baselines use the username `sandfort` and a memorable four-word, hyphen-separated password.

Every instance created from one baseline shares that baseline's credentials. The password is generated locally and is not transmitted or logged.

During Rebuild, Sandfort prefills the current password. You can keep it, enter another valid password, or use the recycle button to generate a new four-word password.

## Rebuild safely

Rebuild is destructive within the selected environment. It removes that Protected Baseline and its recorded instances from UTM, then deletes those app-owned VM bundles. Other Linux environments are not changed.

Before rebuilding:

1. Shut down every Sandfort VM.
2. Confirm that no instance contains work you need to keep.
3. Review the development-tool choices and custom setup script.
4. Confirm the password for the selected environment's replacement baseline.

Sandfort opens UTM automatically if it is closed and waits for its automation interface to become ready. If macOS asks whether Sandfort may control UTM, allow it. Sandfort uses native Apple Events to remove only the recorded Sandfort VMs. It does not use AppleScript or UI automation.

### Why macOS asks whether Sandfort may control UTM

macOS shows this once, the first time Sandfort needs to talk to UTM. That is
usually when you create an environment or start a sandbox, not only when you
rebuild.

Sandfort needs it to start a sandbox for you. Opening a virtual machine hands it
to UTM, which adds it to the library in the background; Sandfort waits until UTM
confirms the machine is there, then asks UTM to start it. Both of those are
questions put to UTM, and macOS treats asking as controlling.

You can decline, and everything else still works: Sandfort downloads, verifies,
builds, and adds the virtual machine exactly as before. It cannot start it. The
sandbox appears in UTM's list and waits for you to press play, and the activity
log says so rather than pretending it started.

To change your answer later, open System Settings → Privacy & Security →
Automation and turn UTM on or off under Sandfort.

## Troubleshooting setup

### The setup VM shows an Ubuntu login prompt

The setup terminal can show a login prompt while cloud-init continues in the background. Do not log in and do not shut down the VM. Wait for it to finish and power itself off automatically.

If you previously logged in and want to check progress, run `cloud-init status --wait`. A result of `done` means cloud-init has finished, but still wait for the setup process to verify the selected tools and power off.

### Package installation retries or fails

Ubuntu package mirrors can be temporarily slow or unavailable. Sandfort retries baseline package installation and logs a concise status message in the UTM terminal.

Verify that the Mac itself has Internet access. Setup requires temporary outbound Internet access even though clean instances default to offline. If all retries fail, leave the failed setup stopped and choose **Rebuild** later.

### Setup appears stuck on journal messages

Messages about rotating, flushing, or starting the system journal can appear near the end of setup or boot. Give the VM several minutes. Sandfort configures compact journals during baseline setup so clean instances do not repeatedly wait for large persistent logs.

### The setup terminal is too noisy

Turn off **Show detailed setup output** before the next Rebuild for concise Sandfort progress messages. Turn it on only when diagnosing package-manager output.

### Copy the Sandfort activity log

Each entry is stamped with the time of day and, during an operation, how long that operation had been running. The clock lets you line the log up against `/var/log/sandfort-setup.log` inside the guest; the elapsed column makes a slow step obvious.

Use the copy icon beside the status heading to copy the complete activity log, timestamps included, to the macOS clipboard. You can paste it into a text file or support message when diagnosing a problem. Sandfort does not intentionally write the guest password to this log, but review copied text before sharing it.

## Troubleshooting clean instances

### UTM says “Display output is not active”

The Protected Baseline and setup VM use a serial terminal. Clean instances use the graphical display.

Confirm that you launched a numbered instance through Sandfort rather than starting the Protected Baseline directly in UTM. If the selected instance was created by an older or incomplete setup, stop it and use **Reset & Run Clean**. Rebuild if the baseline itself never completed.

### The desktop login does not appear

Linux can display boot and journal messages before the graphical login manager starts. Wait several minutes, especially on the first clean boot. If it never appears, stop the VM, use **Reset & Run Clean**, and ensure the baseline originally powered itself off before **Finish Setup** was clicked.

### A selected tool is missing

Tool selections apply only while building a baseline. Expanding the tool section or changing its values does not update the current baseline.

Choose **Rebuild**, select the tool, let setup power itself off automatically, then click **Finish Setup**. New and reset instances created from that baseline will contain the tool.

### Node.js is an older distribution version

When **Latest Node.js LTS + npm** is selected, Sandfort downloads and verifies the official Linux ARM64 Node.js LTS archive during baseline setup. Rebuild the baseline to replace an older distribution package. Verify with `node --version` and `npm --version` inside a new or reset instance.

### An Internet-enabled instance has no Internet

Network mode is applied when an instance is created or reset. Resume preserves the old mode.

Stop the VM, choose **Reset & Run Clean**, and select **Continue With Internet**. Do not launch the VM directly from UTM because that can reuse an earlier saved configuration.

### UTM shows an unavailable or duplicate entry

Always create, reset, rename, and delete instances through Sandfort. Current versions wait for UTM to confirm removal before deleting app state. An unavailable entry left by an older Sandfort version is no longer recorded by the app; select only that unavailable entry in UTM and use UTM's trash button once.

### Sandfort says a VM is running

Sandfort will not copy, reset, rename, delete, or rebuild a VM whose disk is in use. Shut the guest down fully in UTM rather than suspending it, then try again.

## Security rules

- Prefer offline instances for suspicious code.
- Never sign in to personal or work accounts inside a sandbox.
- Never copy secrets, SSH keys, password-manager data, wallets, or cloud credentials into a sandbox, including as materials.
- Never enable shared folders, clipboard sharing, USB sharing, bridged networking, or port forwarding in UTM.
- Never run the Protected Baseline directly.
- Treat a resumed instance as potentially contaminated.
- Reset the selected instance before beginning unrelated untrusted work.
- Keep macOS, UTM, the selected Linux distribution, and Sandfort updated.

## Where Sandfort stores data

Sandfort stores its state, verified image cache, Protected Baseline, and instances under the current user's `Library/Application Support/Sandfort` directory.

Open **Sandfort → Settings** to see the exact Linux image-cache location. The settings pane can reveal it in Finder or copy its path. Its read-only **Environment downloads** section lists the exact official HTTPS source URL used for each Ubuntu, Fedora, Debian, and openSUSE image. Production environments share `~/Library/Application Support/Sandfort/Cache`; isolated verification builds use their own cache directory.

Do not manually move or edit these files while Sandfort or UTM is open. Use Sandfort's instance and rebuild controls so its saved state and UTM's library remain consistent.

## More information

Visit [sandfort.app](https://sandfort.app/) for project information. Technical contributors can consult the repository README, architecture document, and security model.
