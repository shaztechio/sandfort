// Copyright 2026 Shazron Abdullah and Sandfort contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import SandfortApp

/// Contract tests for what every guest ends up containing.
final class GuestToolingTests: XCTestCase {
    private let credentials = SandboxCredentials(username: "sandfort", password: "safe-test")

    /// Same extraction the rest of the suite uses: the finalizer is base64 into
    /// the seed, so assertions have to decode it rather than match the YAML.
    private func finalizer(
        _ profile: LinuxGuestProfile,
        tools: SandboxToolSelection = .recommended
    ) throws -> String {
        let isoText = String(
            decoding: try profile.seedISO(credentials: credentials, tools: tools),
            as: UTF8.self
        )
        let section = try XCTUnwrap(isoText.range(of: "- path: /var/lib/sandfort/baseline-finalize.sh"))
        let tail = isoText[section.lowerBound...]
        let contentLine = try XCTUnwrap(tail.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("content: ")
        })
        let encoded = contentLine.trimmingCharacters(in: .whitespaces).dropFirst("content: ".count)
        return String(decoding: try XCTUnwrap(Data(base64Encoded: String(encoded))), as: UTF8.self)
    }

    /// A desktop with no terminal or no browser looks finished and is not.
    /// openSUSE shipped both defects, one revision apart.
    func testEveryProfileVerifiesATerminalAndABrowser() throws {
        for profile in LinuxGuestCatalog.profiles {
            let script = try finalizer(profile)
            XCTAssertTrue(
                script.contains(GuestProvisioningSupport.terminalVerificationCommand),
                "\(profile.id) does not verify a terminal"
            )
            XCTAssertTrue(
                script.contains(GuestProvisioningSupport.browserVerificationCommand),
                "\(profile.id) does not verify a browser"
            )
        }
    }

    /// Checks the binary, not the package: on Ubuntu both firefox and
    /// chromium-browser are transitional packages for snaps, so a package query
    /// can succeed while nothing usable is installed.
    func testTerminalAndBrowserChecksLookForBinaries() {
        XCTAssertTrue(GuestProvisioningSupport.terminalVerificationCommand.contains("command -v"))
        XCTAssertTrue(GuestProvisioningSupport.browserVerificationCommand.contains("command -v"))
        XCTAssertFalse(GuestProvisioningSupport.browserVerificationCommand.contains("dpkg-query"))
        XCTAssertFalse(GuestProvisioningSupport.browserVerificationCommand.contains("rpm -q"))
    }

    /// openSUSE's GNOME pattern ships no terminal, so it must ask for one.
    func testOpenSUSEInstallsATerminalExplicitly() throws {
        let iso = try LinuxGuestCatalog.opensuseLeap16ARM64.seedISO(credentials: credentials)
        let text = String(decoding: iso, as: UTF8.self)
        XCTAssertTrue(text.contains("gnome-terminal"))
        XCTAssertTrue(try finalizer(LinuxGuestCatalog.opensuseLeap16ARM64).contains("rpm -q gnome-terminal"))
    }

    // MARK: - Visual Studio Code

    func testVSCodeIsInstalledAndVerifiedWhenSelected() throws {
        for profile in LinuxGuestCatalog.profiles {
            let script = try finalizer(profile)
            XCTAssertTrue(
                script.contains("update.code.visualstudio.com/api/update/linux-arm64/stable/latest"),
                "\(profile.id) does not install VS Code"
            )
            XCTAssertTrue(script.contains("sha256sum --check"), "\(profile.id) does not verify the download")
            XCTAssertTrue(script.contains("command -v code"), "\(profile.id) does not verify VS Code")
        }
    }

    func testVSCodeIsAbsentWhenDeselected() throws {
        let tools = SandboxToolSelection(python: false, nodeJS: false, vsCode: false)
        for profile in LinuxGuestCatalog.profiles {
            let script = try finalizer(profile, tools: tools)
            XCTAssertFalse(
                script.contains("update.code.visualstudio.com"),
                "\(profile.id) installs VS Code even though it was deselected"
            )
            XCTAssertFalse(script.contains("command -v code"))
        }
    }

    /// The reason the tarball is used rather than Microsoft's .deb or .rpm:
    /// those add Microsoft's repository and signing key in their post-install
    /// scripts, giving every sandbox a standing auto-update channel to a third
    /// party. That is easy to reintroduce by "simplifying" the installer.
    func testVSCodeInstallAddsNoMicrosoftRepositoryOrKey() throws {
        for profile in LinuxGuestCatalog.profiles {
            let script = try finalizer(profile)
            for forbidden in [
                "sources.list.d", "packages.microsoft.com", "microsoft.gpg",
                "apt-key", "rpm --import", "zypper ar", "zypper addrepo",
                "dnf5 config-manager", "yum-config-manager", "vscode.repo"
            ] {
                XCTAssertFalse(
                    script.contains(forbidden),
                    "\(profile.id) VS Code install introduces \(forbidden)"
                )
            }
        }
    }

    /// A malformed version or checksum from the vendor must stop the build
    /// rather than install whatever arrived.
    func testVSCodeInstallValidatesWhatTheVendorReturns() {
        let script = GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: true,
            linuxArchiveArchitecture: "arm64"
        )
        XCTAssertTrue(script.contains("invalid version"))
        XCTAssertTrue(script.contains("invalid checksum"))
        XCTAssertTrue(script.contains("-ne 64"), "the checksum length must be checked")
        // Verified by file: VS Code refuses to run normally as root.
        XCTAssertTrue(script.contains("test -x /usr/local/bin/code"))
        XCTAssertTrue(script.contains("resources/app/package.json"))
        // It has to appear in the GNOME overview to be usable in a GUI sandbox.
        XCTAssertTrue(script.contains("code.desktop"))
    }

    /// The launch failure this guards against: Electron's sandbox helper ships
    /// setuid but owned by Microsoft's build user, so the bit does nothing until
    /// it is owned by root. Chromium then needs unprivileged user namespaces,
    /// which Ubuntu 24.04 restricts through AppArmor, and VS Code dies during
    /// launch showing only a spinner.
    func testVSCodeSandboxHelperIsMadeSetuidRoot() {
        let script = GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: true,
            linuxArchiveArchitecture: "arm64"
        )
        XCTAssertTrue(script.contains("chown root:root \"$codeInstall/chrome-sandbox\""))
        XCTAssertTrue(script.contains("chmod 4755 \"$codeInstall/chrome-sandbox\""))
        // Ownership is the part that was actually wrong. The archive already
        // carries the setuid bit, so checking the bit alone passes on the broken
        // layout: setuid, owned by a normal user, refused by Chromium.
        XCTAssertTrue(script.contains("stat -c '%u'"), "the owner must be verified, not just the bit")
        XCTAssertTrue(script.contains("!= \"0\""), "the owner must be root")
        XCTAssertTrue(script.contains("! -u \"$codeInstall/chrome-sandbox\""))
    }

    /// The tempting shortcut for the same failure is --no-sandbox, which
    /// disables Electron's sandbox inside a tool whose purpose is containing
    /// untrusted code. Fix the helper instead.
    func testVSCodeDoesNotDisableItsOwnSandbox() throws {
        for profile in LinuxGuestCatalog.profiles {
            // Comments explain why the flag is not used, so compare commands only.
            let commands = try finalizer(profile)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
            XCTAssertFalse(commands.contains("--no-sandbox"), "\(profile.id) disables Electron's sandbox")
            XCTAssertFalse(commands.contains("--disable-gpu-sandbox"))
        }
    }

    /// The desktop entry has to launch the GUI binary. `bin/code` is the command
    /// line wrapper, which is right for a terminal and wrong for a launcher.
    func testDesktopEntryLaunchesTheGUIBinary() {
        let script = GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: true,
            linuxArchiveArchitecture: "arm64"
        )
        XCTAssertTrue(script.contains("Exec=${codeInstall}/code %F"))
        XCTAssertFalse(script.contains("Exec=/usr/local/bin/code"))
    }

    func testVSCodeCommandsAreEmptyWhenDisabled() {
        XCTAssertTrue(GuestProvisioningSupport.vsCodeInstallCommands(
            enabled: false,
            linuxArchiveArchitecture: "arm64"
        ).isEmpty)
    }

    // MARK: - Tool selection

    /// Tool selections persisted before VS Code existed must still decode, and
    /// must default to installing it rather than silently dropping it.
    func testToolSelectionWithoutVSCodeStillDecodes() throws {
        let legacy: [String: Any] = ["python": true, "nodeJS": true]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacy, format: .xml, options: 0
        )
        let decoded = try PropertyListDecoder().decode(SandboxToolSelection.self, from: data)
        XCTAssertNil(decoded.vsCode)
        XCTAssertTrue(decoded.installsVSCode, "an absent field must mean on, matching the default")
        XCTAssertTrue(decoded.description.contains("Visual Studio Code"))
    }

    func testRecommendedSelectionIncludesVSCode() {
        XCTAssertTrue(SandboxToolSelection.recommended.installsVSCode)
        XCTAssertEqual(SandboxToolSelection.recommended.vsCode, true)
    }

    /// Debian's cloud image runs systemd-networkd beside NetworkManager, and its
    /// wait-online blocked network-online.target for a full 120 seconds on an
    /// offline instance, delaying the greeter by over two minutes. Ubuntu has
    /// always masked these; Debian must too.
    func testProfilesRunningSystemdNetworkdMaskItsWaitOnline() throws {
        for profile in [LinuxGuestCatalog.ubuntu2404ARM64, LinuxGuestCatalog.debian13ARM64] {
            let script = try finalizer(profile)
            XCTAssertTrue(
                script.contains("systemctl mask systemd-networkd-wait-online.service"),
                "\(profile.id) leaves systemd-networkd-wait-online blocking boot"
            )
            XCTAssertTrue(
                script.contains("systemctl mask NetworkManager-wait-online.service"),
                "\(profile.id) leaves NetworkManager-wait-online blocking boot"
            )
        }
    }

    /// These four revisions are what force the rebuild that ships the terminal
    /// and the editor. Getting one wrong silently reuses an old baseline.
    func testProfileRevisionsWereBumpedForTheseGuestChanges() {
        XCTAssertEqual(LinuxGuestCatalog.ubuntu2404ARM64.revision, 4)
        XCTAssertEqual(LinuxGuestCatalog.fedora44ARM64.revision, 4)
        XCTAssertEqual(LinuxGuestCatalog.debian13ARM64.revision, 7)
        XCTAssertEqual(LinuxGuestCatalog.opensuseLeap16ARM64.revision, 6)
    }
}
