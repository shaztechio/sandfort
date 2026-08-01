# Sandfort Help

Sandfort creates disposable Linux virtual machines for work you do not trust. It uses UTM on Apple silicon Macs and keeps a protected baseline separate from the sandbox instances you run.

Sandfort reduces risk, but a virtual machine is not a perfect security boundary. Keep macOS, UTM, and Ubuntu updated, and never put personal accounts, secrets, wallets, SSH keys, cloud credentials, or important files inside a sandbox.

## Start here

Before creating a sandbox:

- Install [UTM](https://mac.getutm.app/).
- Make sure the Mac has enough free space for the Ubuntu download, protected baseline, and each independent instance.
- Quit or stop any Sandfort VMs before rebuilding or resetting them.

To create Sandfort for the first time:

1. Open Sandfort and select the development tools you want in the baseline.
2. Click **Create Sandbox**.
3. Leave the setup VM running in UTM while Ubuntu updates itself and installs the desktop and selected tools.
4. Wait for the setup VM to power itself off automatically. This commonly takes 10–30 minutes and can take longer on a slow package mirror.
5. Return to Sandfort and click **Finish Setup**.
6. Sandfort protects the completed baseline and creates **Sandbox Instance 1**.

Do not manually shut down the setup VM. Do not click **Finish Setup** while Ubuntu is still running or installing packages.

## Understand the protected baseline

The **Protected Baseline** is the trusted source used to make clean instances. Never start it directly in UTM and never use it for suspicious work.

The baseline contains Ubuntu, the desktop, security settings, updates, and the development tools selected when it was built. Changes made inside an instance do not update the baseline.

Use **Rebuild** when you want to change the baseline itself. Rebuild deletes the protected baseline and every sandbox instance after confirmation, while retaining the verified Ubuntu download.

## Run a sandbox instance

Select an instance, then open **Run Instance**.

- **Resume Instance** continues the instance exactly where you left it. Its files, changes, contamination, and last selected network mode remain.
- **Reset & Run Clean** deletes that instance's changes and restores it from the Protected Baseline.
- **Rename Instance** adds or changes its descriptive label without changing its number, disk, or identity.
- **Delete Instance** moves the stopped instance bundle to macOS Trash. It does not change the baseline or other instances.

Use **New Clean Sandbox** to create another independent numbered instance. Instances have separate disks, UEFI state, VM identifiers, and network addresses, so more than one can run at the same time.

Deleted instance numbers are not reused.

## Choose network access

Sandfort asks for a network mode when creating or resetting an instance.

- **Without Internet** is the default and safest option. The guest cannot reach the Internet or the Mac host.
- **With Internet** allows outbound access so the guest can download packages or reach websites. Untrusted software can also contact external systems.

Shared host folders, clipboard sharing, automatic USB sharing, bridged networking, incoming port forwarding, and SSH remain disabled in both modes.

Resume does not ask again because it preserves the instance's last explicit network mode. Use **Reset & Run Clean** to choose a different mode and start from the baseline.

## Configure development tools

Expand **Development tools for the next baseline** before creating or rebuilding the baseline.

Git, curl, and jq are always installed. Python development tools and the latest Node.js LTS with npm can be selected in the app.

Advanced mode accepts a custom setup script. The script:

- Runs as root inside Ubuntu during trusted baseline creation.
- Never runs on the Mac host.
- Applies only to the next baseline rebuild.
- Must never contain code copied from an untrusted challenge.

Changing a tool option or script does not modify an existing baseline. Choose **Rebuild** to apply the new configuration.

## Ubuntu sign-in

Sandfort displays the Ubuntu username and password in the app. New baselines use the username `sandfort` and a memorable four-word, hyphen-separated password.

Every instance created from one baseline shares that baseline's credentials. The password is generated locally and is not transmitted or logged.

During Rebuild, Sandfort prefills the current password. You can keep it, enter another valid password, or use the recycle button to generate a new four-word password.

## Rebuild safely

Rebuild is destructive. It removes the Protected Baseline and all recorded instances from UTM, then deletes the app-owned VM bundles.

Before rebuilding:

1. Shut down every Sandfort VM.
2. Confirm that no instance contains work you need to keep.
3. Review the development-tool choices and custom setup script.
4. Confirm the Ubuntu password for the new baseline.

Sandfort opens UTM automatically if it is closed and waits for its automation interface to become ready. If macOS asks whether Sandfort may control UTM, allow it. Sandfort uses native Apple Events to remove only the recorded Sandfort VMs. It does not use AppleScript or UI automation.

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

Use the copy icon beside the status heading to copy the complete activity log to the macOS clipboard. You can paste it into a text file or support message when diagnosing a problem. Sandfort does not intentionally write the Ubuntu password to this log, but review copied text before sharing it.

## Troubleshooting clean instances

### UTM says “Display output is not active”

The Protected Baseline and setup VM use a serial terminal. Clean instances use the graphical display.

Confirm that you launched a numbered instance through Sandfort rather than starting the Protected Baseline directly in UTM. If the selected instance was created by an older or incomplete setup, stop it and use **Reset & Run Clean**. Rebuild if the baseline itself never completed.

### The desktop login does not appear

Ubuntu can display boot and journal messages before the graphical login manager starts. Wait several minutes, especially on the first clean boot. If it never appears, stop the VM, use **Reset & Run Clean**, and ensure the baseline originally powered itself off before **Finish Setup** was clicked.

### A selected tool is missing

Tool selections apply only while building a baseline. Expanding the tool section or changing its values does not update the current baseline.

Choose **Rebuild**, select the tool, let setup power itself off automatically, then click **Finish Setup**. New and reset instances created from that baseline will contain the tool.

### Node.js is an older Ubuntu version

When **Latest Node.js LTS + npm** is selected, Sandfort downloads and verifies the official Linux ARM64 Node.js LTS archive during baseline setup. Rebuild the baseline to replace an older distribution package. Verify with `node --version` and `npm --version` inside a new or reset instance.

### An Internet-enabled instance has no Internet

Network mode is applied when an instance is created or reset. Resume preserves the old mode.

Stop the VM, choose **Reset & Run Clean**, and select **Continue With Internet**. Do not launch the VM directly from UTM because that can reuse an earlier saved configuration.

### UTM shows an unavailable or duplicate entry

Always create, reset, rename, and delete instances through Sandfort. If UTM still shows an unavailable entry after Sandfort moved its bundle to Trash, select only that unavailable entry in UTM and use UTM's trash button to remove the stale registration.

### Sandfort says a VM is running

Sandfort will not copy, reset, rename, delete, or rebuild a VM whose disk is in use. Shut the guest down fully in UTM rather than suspending it, then try again.

## Security rules

- Prefer offline instances for suspicious code.
- Never sign in to personal or work accounts inside a sandbox.
- Never copy secrets, SSH keys, password-manager data, wallets, or cloud credentials into a sandbox.
- Never enable shared folders, clipboard sharing, USB sharing, bridged networking, or port forwarding in UTM.
- Never run the Protected Baseline directly.
- Treat a resumed instance as potentially contaminated.
- Reset the selected instance before beginning unrelated untrusted work.
- Keep macOS, UTM, Ubuntu, and Sandfort updated.

## Where Sandfort stores data

Sandfort stores its state, verified image cache, Protected Baseline, and instances under the current user's `Library/Application Support/Sandfort` directory.

Do not manually move or edit these files while Sandfort or UTM is open. Use Sandfort's instance and rebuild controls so its saved state and UTM's library remain consistent.

## More information

Visit [sandfort.app](https://sandfort.app/) for project information. Technical contributors can consult the repository README, architecture document, and security model.
