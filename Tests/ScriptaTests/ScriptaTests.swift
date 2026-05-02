import XCTest
@testable import Scripta

final class ScriptaTests: XCTestCase {
    func testScriptContentHasHeaders() {
        let content = ScriptExporter.makeScriptFileContent(
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 10),
            transcript: "hello world"
        )
        XCTAssertTrue(content.contains("Scripta Script"))
        XCTAssertTrue(content.contains("Transcript"))
        XCTAssertTrue(content.contains("hello world"))
    }
}
