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

/// Materials attach to **one instance** and take effect on its next launch.
///
/// `AGENTS.md` warns that the development-tools sheet already risks reading as
/// "applies now" when it means "applies to the next baseline". A materials
/// control that was offered with no instance to attach to, or that silently
/// targeted whichever instance was selected last, would repeat that mistake with
/// the user's own files.
@MainActor
final class MaterialsGatingTests: XCTestCase {
    private func model(instances: [SandboxInstance], stage: SandboxState.Stage?) -> SandfortViewModel {
        let model = SandfortViewModel()
        model.instances = instances
        model.stage = stage
        return model
    }

    private func instance(_ number: Int, materials: String? = nil) -> SandboxInstance {
        var instance = SandboxInstance(
            number: number,
            bundlePath: "/tmp/Instance\(number).utm",
            vmName: "Sandfort — Instance \(number)",
            label: nil
        )
        instance.materialsDisplayName = materials
        instance.materialsByteCount = materials == nil ? nil : 1024
        instance.materialsPackedAt = materials == nil ? nil : Date()
        return instance
    }

    func testMaterialsNeedAnInstanceToAttachTo() {
        let none = model(instances: [], stage: .ready)
        XCTAssertFalse(
            none.canChooseMaterials,
            "with no instance there is nothing for materials to belong to"
        )

        let ready = model(instances: [instance(1)], stage: .ready)
        ready.selectedInstanceNumber = 1
        XCTAssertTrue(ready.canChooseMaterials)
    }

    /// A baseline being provisioned has no instances yet, and materials are not a
    /// baseline concern in any case.
    func testMaterialsAreNotOfferedBeforeTheBaselineIsReady() {
        for stage in [SandboxState.Stage.provisioning, nil] as [SandboxState.Stage?] {
            let model = self.model(instances: [instance(1)], stage: stage)
            model.selectedInstanceNumber = 1
            XCTAssertFalse(
                model.canChooseMaterials,
                "stage \(String(describing: stage)) must not offer materials"
            )
        }
    }

    /// Attaching rewrites a bundle's configuration, so it must not start while
    /// another operation is already touching that bundle.
    func testMaterialsAreNotOfferedWhileSomethingElseIsRunning() {
        let model = self.model(instances: [instance(1)], stage: .ready)
        model.selectedInstanceNumber = 1
        model.isRunning = true
        XCTAssertFalse(model.canChooseMaterials)
    }

    /// Opening from a row must target *that* row.
    ///
    /// The control used to live in the environment's actions menu and act on
    /// whichever instance was selected last. With two instances on screen it
    /// named neither, so there was no way to tell which sandbox held which file
    /// — reported as materials appearing to vanish when a second instance was
    /// created, when in fact nothing had been deleted at all.
    func testOpeningFromAnInstanceTargetsThatInstance() {
        let model = self.model(
            instances: [instance(1, materials: "one.zip"), instance(2), instance(3, materials: "three.zip")],
            stage: .ready
        )
        model.selectedInstanceNumber = 1

        model.openMaterials(forInstance: 3)

        XCTAssertTrue(model.showMaterials)
        XCTAssertEqual(
            model.selectedInstance?.number, 3,
            "the sheet must describe the instance whose menu was used"
        )
        XCTAssertEqual(model.selectedInstance?.materialsDisplayName, "three.zip")
    }

    /// An instance with none is still a valid target — that is how materials get
    /// attached in the first place.
    func testOpeningFromAnInstanceWithoutMaterialsStillTargetsIt() {
        let model = self.model(
            instances: [instance(1, materials: "one.zip"), instance(2)],
            stage: .ready
        )

        model.openMaterials(forInstance: 2)

        XCTAssertEqual(model.selectedInstance?.number, 2)
        XCTAssertFalse(model.selectedInstance?.hasMaterials == true)
        XCTAssertTrue(model.canChooseMaterials)
    }

    /// The sheet describes the selected instance, and it has to follow the
    /// selection rather than remember the first one it saw.
    func testTheSheetDescribesWhicheverInstanceIsSelected() {
        let model = self.model(
            instances: [instance(1, materials: "one.zip"), instance(2), instance(3, materials: "three.zip")],
            stage: .ready
        )

        model.selectedInstanceNumber = 3
        XCTAssertEqual(model.selectedInstance?.materialsDisplayName, "three.zip")
        XCTAssertTrue(model.selectedInstance?.hasMaterials == true)

        model.selectedInstanceNumber = 2
        XCTAssertNil(model.selectedInstance?.materialsDisplayName)
        XCTAssertFalse(model.selectedInstance?.hasMaterials == true,
                       "instance 2 has none, and must not inherit instance 3's")

        model.selectedInstanceNumber = 99
        XCTAssertNil(model.selectedInstance, "a selection that names no instance describes nothing")
        XCTAssertFalse(model.canChooseMaterials)
    }
}
