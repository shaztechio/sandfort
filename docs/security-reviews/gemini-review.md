# Sandfort Security Review

This review prioritizes the isolation guarantees defined in `docs/security-model.md` and the specification-conformance of `OpenPGPSignatureVerifier.swift`, adhering strictly to the constraints and priorities outlined in the security review brief.

## Findings

### 1. `repairBundle` omits assertions for `Sharing` and `Input` dictionaries

- **Location**: `sources/sandfortapp/UTMBundleBuilder.swift:88` (inside `repairBundle`)
- **Concrete failure scenario**: If an instance's `config.plist` is modified to enable `ClipboardSharing`, `DirectoryShareMode`, or `UsbSharing` (for example, by a user tweaking settings in UTM or an external process modifying the plist), Sandfort does not revert these changes. When Sandfort launches or evaluates state, `SandfortWorkflow.currentState()` calls `repairBundle()` to assert the app's policy. While it properly resets `Network.IsolateFromHost`, `PortForward`, and `QEMU.AdditionalArguments`, it completely ignores the `Sharing` and `Input` dictionaries. When the instance is later resumed, it will run with full clipboard, host directory, and USB sharing enabled.
- **Severity**: High. The threat model explicitly guarantees "No port forwards, host directory sharing, synchronized clipboard, or automatic USB sharing." Missing these keys in the repair flow silently enables them without anything appearing broken in the UI.
- **Reachability**: Reachable anytime the app reads its state via `currentState()`, which occurs on app launch and before standard VM operations like `resumeInstance`.
- **Failing test**:
  ```swift
  func testRepairBundleEnforcesSharingAndInputIsolation() throws {
      let builder = UTMBundleBuilder()
      let bundleURL = // ... temp URL ...
      
      // Write an initial configuration that violates the security model
      let plist: [String: Any] = [
          "Sharing": [
              "ClipboardSharing": true,
              "DirectoryShareMode": "WebDAV",
              "DirectoryShareReadOnly": false
          ],
          "Input": [
              "MaximumUsbShare": 3,
              "UsbSharing": true
          ]
      ]
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: bundleURL.appendingPathComponent("config.plist"))
      
      try builder.repairBundle(at: bundleURL, profile: LinuxGuestCatalog.defaultProfile)
      
      let repairedData = try Data(contentsOf: bundleURL.appendingPathComponent("config.plist"))
      let repaired = try PropertyListSerialization.propertyList(from: repairedData, format: nil) as! [String: Any]
      
      let sharing = repaired["Sharing"] as? [String: Any]
      XCTAssertEqual(sharing?["ClipboardSharing"] as? Bool, false)
      XCTAssertEqual(sharing?["DirectoryShareMode"] as? String, "None")
      
      let input = repaired["Input"] as? [String: Any]
      XCTAssertEqual(input?["UsbSharing"] as? Bool, false)
  }
  ```

### 2. TOCTOU vulnerability in `verifiedImage` cache consumption

