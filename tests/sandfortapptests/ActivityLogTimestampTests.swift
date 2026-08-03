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

/// The activity log is what gets pasted into bug reports, so its formatting is
/// worth pinning: the clock correlates it with the guest's own setup log, and
/// the elapsed column is what makes a slow step visible.
@MainActor
final class ActivityLogTimestampTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_754_200_000)

    func testLineCarriesWallClockAndElapsed() {
        let line = SandfortViewModel.timestamped(
            "Verifying SHA-256…",
            at: start.addingTimeInterval(136),
            since: start
        )
        XCTAssertTrue(line.hasSuffix("Verifying SHA-256…"))
        XCTAssertTrue(line.contains("+2:16"), "136 seconds should read as +2:16")
        XCTAssertNotNil(
            line.range(of: "^[0-9]{2}:[0-9]{2}:[0-9]{2} ", options: .regularExpression),
            "the line should begin with a 24-hour clock"
        )
    }

    /// A 12-hour locale would append AM/PM and break the column alignment.
    func testClockIsTwentyFourHourRegardlessOfLocale() {
        let line = SandfortViewModel.timestamped("x", at: start, since: nil)
        XCTAssertFalse(line.contains("AM"))
        XCTAssertFalse(line.contains("PM"))
    }

    /// Several messages are multi-line, including Check My Mac and errors.
    /// Stamping every line would claim each arrived at a different moment.
    func testOnlyTheFirstLineOfAMultiLineMessageIsStamped() {
        let line = SandfortViewModel.timestamped(
            "Check complete\nUTM 4.7.5 is installed at /Applications/UTM.app.\nThis Mac is arm64.",
            at: start,
            since: start
        )
        let lines = line.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        let stamp = "^[0-9]{2}:[0-9]{2}:[0-9]{2}"
        XCTAssertNotNil(lines[0].range(of: stamp, options: .regularExpression))
        for continuation in lines.dropFirst() {
            XCTAssertNil(
                continuation.range(of: stamp, options: .regularExpression),
                "continuation lines must not be stamped"
            )
            XCTAssertTrue(continuation.hasPrefix("  "), "continuation lines must be indented")
        }
    }

    /// Continuation lines line up under the message, not under the clock.
    func testContinuationLinesAlignWithTheMessageColumn() {
        let line = SandfortViewModel.timestamped("first\nsecond", at: start, since: start)
        let lines = line.components(separatedBy: "\n")
        let messageColumn = lines[0].distance(
            from: lines[0].startIndex,
            to: try! XCTUnwrap(lines[0].range(of: "first")).lowerBound
        )
        let indent = lines[1].prefix { $0 == " " }.count
        XCTAssertEqual(indent, messageColumn)
    }

    /// Outside an operation there is nothing to be elapsed from, but the column
    /// still has to hold its width or the message column wanders.
    func testMessagesOutsideAnOperationKeepTheColumnWidth() {
        let during = SandfortViewModel.timestamped("x", at: start, since: start)
        let outside = SandfortViewModel.timestamped("x", at: start, since: nil)
        XCTAssertFalse(outside.contains("+"))
        XCTAssertEqual(
            during.distance(from: during.startIndex, to: during.range(of: "x")!.lowerBound),
            outside.distance(from: outside.startIndex, to: outside.range(of: "x")!.lowerBound)
        )
    }

    /// A long setup runs past an hour; minutes keep counting rather than wrapping.
    func testElapsedKeepsCountingPastAnHour() {
        let line = SandfortViewModel.timestamped(
            "still going",
            at: start.addingTimeInterval(3_723),
            since: start
        )
        XCTAssertTrue(line.contains("+62:03"), "3723 seconds should read as +62:03")
    }

    func testElapsedIsNeverNegativeIfTheClockMovesBackwards() {
        let line = SandfortViewModel.timestamped(
            "x",
            at: start.addingTimeInterval(-30),
            since: start
        )
        XCTAssertTrue(line.contains("+0:00"))
        XCTAssertFalse(line.contains("-"))
    }
}
