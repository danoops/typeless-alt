import AppKit
import CryptoKit
import Network
import Security

// Credentials never leave Keychain. Public registration metadata is retained on sign-out.
enum PlanKeychain {
    static let service = "typeless-alt.siwc"
    static func read() throws -> PlanStore {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "profiles", kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return PlanStore() }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure("Cannot read SIWC Keychain (\(status)).") }
        return try JSONDecoder().decode(PlanStore.self, from: data)
    }
    static func write(_ store: PlanStore) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "profiles"]
        let data = try JSONEncoder().encode(store)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure("Cannot save SIWC credentials in Keychain.") }
        } else if status != errSecSuccess { throw Failure("Cannot update SIWC Keychain (\(status)).") }
    }
}
struct PlanProfile: Codable {
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var label: String { "\(email) · \(clientID.suffix(8))" }
}
struct PlanStore: Codable {
    var hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
    var profiles: [PlanProfile] = []
    var activeID: String?
}
struct PlanToken: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double
    let scope: String?
    let token_type: String
}

// Only a loopback listener is exposed, with a bounded request and a five-minute timeout.
// Mutable callback state is confined to queue.
final class PlanCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "typeless-alt.siwc.callback")
    private var completion: CheckedContinuation<URL, Error>?
    private var timer: DispatchWorkItem?
    private var finished = false
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func receive(open: @escaping (URL) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.completion = continuation
                self.listener.stateUpdateHandler = { state in
                    if case .ready = state, let port = self.listener.port {
                        open(URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                    } else if case .failed = state { self.finish(.failure(Failure("Cannot start SIWC callback listener."))) }
                }
                self.listener.newConnectionHandler = { connection in
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                    self.read(connection, data: Data())
                }
                let timer = DispatchWorkItem { self.finish(.failure(Failure("ChatGPT sign-in timed out. Try again."))) }
                self.timer = timer
                self.queue.asyncAfter(deadline: .now() + 300, execute: timer)
                self.listener.start(queue: self.queue)
            }
        }
    }
    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, done, error in
            var data = data; data.append(chunk ?? Data())
            guard data.count <= 16384 else { connection.cancel(); return }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"), let port = self.listener.port,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(parts[1])") else { connection.cancel(); return }
                let message = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nCache-Control: no-store\r\n\r\nReturn to Typeless Alt to check sign-in. You may close this tab."
                connection.send(content: Data(message.utf8), completion: .contentProcessed { _ in
                    self.queue.async { self.finish(.success(url)) }
                })
            } else if done || error != nil { connection.cancel() }
            else { self.read(connection, data: data) }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }; finished = true
        timer?.cancel(); listener.cancel(); connections.forEach { $0.cancel() }
        completion?.resume(with: result); completion = nil
    }
}

final class PlanNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PlanOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode64(_ text: String) throws -> Data {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)) else { throw Failure("Invalid ID token encoding.") }
        return data
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure("Secure random generation failed.") }
        return base64url(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    static func send(_ url: URL, fields: [String: String]? = nil, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 60
        if let fields { request.httpMethod = "POST"; request.httpBody = form(fields); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: PlanNoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure("ChatGPT HTTP \(code). Check access/usage in ChatGPT Settings; sign in again if authorization expired. No API-key fallback was used.")
        }
        return data
    }
    static func callback(_ url: URL, state: String, previousClient: String?) throws -> (String, String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw Failure("Duplicate OAuth callback parameters.") }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw Failure("ChatGPT callback state mismatch.") }
        guard values["error"] == nil else { throw Failure("ChatGPT authorization declined. No credentials changed.") }
        let client = values["client_id"] ?? previousClient ?? ""
        guard !client.isEmpty, client != "dynamic_agent_client", previousClient == nil || client == previousClient,
              let code = values["code"], !code.isEmpty else { throw Failure("Incomplete or mismatched ChatGPT registration.") }
        return (client, code)
    }
    // RS256, pinned issuer/JWKS endpoint; no token-selected key URLs or algorithms.
    static func validateID(_ token: String, client: String, nonce: String, jwks: Data, now: Date = Date()) throws -> (String, String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let header = try JSONSerialization.jsonObject(with: decode64(parts[0])) as? [String: Any], header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let document = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = document["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] == nil || $0["use"] as? String == "sig") && ($0["alg"] == nil || $0["alg"] as? String == "RS256") }),
              let n = jwk["n"] as? String, let e = jwk["e"] as? String else { throw Failure("Invalid ChatGPT signing key or algorithm.") }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            let length = bytes.count
            let prefix: [UInt8] = length < 128 ? [UInt8(length)] : length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)]
            return Data([tag] + prefix) + bytes
        }
        func integer(_ data: Data) -> Data { der(0x02, data.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + data : data) }
        let keyData = try der(0x30, integer(decode64(n)) + integer(decode64(e)))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              try SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, decode64(parts[2]) as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: decode64(parts[1])) as? [String: Any] else { throw Failure("ChatGPT ID token signature validation failed.") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audiences.contains(client),
              audiences.count <= 1 || claims["azp"] as? String == client,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw Failure("ChatGPT ID token identity/nonce/expiry validation failed.") }
        return (subject, claims["email"] as? String ?? subject)
    }
}