- **Location**: `sources/sandfortapp/SandfortWorkflow.swift:242` and `616` (and `sources/sandfortapp/UTMBundleBuilder.swift:28`)
- **Concrete failure scenario**: In `SandfortWorkflow.create`, the method `verifiedImage` verifies the SHA-256 of the cached distribution image in the user-writable `Application Support` cache directory. After verification succeeds, control returns to `create`, which then calls `provider.createSetupBundle`. Inside `createSetupBundle`, `FileManager.default.copyItem` copies the image from the cache directory into the UTM bundle. A malicious local process can wait for `verifiedImage` to complete and then immediately overwrite the image in the cache directory before `createSetupBundle` copies it. This copies a malicious image into the VM bundle without triggering a checksum failure.
- **Severity**: Medium. Allows local privilege escalation into the VM or persistent contamination of the trusted baseline by swapping the immutable distribution image with a malicious one. The threat model guarantees "verify its pinned SHA-256 before use", but the separation of verification and file consumption creates a Time-of-Check to Time-of-Use window that breaks this guarantee.
- **Reachability**: Reachable during the creation of any new baseline environment that utilizes a downloaded or cached image.
- **Failing test**:
  ```swift
  func testImageVerificationIsAtomicWithBundleCreation() async throws {
      // Mock the provider to observe the state of the disk at the exact moment of creation
      let provider = MockVirtualMachineProvider { bundleURL, name, imageURL, profile, credentials, tools in
          // At this point, the workflow believes the image is verified and is about to copy it.
          // A malicious process replaces the image at `imageURL` (the cache).
          let maliciousPayload = Data(repeating: 0x41, count: 1024)
          try? maliciousPayload.write(to: imageURL)
          
          // Proceed with the actual UTMBundleBuilder logic
          try UTMBundleBuilder().createSetupBundle(at: bundleURL, name: name, from: imageURL, profile: profile, credentials: credentials, tools: tools)
      }
      
      let workflow = SandfortWorkflow(provider: provider)
      // Execute the creation flow which will trigger the mock provider
      let state = try await workflow.create(tools: .none, event: { _ in })
      
      let copiedDiskURL = URL(fileURLWithPath: state.setupBundlePath).appendingPathComponent("Data/sandfort.qcow2")
      let copiedHash = try DiskUtilities.sha256(of: copiedDiskURL)
      
      // The copied hash will match the malicious payload, failing this assertion.
      XCTAssertEqual(copiedHash, LinuxGuestCatalog.defaultProfile.image.sha256, 
          "The disk written to the bundle was modified after its checksum was verified.")
  }
  ```

## Areas explicitly found to be safe

### `OpenPGPSignatureVerifier.swift` Conformance

I conducted a rigorous specification-conformance pass against RFC 4880 for the custom OpenPGP parser. **I found no vulnerabilities that fail open.** 
- **Packet and MPI parsing**: Bounds checks are strictly enforced via `ByteReader`. Length declarations, including partial/indeterminate lengths, are safely validated or rejected. A malformed MPI length (e.g., absurdly large) correctly causes `padded.count <= key.modulus.count` to fail closed. 
- **Signature malleability**: Appending unhashed trailing garbage to the signature packet does not affect the verified payload or the RSA signature MPI, so it has no cryptographic impact. 
- **Fingerprint matching**: `constantTimeEquals` strictly validates string length, ensuring keys match in full and cannot be spoofed via prefix matching.

*(Note: There is a minor parsing anomaly in `splitClearsignedDocument` where it fails to strip the required empty line preceding the signature block. However, this causes the verification of valid clearsigned documents containing that empty line to **fail closed** due to a digest mismatch, meaning it poses no security risk.)*

### Guest Provisioning Quoting

The `GuestProvisioningSupport.swift` password and script embeddings are well-defended against YAML injection:
- `customSetupScript` base64-encodes the entire user-provided script, circumventing all shell and YAML escaping issues.
- `credentials` enforces an explicit character set (`0x21...0x7e`) and utilizes robust single-quote escaping (`''`) that fully complies with YAML 1.2 string literal boundaries.

## Areas not examined closely

- **SwiftUI View Layer**: As requested, the entire view hierarchy (`sources/sandfortapp/ContentView.swift`, etc.) was omitted.
- **UTM Engine/QEMU Surface Area**: I did not review the QEMU binary, its network/block drivers, or the hypervisor boundary. The review assumes the underlying UTM isolation mechanisms work as advertised once the correct arguments are supplied.
- **Cloud-Init Scripts**: I did not deeply audit the specific shell commands within `UbuntuCloudInit.swift` or others, beyond confirming they avoid arbitrary quoting execution.

## Test Environment
- **Model**: Gemini 3.1 Pro (High)
- **Date**: 2026-08-06
- **Context**: Code review via AI Assistant
