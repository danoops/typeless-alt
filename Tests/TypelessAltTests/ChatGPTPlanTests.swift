import XCTest
import Security
@testable import TypelessAlt

final class ChatGPTPlanTests: XCTestCase {
    func testPKCEAndFormEncoding() {
        XCTAssertEqual(PlanOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(String(data: PlanOAuth.form(["x": "a+b &/?="]), encoding: .utf8), "x=a%2Bb%20%26%2F%3F%3D")
    }
    func testCallbackBindingAndIssuedClient() throws {
        func callback(_ query: String, previous: String? = nil) throws -> (String, String) {
            try PlanOAuth.callback(URL(string: "http://127.0.0.1:1455/auth/callback?\(query)")!, state: "expected", previousClient: previous)
        }
        XCTAssertEqual(try callback("state=expected&code=abc&client_id=oaiapp_test").0, "oaiapp_test")
        XCTAssertEqual(try callback("state=expected&code=abc", previous: "oaiapp_test").0, "oaiapp_test")
        for query in ["state=wrong&code=abc&client_id=oaiapp_test", "state=expected&error=access_denied", "state=expected&code=abc", "state=expected&code=abc&client_id=dynamic_agent_client", "state=expected&state=expected&code=abc&client_id=oaiapp_test"] {
            XCTAssertThrowsError(try callback(query))
        }
        XCTAssertThrowsError(try callback("state=expected&code=abc&client_id=other", previous: "oaiapp_test"))
    }
    func testRequestAndCompletedStream() throws {
        let payload = ChatGPTPlan.payload("聽日 send email", model: "account-model", bundleID: "com.apple.mail")
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertNil(payload["temperature"])
        XCTAssertNil(payload["messages"])
        XCTAssertTrue((payload["instructions"] as! String).contains("Traditional Chinese"))
        var stream = PlanStream()
        XCTAssertNil(try stream.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}"))
        XCTAssertEqual(try stream.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","content":[{"type":"output_text","text":"hidden"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"你好，hello"}]}]}}"#), "你好，hello")
        for type in ["error", "response.failed", "response.incomplete"] {
            XCTAssertThrowsError(try stream.consume("data: {\"type\":\"\(type)\"}"))
        }
        XCTAssertThrowsError(try stream.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#))
        XCTAssertNil(try stream.consume("data: [DONE]")) // Never accepted as a completed response.
    }
    func testIDTokenSignatureAndClaims() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicData = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Extract RSA modulus/exponent from Security's PKCS#1 DER public key.
        let bytes = [UInt8](publicData); var offset = 0
        func read() -> Data {
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            let start = offset; offset += length
            return Data(bytes[start..<offset])
        }
        offset = bytes[1] & 128 == 0 ? 2 : 2 + Int(bytes[1] & 127)
        var modulus = read(); if modulus.first == 0 { modulus.removeFirst() }
        let exponent = read()
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": PlanOAuth.base64url(modulus), "e": PlanOAuth.base64url(exponent)]]])
        let header = PlanOAuth.base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]))
        let now = Date()
        func token(_ overrides: [String: Any] = [:], wrongSignature: Bool = false) throws -> String {
            let claims: [String: Any] = ["iss": PlanOAuth.issuer, "aud": "issued-client", "sub": "user-123", "email": "fixture@example.invalid", "nonce": "nonce", "exp": now.timeIntervalSince1970 + 300]
            let body = PlanOAuth.base64url(try JSONSerialization.data(withJSONObject: claims.merging(overrides) { _, value in value }))
            let message = "\(header).\(body)"
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
            return "\(message).\(PlanOAuth.base64url(wrongSignature ? Data(repeating: 0, count: signature.count) : signature))"
        }
        func validate(_ value: String) throws -> (String, String) { try PlanOAuth.validateID(value, client: "issued-client", nonce: "nonce", jwks: jwks, now: now) }
        XCTAssertEqual(try validate(token()).0, "user-123")
        XCTAssertThrowsError(try validate(token(wrongSignature: true)))
        for overrides: [String: Any] in [["iss": "https://attacker.invalid"], ["aud": "wrong"], ["nonce": "wrong"], ["exp": now.timeIntervalSince1970 - 1], ["aud": ["issued-client", "other"]], ["sub": ""]] {
            XCTAssertThrowsError(try validate(token(overrides)))
        }
    }
    func testLoopbackCallbackListener() async throws {
        let callback = try PlanCallback()
        let result = try await callback.receive { redirect in
            XCTAssertEqual(redirect.host, "127.0.0.1")
            XCTAssertEqual(redirect.path, "/auth/callback")
            XCTAssertNotNil(redirect.port)
            Task {
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                do { _ = try await session.data(from: URL(string: redirect.absoluteString + "?state=test&code=fixture&client_id=issued")!) }
                catch { XCTFail("Loopback request failed: \(error)") }
            }
        }
        XCTAssertEqual(try PlanOAuth.callback(result, state: "test", previousClient: nil).0, "issued")
    }
    func testPlanSettingsAndInvalidSTT() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["backend": "chatgpt-plan"], format: .xml, options: 0).write(to: url)
        let settings = try Settings.load(from: url)
        XCTAssertEqual(settings.chatgptSTT, "groq"); XCTAssertEqual(settings.chatgptModel, "")
        try PropertyListSerialization.data(fromPropertyList: ["backend": "chatgpt-plan", "chatgptSTT": "siwc"], format: .xml, options: 0).write(to: url)
        XCTAssertThrowsError(try Settings.load(from: url))
    }
}
