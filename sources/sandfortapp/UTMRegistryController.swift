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

import AppKit
import Foundation

/// Removes app-owned VM registrations from UTM without invoking AppleScript,
/// osascript, UI scripting, or a command-line helper.
enum UTMRegistryController {
    private static let bundleIdentifier = UTMLauncher.bundleIdentifier
    private static let virtualMachineClass = fourCharacterCode("UTMv")
    /// Configuration commands sit in their own suite: `UTMcReLd`, `UTMcUpDt`.
    private static let configurationClass = fourCharacterCode("UTMc")
    /// `errAEEventNotHandled`. UTM 4.7.5 has no `reload configuration` command —
    /// it arrived in 5.0.4 — so this is the expected answer there, not a fault.
    static let commandNotUnderstoodStatus = -1708
    private static let applicationNotRunningStatus = -600
    /// `errAEEventNotPermitted`. macOS returns this when the user has refused
    /// Sandfort permission to control UTM, which is a refusal rather than a
    /// failure: callers fall back instead of reporting an error.
    private static let automationNotPermittedStatus = -1743

    static func deleteVirtualMachine(named name: String) async throws {
        try await launchUTMIfNeeded()
        try await sendDeleteRequestWhenReady(named: name)

        // UTM can reply before its open library finishes removing the bundle.
        // Do not let the workflow delete the parent directory out from under
        // that asynchronous operation, or UTM can retain a stale registration.
        for attempt in 0..<60 {
            if try !isVirtualMachineRegistered(named: name) {
                return
            }
            if attempt == 29 {
                try sendDeleteRequest(named: name)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw UTMRegistryError.deletionTimedOut(name: name)
    }

    /// Resolves UTM through `UTMLauncher` rather than repeating a path list.
    /// This used to hardcode /Applications and ~/Applications, so a UTM
    /// installed anywhere else could not be cold-started here even though the
    /// rest of the app had already found it.
    @MainActor
    private static func launchUTMIfNeeded() throws {
        // With a pin, "already running" must mean the pinned copy. Another UTM
        // being open is not a substitute and would leave every later event
        // unaddressable.
        if UTMLauncher.activePinnedApplicationURL != nil {
            if UTMLauncher.pinnedProcessIdentifier() != nil { return }
        } else if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }) {
            return
        }
        guard let installation = UTMLauncher.installation else {
            throw SandboxError.utmNotInstalled
        }
        guard NSWorkspace.shared.open(installation.applicationURL) else {
            throw UTMRegistryError.launchFailed
        }
    }