actor ChatGPTPlan {
    static let shared = ChatGPTPlan()
    private var operationInProgress = false
    func snapshot() throws -> PlanStore { try PlanKeychain.read() }
    func signIn(clientID: String? = nil) async throws {
        guard !operationInProgress else { throw Failure("A ChatGPT operation is already running.") }
        operationInProgress = true; defer { operationInProgress = false }
        var store = try PlanKeychain.read(); try PlanKeychain.write(store) // persist host before opening browser
        let old = store.profiles.first { $0.clientID == clientID }
        let state = try PlanOAuth.random(), nonce = try PlanOAuth.random(), verifier = try PlanOAuth.random()
        let callback = try PlanCallback()
        let url = try await callback.receive { redirect in
            var fields = ["client_id": old?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": store.hostID, "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": PlanOAuth.scopes, "resource": PlanOAuth.resource, "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": PlanOAuth.challenge(verifier)]
            if let old {
                fields["id_token_hint"] = old.idToken; fields["login_hint"] = old.email
                if !old.scopes.contains("chatgpt.tokens.use.direct") { fields["prompt"] = "consent" }
            }
            else { fields["agent_name_hint"] = "Typeless Alt" }
            let auth = URL(string: "\(PlanOAuth.issuer)/api/accounts/authorize?\(String(data: PlanOAuth.form(fields), encoding: .utf8)!)")!
            DispatchQueue.main.async { NSWorkspace.shared.open(auth) }
        }
        let (client, code) = try PlanOAuth.callback(url, state: state, previousClient: old?.clientID)
        let data = try await PlanOAuth.send(URL(string: "\(PlanOAuth.issuer)/api/accounts/oauth/token")!, fields: ["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": "http://127.0.0.1:\(url.port!)/auth/callback", "resource": PlanOAuth.resource])
        let token = try JSONDecoder().decode(PlanToken.self, from: data)
        guard let idToken = token.id_token else { throw Failure("ChatGPT returned no ID token.") }
        let jwks = try await PlanOAuth.send(URL(string: "\(PlanOAuth.issuer)/.well-known/jwks.json")!)
        let (subject, email) = try PlanOAuth.validateID(idToken, client: client, nonce: nonce, jwks: jwks)
        guard old == nil || old?.subject == subject else { throw Failure("ChatGPT account changed; credentials were not replaced.") }
        let scopes = (token.scope ?? "").split(separator: " ").map(String.init)
        guard !token.access_token.isEmpty, token.token_type.lowercased() == "bearer" else { throw Failure("Invalid ChatGPT token response.") }
        let profile = PlanProfile(clientID: client, subject: subject, email: email, accessToken: token.access_token, refreshToken: token.refresh_token, idToken: idToken, expiresAt: Date().addingTimeInterval(token.expires_in), scopes: scopes)
        store.profiles.removeAll { $0.clientID == client }; store.profiles.append(profile); store.activeID = client
        try PlanKeychain.write(store)
        guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke") else { throw Failure("Signed in, but ChatGPT plan usage is disabled. Use Sign in with ChatGPT again to enable it; no inference was sent.") }
    }
    func select(_ client: String) throws {
        guard !operationInProgress else { throw Failure("Wait for the current ChatGPT operation.") }
        var store = try PlanKeychain.read()
        guard store.profiles.contains(where: { $0.clientID == client && $0.accessToken != nil }) else { throw Failure("Sign in to this ChatGPT account again.") }
        store.activeID = client; try PlanKeychain.write(store)
    }
    func signOut() async throws {
        guard !operationInProgress else { throw Failure("Wait for the current ChatGPT operation.") }
        operationInProgress = true; defer { operationInProgress = false }
        var store = try PlanKeychain.read()
        guard let index = store.profiles.firstIndex(where: { $0.clientID == store.activeID }) else { return }
        let profile = store.profiles[index]
        var revoked = profile.refreshToken == nil
        if let refresh = profile.refreshToken {
            for attempt in 0..<3 {
                do {
                    _ = try await PlanOAuth.send(URL(string: "\(PlanOAuth.issuer)/api/accounts/oauth/revoke")!, fields: ["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID])
                    revoked = true; break
                } catch { if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) } }
            }
        }
        store.profiles[index].accessToken = nil; store.profiles[index].refreshToken = nil; store.profiles[index].idToken = nil; store.activeID = nil
        try PlanKeychain.write(store)
        if !revoked { throw Failure("Signed out locally. Remote revocation was not confirmed; disconnect Typeless Alt in ChatGPT Settings.") }
    }
    func polish(_ text: String, model: String, bundleID: String) async throws -> String {
        guard !operationInProgress else { throw Failure("Wait for the current ChatGPT operation.") }
        operationInProgress = true; defer { operationInProgress = false }
        var store = try PlanKeychain.read()
        guard let index = store.profiles.firstIndex(where: { $0.clientID == store.activeID }), store.profiles[index].accessToken != nil else { throw Failure("Use menubar → Sign in with ChatGPT first.") }
        var profile = store.profiles[index]
        if profile.expiresAt.timeIntervalSinceNow < 60 {
            guard let refresh = profile.refreshToken else { throw Failure("ChatGPT session expired. Sign in again.") }
            let data = try await PlanOAuth.send(URL(string: "\(PlanOAuth.issuer)/api/accounts/oauth/token")!, fields: ["grant_type": "refresh_token", "client_id": profile.clientID, "refresh_token": refresh, "resource": PlanOAuth.resource])
            let token = try JSONDecoder().decode(PlanToken.self, from: data)
            guard !token.access_token.isEmpty, token.token_type.lowercased() == "bearer" else { throw Failure("Invalid ChatGPT token type.") }
            profile.accessToken = token.access_token; profile.refreshToken = token.refresh_token ?? refresh
            profile.idToken = token.id_token ?? profile.idToken
            profile.expiresAt = Date().addingTimeInterval(token.expires_in)
            if let scope = token.scope { profile.scopes = scope.split(separator: " ").map(String.init) }
            store.profiles[index] = profile; try PlanKeychain.write(store)
        }
        guard profile.scopes.contains("chatgpt.tokens.use.direct"), profile.scopes.contains("resource.invoke"), let access = profile.accessToken else { throw Failure("ChatGPT plan usage is not authorized. Sign in again.") }
        struct Catalog: Decodable { struct Model: Decodable { let slug: String; let visibility: String? }; let models: [Model] }
        let catalog = try JSONDecoder().decode(Catalog.self, from: await PlanOAuth.send(URL(string: "\(PlanOAuth.resource)/models")!, bearer: access))
        let available = catalog.models.filter { $0.visibility == "list" }
        guard let selected = model.isEmpty ? available.first?.slug : available.first(where: { $0.slug == model })?.slug else { throw Failure("ChatGPT plan model is unavailable. Clear chatgptModel to use the account's first available model.") }
        var request = URLRequest(url: URL(string: "\(PlanOAuth.resource)/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.payload(text, model: selected, bundleID: bundleID))
        let session = URLSession(configuration: .ephemeral, delegate: PlanNoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure("ChatGPT Responses HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check sign-in, model access and ChatGPT Settings → Usage. No paid API fallback was used.") }
        var stream = PlanStream()
        for try await line in bytes.lines {
            if let result = try stream.consume(line) { return result }
        }
        throw Failure("ChatGPT stream ended without response.completed. Nothing inserted.")
    }
    static func payload(_ text: String, model: String, bundleID: String) -> [String: Any] {
        ["model": model, "instructions": OpenAI.messages(text, bundleID: bundleID)[0]["content"]!, "input": [["role": "user", "content": text]], "store": false, "stream": true]
    }
}
struct PlanStream {
    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard raw != "[DONE]", let data = raw.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { return nil }
        if ["error", "response.failed", "response.incomplete"].contains(type) {
            throw Failure("ChatGPT response failed or was incomplete. Check plan allowance/access in ChatGPT Settings → Usage; nothing inserted.")
        }
        guard type == "response.completed", let response = event["response"] as? [String: Any], response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else { return nil }
        let text = output.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure("ChatGPT returned no usable polished text.") }
        return text
    }
}
