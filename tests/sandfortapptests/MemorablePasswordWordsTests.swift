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

import XCTest
@testable import SandfortApp

/// The word list is an entropy claim published in `docs/password-strength.md`.
/// These tests exist so editing the list cannot silently weaken the generated
/// password or make it unusable at a VM console.
final class MemorablePasswordWordsTests: XCTestCase {
    /// 2,048 is exactly 2^11, so four distinct words give 44.00 bits. Changing
    /// the count changes the documented strength.
    func testWordListHasExactlyTwoThousandFortyEightUniqueWords() {
        XCTAssertEqual(MemorablePasswordWords.all.count, 2048)
        XCTAssertEqual(Set(MemorablePasswordWords.all).count, 2048)
    }

    /// The password is typed by hand at a VM console: Sandfort deliberately
    /// disables clipboard sharing, so there is no paste.
    func testEveryWordIsLowercaseAsciiAndEasyToType() {
        for word in MemorablePasswordWords.all {
            XCTAssertNotNil(
                word.range(of: "^[a-z]{3,8}$", options: .regularExpression),
                "\(word) must be 3-8 lowercase ASCII letters"
            )
        }
    }

    func testWordListIsSortedSoReviewersSeeAStableDiff() {
        XCTAssertEqual(MemorablePasswordWords.all, MemorablePasswordWords.all.sorted())
    }

    /// A hyphen separates words, so no word may contain one and create an
    /// ambiguous phrase.
    func testNoWordContainsTheSeparator() {
        XCTAssertFalse(MemorablePasswordWords.all.contains { $0.contains("-") })
    }

    /// Spot-check that known homophone pairs were not both admitted. A spoken
    /// or remembered phrase should not be ambiguous.
    func testKnownHomophonePairsAreNotBothPresent() {
        let words = Set(MemorablePasswordWords.all)
        let pairs = [
            ("flower", "flour"), ("steel", "steal"), ("brake", "break"),
            ("plain", "plane"), ("pear", "pair"), ("mail", "male"),
            ("sail", "sale"), ("tail", "tale"), ("bear", "bare"),
            ("chord", "cord"), ("knight", "night"), ("mussel", "muscle"),
            ("cereal", "serial"), ("sole", "soul"), ("thyme", "time")
        ]
        for (first, second) in pairs {
            XCTAssertFalse(
                words.contains(first) && words.contains(second),
                "\(first)/\(second) are homophones; only one may be in the list"
            )
        }
    }

    /// The documented figure is 44.00 bits. This asserts the arithmetic behind
    /// the claim rather than restating the constant.
    func testGeneratedPasswordSpaceMeetsTheDocumentedEntropy() {
        let n = Double(MemorablePasswordWords.all.count)
        let space = n * (n - 1) * (n - 2) * (n - 3)
        XCTAssertEqual(log2(space), 44.0, accuracy: 0.01)
    }

    func testGeneratedPasswordIsFourDistinctWordsFromTheList() {
        let words = Set(MemorablePasswordWords.all)
        for _ in 0..<200 {
            let parts = GuestProvisioningSupport.credentials().password.components(separatedBy: "-")
            XCTAssertEqual(parts.count, 4)
            XCTAssertEqual(Set(parts).count, 4, "words within one phrase must be distinct")
            for part in parts { XCTAssertTrue(words.contains(part), "\(part) is not in the list") }
        }
    }

    /// A weak or seeded generator would show up as repeats across a small
    /// sample long before the birthday bound predicts one.
    func testRepeatedGenerationDoesNotProduceObviousRepeats() {
        let generated = (0..<500).map { _ in GuestProvisioningSupport.credentials().password }
        XCTAssertEqual(Set(generated).count, generated.count)
        // A shuffle that favored part of the list would concentrate first words.
        let firstWords = Set(generated.map { $0.components(separatedBy: "-")[0] })
        XCTAssertGreaterThan(firstWords.count, 400, "first-word distribution looks skewed")
    }
}
