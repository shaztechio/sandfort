import AppKit
import Foundation

/// Removes app-owned VM registrations from UTM without invoking AppleScript,
/// osascript, UI scripting, or a command-line helper.
enum UTMRegistryController {
    private static let bundleIdentifier = "com.utmapp.UTM"
    private static let virtualMachineClass = fourCharacterCode("UTMv")

    static func deleteVirtualMachine(named name: String) async throws {
        try sendDeleteRequest(named: name)

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

    private static func isVirtualMachineRegistered(named name: String) throws -> Bool {
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

    var errorDescription: String? {
        switch self {
        case let .deleteFailed(name, reason):
            return "UTM could not remove “\(name)” from its library: \(reason)"
        case let .deletionTimedOut(name):
            return "UTM did not finish removing “\(name)” from its open library. Close UTM and try Rebuild again."
        }
    }
}