    private static func sendDeleteRequestWhenReady(named name: String) async throws {
        for attempt in 0..<40 {
            do {
                try sendDeleteRequest(named: name)
                return
            } catch let error as NSError where isApplicationNotRunning(error) {
                guard attempt < 39 else { throw UTMRegistryError.launchTimedOut }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Which application the next Apple Event is addressed to.
    ///
    /// Normally the bundle identifier, which reaches whichever UTM is running.
    /// When a UTM is pinned in Settings, the event is addressed to **that
    /// process** instead: addressing by identifier with two copies installed
    /// would send `start`, `stop` and `reload configuration` to whichever
    /// happened to be open, while the app reported the pinned version. A pin
    /// that did not cover this would make a version test meaningless.
    ///
    /// A pin whose copy is not running is an error rather than a fallback.
    /// Falling back to the identifier is exactly the case this exists to
    /// prevent, and it would be invisible — the command would succeed against
    /// the wrong UTM.
    private static func targetApplication() throws -> NSAppleEventDescriptor {
        // Only a pin that resolved redirects the event. A pin naming an
        // application that has moved, or that is not UTM, falls back to the
        // ordinary target — the same copy `resolveInstallation` reports and the
        // user is told about in Check My Mac.
        guard UTMLauncher.activePinnedApplicationURL != nil else {
            return NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        }
        guard let pid = UTMLauncher.pinnedProcessIdentifier() else {
            throw UTMRegistryError.pinnedUTMNotRunning(
                path: UTMLauncher.activePinnedApplicationURL?.path ?? "the pinned UTM"
            )
        }
        return NSAppleEventDescriptor(processIdentifier: pid)
    }

    static func isApplicationNotRunning(_ error: NSError) -> Bool {
        error.domain == NSOSStatusErrorDomain && error.code == applicationNotRunningStatus
    }

    /// The user has refused Sandfort permission to control UTM. Callers must
    /// treat this as "cannot ask UTM anything" and carry on without it, never
    /// as a failed operation: no app feature may depend on a permission the
    /// user is free to decline.
    static func isAutomationDenied(_ error: NSError) -> Bool {
        error.domain == NSOSStatusErrorDomain && error.code == automationNotPermittedStatus
    }

    /// Asks UTM to start the VM registered under this exact name.
    ///
    /// The `utm://start?name=` URL is a no-op: verified by opening it against a
    /// registered, stopped VM on UTM 4.7.5, which stayed stopped. UTM's macOS
    /// URL handler implements only `downloadVM` and file import — there is no
    /// `start` case in its source at 4.7.5 or 5.0.4 — so this is not a bug that
    /// might be fixed. UTM's scripting interface exposes a real `start` command
    /// (`UTMvstar`), which does work, so the app uses that.
    ///
    /// See docs/utm-version-audit.md for which UTM versions this was checked
    /// against and how to re-check it.
    static func startVirtualMachine(named name: String) throws {
        let target = try targetApplication()
        let event = NSAppleEventDescriptor(
            eventClass: virtualMachineClass,
            eventID: fourCharacterCode("star"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(objectSpecifier(named: name), forKeyword: AEKeyword(keyDirectObject))

        let reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
        let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard errorNumber == 0 else {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "UTM returned Apple Event error \(errorNumber)."
            throw UTMRegistryError.startFailed(name: name, reason: message)
        }
    }

    /// Asks UTM to re-read a stopped machine's configuration from its bundle.
    ///
    /// UTM keeps its own copy of a configuration, so a drive Sandfort attaches
    /// while UTM is running is not in the copy UTM launches from — the instance
    /// resumes with no disc, silently. UTM 5.0.4 added a command for exactly
    /// this case: *"Useful when the .utm bundle has been modified externally
    /// (e.g. by an automation tool) and UTM's cached configuration needs to be
    /// refreshed. The VM must be in the stopped state."*
    ///
    /// **This is not `delete`.** That command is documented as "All data will be
    /// deleted, there is no confirmation!" and destroyed a user's instance when
    /// it was used as a cache-buster. This one only re-reads.
    ///
    /// It is an optimisation and never a requirement: the command does not exist
    /// before 5.0.4, and 4.7.5 is still what `releases/latest` gives people.
    /// There it answers `errAEEventNotHandled` and the caller falls back to
    /// telling the user to quit UTM. Checked against each tag's `UTM.sdef`:
    /// absent in 4.7.5 and 5.0.0–5.0.3, present in 5.0.4.
    static func reloadConfiguration(named name: String) throws {
        let target = try targetApplication()
        let event = NSAppleEventDescriptor(
            eventClass: configurationClass,
            eventID: fourCharacterCode("ReLd"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(objectSpecifier(named: name), forKeyword: AEKeyword(keyDirectObject))

        let reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
        let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard errorNumber == 0 else {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "UTM returned Apple Event error \(errorNumber)."
            throw UTMRegistryError.reloadFailed(name: name, reason: message)
        }
    }

    /// Asks the guest to power itself down, then waits for UTM to report the VM
    /// stopped.
    ///
    /// Deliberately the polite `request` method, never `force` or `kill`. This
    /// runs against the baseline setup VM as well as disposable instances, and
    /// pulling the power on a guest mid-provision is a good way to produce a
    /// corrupt baseline that looks fine until it is used. A guest that ignores
    /// the request is reported, not escalated.
    static func stopVirtualMachine(named name: String) throws {
        let target = try targetApplication()
        let event = NSAppleEventDescriptor(
            eventClass: virtualMachineClass,
            eventID: fourCharacterCode("stop"),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(objectSpecifier(named: name), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(
            NSAppleEventDescriptor(enumCode: fourCharacterCode("ReQu")),
            forKeyword: fourCharacterCode("StBy")
        )

        let reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
        let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard errorNumber == 0 else {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "UTM returned Apple Event error \(errorNumber)."
            throw UTMRegistryError.stopFailed(name: name, reason: message)
        }
    }

    private static func sendDeleteRequest(named name: String) throws {
        let target = try targetApplication()
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEDelete),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(objectSpecifier(named: name), forKeyword: AEKeyword(keyDirectObject))

        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: 30)
        } catch let error as NSError
            where error.domain == NSOSStatusErrorDomain && error.code == Int(errAENoSuchObject) {
            return
        }
        let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard errorNumber == 0 || errorNumber == errAENoSuchObject else {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "UTM returned Apple Event error \(errorNumber)."
            throw UTMRegistryError.deleteFailed(name: name, reason: message)
        }
    }

    /// Whether UTM's library currently holds a VM with this exact name. Used
    /// both to confirm a deletion completed and, before starting a VM, to wait
    /// until UTM has finished importing a freshly written bundle.
    static func isVirtualMachineRegistered(named name: String) throws -> Bool {
        let target = try targetApplication()
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEGetData),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(objectSpecifier(named: name), forKeyword: AEKeyword(keyDirectObject))

        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
        } catch let error as NSError
            where error.domain == NSOSStatusErrorDomain && error.code == Int(errAENoSuchObject) {
            return false
        }
        let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        if errorNumber == errAENoSuchObject {
            return false
        }
        guard errorNumber == 0 else {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                ?? "UTM returned Apple Event error \(errorNumber)."
            throw UTMRegistryError.deleteFailed(name: name, reason: message)
        }
        return true
    }

    static func objectSpecifier(named name: String) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(
            NSAppleEventDescriptor(typeCode: virtualMachineClass),
            forKeyword: AEKeyword(keyAEDesiredClass)
        )
        record.setDescriptor(
            NSAppleEventDescriptor(enumCode: OSType(formName)),
            forKeyword: AEKeyword(keyAEKeyForm)
        )
        record.setDescriptor(
            NSAppleEventDescriptor(string: name),
            forKeyword: AEKeyword(keyAEKeyData)
        )
        record.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }

    private static func fourCharacterCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}

enum UTMRegistryError: LocalizedError {
    case deleteFailed(name: String, reason: String)
    case deletionTimedOut(name: String)
    case launchFailed
    case launchTimedOut
    case startFailed(name: String, reason: String)
    case stopFailed(name: String, reason: String)
    case stopIgnored(name: String)
    case reloadFailed(name: String, reason: String)
    case pinnedUTMNotRunning(path: String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(name, reason):
            return "UTM could not start “\(name)”: \(reason). Start it with UTM's play button."
        case let .stopFailed(name, reason):
            return "UTM could not stop “\(name)”: \(reason)"
        case let .stopIgnored(name):
            return "The guest in “\(name)” did not shut down when asked. It may be showing a "
                + "confirmation dialog. Finish shutting it down in the VM, or stop it from UTM."
        case let .pinnedUTMNotRunning(path):
            return "The UTM pinned in Settings is not running: \(path). Open that copy of UTM, "
                + "or clear the pin in Settings → Advanced."
        case let .reloadFailed(name, reason):
            // Never surfaced as a failed operation: the caller treats this as
            // "UTM could not be asked" and tells the user to quit UTM instead.
            // UTM 4.7.5 has no such command and always lands here.
            return "UTM could not re-read “\(name)”: \(reason)"
        case let .deleteFailed(name, reason):
            return "UTM could not remove “\(name)” from its library: \(reason)"
        case let .deletionTimedOut(name):
            return "UTM did not finish removing “\(name)” from its open library. Close UTM and try Rebuild again."
        case .launchFailed:
            return "Sandfort could not open UTM to remove the old virtual machines. Open UTM, then try Rebuild again."
        case .launchTimedOut:
            return "UTM opened, but its automation interface did not become ready. Wait for UTM to finish opening, then try Rebuild again."
        }
    }
}
