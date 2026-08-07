# Sandfort security review — Codex

- **Model:** OpenAI 5.6 sol, extra-high reasoning
- **Reviewed commit:** `2f0707b`
- **Scope:** `DiskUtilities.swift`, `ISO9660Writer.swift`, and
  `SandfortWorkflow.swift`, with only directly relevant provider, model, UI-call,
  and test code followed from those files

## Findings

### 1. Medium — isolation-repair failures are discarded before Resume

**Location:** `sources/sandfortapp/SandfortWorkflow.swift:130-154`, especially
the two `try? provider.repairBundle` calls at lines 141 and 147. The reachable
launch is `resumeInstance` at lines 480-490.

**Concrete failure scenario:** The security model expressly anticipates that a
user can enable clipboard sharing, a host directory, automatic USB sharing, a
port forward, or extra QEMU arguments through UTM's settings. Assume one of
those settings has drifted. On the next state read, `repairBundle` reads the
drifted configuration but cannot atomically write the repaired plist because of
a filesystem error (for example, the bundle directory is temporarily
unwritable or the volume returns a write error). `repairBundle` throws. Both
calls in `currentState()` discard that error and still return the decoded state.
When the user chooses **Resume**, `resumeInstance()` calls `currentState()`,
accepts that returned state, and opens and starts the same bundle. The untrusted
guest therefore runs with the drifted sharing or host-access setting that
Sandfort claims to reassert on every state read. The UI receives no indication
that enforcement failed.

This is different from Resume deliberately preserving contamination and the
last explicit network mode. Clipboard, directory, USB, port-forward, and extra
QEMU-argument restrictions are unconditional guarantees in every mode.

**Severity:** Medium. The outcome crosses an explicit guest-to-host boundary:
untrusted guest code can receive clipboard, selected host-directory, or USB
access, depending on the drifted setting. It is not High because the guest
cannot cause the repair failure from the default isolated configuration; a host
configuration drift and a host-side write failure must coincide.

**Reachability:** Yes. `SandfortViewModel.resumeSelectedInstance()` calls
`resumeInstance()` directly. That method performs no independent repair or
validation after the nonthrowing `currentState()` call. UTM's settings UI is the
documented source of configuration drift, and ordinary filesystem errors can
make the repair throw. Rebuild, Reset & Run Clean, and setup reopening have
later throwing operations that stop on failure; Resume is the direct fail-open
path.

**Failing test:** Add the following workflow-level negative case. It uses the
same injected-provider and temporary-state style as
`RunningVirtualMachineScopeTests`. No production patch is implied by the test;
the required behavior is simply that state whose isolation could not be
repaired must not remain launchable.

```swift
private struct RepairFailureProvider: VirtualMachineProvider {
    var identifier: String { "test.repair-failure" }

    func createSetupBundle(
        at: URL, name: String, from: URL, profile: LinuxGuestProfile,
        credentials: SandboxCredentials, tools: SandboxToolSelection
    ) throws {}

    func createCleanBundle(
        from: URL, at: URL, name: String, profile: LinuxGuestProfile,
        networkMode: SandboxNetworkMode
    ) throws {}

    func resetCleanBundle(
        from: URL, at: URL, profile: LinuxGuestProfile,
        networkMode: SandboxNetworkMode
    ) throws {}

    func setDisplayName(_ name: String, at: URL) throws {}

    func repairBundle(
        at: URL, profile: LinuxGuestProfile, role: VirtualMachineRole
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func ensureBundleNotRunning(at: URL) throws {}
}

func testCurrentStateFailsClosedWhenIsolationRepairFails() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let profile = LinuxGuestCatalog.defaultProfile
    let prefix = "Sandfort — \(profile.displayName)"
    let vms = root.appendingPathComponent("Virtual Machines", isDirectory: true)
    let baseline = vms.appendingPathComponent("Baseline.utm", isDirectory: true)
    let instance = vms.appendingPathComponent("Instance1.utm", isDirectory: true)
    try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)

    var state = SandboxState(
        stage: .ready,
        credentials: profile.credentials(),
        tools: .recommended,
        setupBundlePath: baseline.path,
        sandboxBundlePath: nil,
        setupVMName: "\(prefix) — Protected Baseline TEST",
        sandboxVMName: nil,
        guestProfileID: profile.id,
        guestProfileRevision: profile.revision,
        guestImageSHA256: profile.image.sha256
    )
    state.replaceInstances([
        SandboxInstance(
            number: 1,
            bundlePath: instance.path,
            vmName: "\(prefix) — Instance 1 — TEST"
        )
    ])
    try PropertyListEncoder().encode(state).write(
        to: root.appendingPathComponent("state.plist"),
        options: .atomic
    )

    let workflow = SandfortWorkflow(
        environment: .productionWorkspace(
            profile: profile,
            rootURL: root,
            cacheURL: root.appendingPathComponent("Cache", isDirectory: true)
        ),
        provider: RepairFailureProvider(),
        deleteUTMRegistration: { _ in }
    )

    let loaded = await workflow.currentState()
    XCTAssertNil(
        loaded,
        "a bundle whose isolation repair failed must not remain launchable"
    )
}
```

Against the reviewed code this test fails: `loaded` is non-`nil`, because both
repair errors are swallowed. I did not add the test file to the worktree because
the review brief permits creation of only this report.

This is a host-side fix and would not require users to rebuild guest baselines.

## Scope areas with no finding

### `DiskUtilities.swift`

No actionable finding survived the reachability gate. The QCOW2 arithmetic has
generic trap cases for arbitrary direct callers: `sizeGiB * 1 GiB`, ceiling
addition, `l1Offset + oldL1Size * 8`, and the corresponding validation ceiling
addition are not overflow-checked, and the L1 offset is not checked against file
length before a write. In the app's flows, however, the requested size is a
small constant from a bundled profile and the QCOW2 bytes are resized only after
matching that profile's pinned SHA-256. A network attacker cannot select these
header values. A hostile local process that wins the cache-replacement window
already has the stronger capability documented in issue #18, so turning that
capability into an app crash is not a distinct security finding.

### `ISO9660Writer.swift`

No actionable finding. As a generic internal API it assumes that Rock Ridge
names and directory records fit in `UInt8`, that counts fit ISO 9660's integer
fields, and that the root directory fits one sector. Every app call supplies
exactly two fixed short names (`user-data` and `meta-data`); the only large
user-controlled contribution is base64-encoded custom-script content capped at
64 KiB. Those inputs keep the directory and all conversions within their
bounds. I found no password or script bytes used as an offset, length, filename,
or structural ISO field.

### Remaining `SandfortWorkflow.swift` scope

I did not repeat issue #18's known verified-image TOCTOU. Instance labels affect
only UTM display names; bundle paths retain the permanent instance number and
tag. Deletion uses stored exact names through native Apple Event descriptors,
not shell interpolation. Failures during multi-VM unregistration or filesystem
deletion can leave recoverable partial operational state, but I found no case in
which those failures continue to delete a different environment or start a VM
under a relaxed policy.

## Not examined closely

I did not closely review the handwritten OpenPGP verifier, bundled signing-key
material, cloud-init/provisioning bodies, or the full UTM plist construction;
those are outside this reviewer-specific brief. I followed `repairBundle`, the
provider boundary, persisted state model, Resume UI call, and relevant tests only
as needed to validate the workflow finding. I did not inspect the SwiftUI layer
beyond that call path, perform a live UTM boot, or re-audit the already-fixed
#17, #19, and #20 findings.
