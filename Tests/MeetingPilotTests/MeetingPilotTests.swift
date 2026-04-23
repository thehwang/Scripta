import XCTest
@testable import MeetingPilot

final class MeetingPilotTests: XCTestCase {
    func testScriptContentHasHeaders() {
        let content = ScriptExporter.makeScriptFileContent(
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 10),
            transcript: "hello world"
        )
        XCTAssertTrue(content.contains("Meeting Pilot Script"))
        XCTAssertTrue(content.contains("Transcript"))
        XCTAssertTrue(content.contains("hello world"))
    }
}
