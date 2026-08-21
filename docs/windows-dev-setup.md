# Windows development setup

**Nothing of Sandfort builds on Windows today.** `Package.swift` declares
`platforms: [.macOS(.v13)]` and one target whose files import SwiftUI and
AppKit, `make test` and `make app` are macOS-only, and there is no Windows CI
job. This page gets a machine ready to *start* the port described in
[WINDOWS.md](WINDOWS.md). It is not a build guide, and it does not replace
[CONTRIBUTING.md](../CONTRIBUTING.md), which describes the macOS setup that
builds the shipping app.

Read the plan first. Everything here follows from decisions made there.

## Install nothing yet, if you are here to decide

Two things gate the list below, and both are cheaper to settle before a download
than after one.

**The core language is undecided.** `WINDOWS.md` lists it as the first open
question and warns that it is expensive to revisit. It picks which toolchain
section applies, and those are not the same size: the Swift path installs Visual
Studio 2022 before it installs a compiler, and the .NET path is one SDK.

**Phase 0 is macOS work.** Widening `VirtualMachineProvider` to cover lifecycle,
and splitting the package into a portable core and a macOS UI target, both
happen on a Mac with the existing suite green. A Windows machine cannot start
either. If there is one task in front of you today, it is on the other operating
system.

## Host requirements

[WINDOWS.md](WINDOWS.md#host-requirements) states the floor and the reasoning.
The short version: Windows 10 version 2004 on x86-64, Windows 11 24H2 with the
2025 updates on ARM64, SLAT plus Intel VT-x with EPT and Unrestricted Guest or
AMD SVM, and virtualization enabled in firmware.

Enable the hypervisor API from an **elevated** PowerShell, then reboot:

```powershell
DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All
```

Confirm it afterwards. The query needs elevation too, which is worth knowing
before you conclude the feature is missing:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
```

**Whether this works on Windows Home is unverified.** The plan explains why it
probably does and why that is not good enough to publish. If you are setting up
a Home machine, you are also answering an open question — record what you find.

## What every path needs

Package IDs below were checked against the `winget` source rather than
remembered; versions are what that source offered when this page was written and
will drift.

| Tool | winget | Why |
| --- | --- | --- |
| QEMU | `SoftwareFreedomConservancy.QEMU` | The hypervisor the plan recommends |
| Git | `Git.Git` | |
| GitHub CLI | `GitHub.cli` | Pull requests; every change goes through one |
| Python 3 | `Python.Python.3.12` | `tools/packaging/check-pull-request.py`, which CI runs |

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e --source winget
winget install --id Git.Git -e --source winget
winget install --id GitHub.cli -e --source winget
winget install --id Python.Python.3.12 -e --source winget
```

QEMU has two other supported routes if you prefer them: [Stefan Weil's
installers](https://qemu.weilnetz.de/w64/), which the QEMU project links from
its own [download page](https://www.qemu.org/download/#windows), and MSYS2
(`pacman -S mingw-w64-ucrt-x86_64-qemu`).

## The toolchain, once the language is decided

Install exactly one of these. Installing all three to keep options open is how
the decision stays unmade.

### If the core is Swift

The largest install by a wide margin, and the only one that shares the existing
guest profiles rather than hand-porting them. [swift.org's Windows
instructions](https://www.swift.org/install/windows/) document Visual Studio
2022 Community with specific components as the prerequisite — not Build Tools —
followed by the toolchain:

```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

SwiftUI does not exist on Windows. Choosing Swift shares the core and still
leaves the view layer to WinUI 3 or Avalonia, exactly as the plan says.

### If the core is C#

One SDK, nothing else, and it may already be present:

```powershell
winget install --id Microsoft.DotNet.SDK.10 -e --source winget
```

The cheapest setup and the most expensive commitment: the guest profiles,
cloud-init, the OpenPGP verifier, and the QCOW2 and ISO writers all get
hand-ported, and every future guest change lands twice.

### If the core is Rust

```powershell
winget install --id Rustlang.Rustup -e --source winget
```

Same hand-port cost as C#, with a stronger story for the byte-level work in
`DiskUtilities` and `ISO9660Writer` and a weaker one for a native desktop UI.

## Verifying the machine

```powershell
qemu-system-x86_64 --version
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent    # expect True
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform   # elevated
```

`HypervisorPresent` being true means *a* hypervisor holds the root partition —
Hyper-V, WSL2, or VBS all cause it. It is necessary, not sufficient; only the
feature query answers whether WHPX itself is available.

## What you still cannot do here

- **Build or test Sandfort.** `make test` and `make app` require macOS and a
  Swift toolchain with Apple's frameworks. There is no non-UI target to build
  until phase 0 splits the package.
- **Run a boot smoke test.** That needs a provider, and no provider exists.
- **Run CI.** `Tests / macos-arm64` is the only job; a Windows job arrives with
  phase 1.

You can, however, settle two of the plan's open questions today without any of
that:

- [windows-qemu-spike.md](windows-qemu-spike.md) — does WHPX accelerate, and
  does `restrict=on` isolate? Needs only QEMU.
- [core-language-spike.md](core-language-spike.md) — can the guest contract be
  hand-ported at all? Needs only the candidate language's SDK, and it decides
  which section above you needed in the first place.

## Links

- [WINDOWS.md](WINDOWS.md) — the plan this setup serves
- [windows-qemu-spike.md](windows-qemu-spike.md) — what to do with QEMU once it
  is installed, before any port work begins
- [core-language-spike.md](core-language-spike.md) — how to settle the core
  language with an experiment instead of an argument
- [QEMU on Windows](https://www.qemu.org/download/#windows) and its
  [WHPX documentation](https://www.qemu.org/docs/master/system/whpx.html)
- [Windows Hypervisor Platform API](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform)
- [Install Hyper-V](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v)
  — for the edition restriction that does *not* apply to WHPX
- [Swift on Windows](https://www.swift.org/install/windows/)
- [.NET downloads](https://dotnet.microsoft.com/download) ·
  [rustup](https://rustup.rs/)
