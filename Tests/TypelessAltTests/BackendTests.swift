import XCTest
@testable import TypelessAlt

final class BackendTests: XCTestCase {
    func testExistingSettingsGainBackendDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["sounds": false, "keyCode": 4], format: .xml, options: 0)
        try data.write(to: url)
        let settings = try Settings.load(from: url)
        XCTAssertEqual(settings.backend, "openai")
        XCTAssertEqual(settings.groqModel, "whisper-large-v3")
        XCTAssertEqual(settings.keyCode, 4)
        XCTAssertFalse(settings.sounds)
    }
    func testInvalidBackendIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.plist")
        try PropertyListSerialization.data(fromPropertyList: ["backend": "typo"], format: .xml, options: 0).write(to: url)
        XCTAssertThrowsError(try Settings.load(from: url))
    }
    func testCloudflareRESTAndWorkerShapes() throws {
        XCTAssertEqual(try DictationBackend.decodePolish(Data(#"{"success":true,"result":{"response":"你好，hello"}}"#.utf8)), "你好，hello")
        XCTAssertEqual(try DictationBackend.decodePolish(Data(#"{"response":"Hello"}"#.utf8)), "Hello")
        XCTAssertEqual(try DictationBackend.decodePolish(Data(#"{"success":true,"result":{"choices":[{"message":{"content":"Hello"},"finish_reason":"stop"}]}}"#.utf8)), "Hello")
        XCTAssertEqual(try DictationBackend.decodePolish(Data(#"{"response":"<think>reasoning</think>你好"}"#.utf8)), "你好")
        for json in [#"{"success":false,"result":{"response":"bad"}}"#, #"{"response":""}"#, #"{"response":"<think>unfinished reasoning"}"#] {
            XCTAssertThrowsError(try DictationBackend.decodePolish(Data(json.utf8)))
        }
    }
    func testToneAndLanguages() {
        let mail = OpenAI.messages("聽日 send email", bundleID: "com.apple.mail")
        XCTAssertTrue(mail[0]["content"]!.contains("professional email"))
        XCTAssertTrue(mail[0]["content"]!.contains("Traditional Chinese"))
        XCTAssertEqual(mail[1]["content"], "聽日 send email")
        XCTAssertTrue(OpenAI.messages("Hi", bundleID: "com.apple.MobileSMS")[0]["content"]!.contains("conversational"))
    }
}
