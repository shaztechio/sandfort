// Copyright 2026 Sandfort contributors
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
        if NSWorkspace.shared.runningApplications.contains(where: {
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
    /// UTM's documented `utm://start?name=` URL is a no-op on UTM 4.7.5:
    /// verified by opening it against a registered, stopped VM, which stayed
    /// stopped. UTM's scripting interface exposes a real `start` command
    /// (`UTMvstar`), which does work, so the app uses that.
    static func startVirtualMachine(named name: String) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
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

    private static func sendDeleteRequest(named name: String) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
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
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
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

    var errorDescription: String? {
        switch self {
        case let .startFailed(name, reason):
            return "UTM could not start “\(name)”: \(reason). Start it with UTM's play button."
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
