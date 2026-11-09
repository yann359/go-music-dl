import XCTest
@testable import MusicDL

private final class OAuthProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
private final class MemoryTokenStorage: AccountTokenStorage {
    var tokens: SpotifyTokens?
    var failWrite = false
    var removed = false
    func read() throws -> SpotifyTokens? { tokens }
    func write(_ tokens: SpotifyTokens) throws { if failWrite { throw MusicAccountError.storage }; self.tokens = tokens }
    func remove() throws { tokens = nil; removed = true }
}

@MainActor
final class SpotifyAuthorizationTests: XCTestCase {
    private let clientID = String(repeating: "a", count: 32) // fixture only; never a production Client ID
    private func environment() -> (UserDefaults, SpotifyOAuthClient) {
        let suite = "MusicDL.AuthTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(clientID, forKey: "account.spotify.clientID")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); OAuthProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthProtocol.self]
        return (defaults, SpotifyOAuthClient(session: URLSession(configuration: config)))
    }
    private func successfulBrowser(_ url: URL) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: SpotifyConfiguration.redirect + "?code=fixture-code&state=" + state)!
    }

    func testPKCEUsesRFC7636VectorAndUnpredictableVerifier() throws {
        let pkce = SpotifyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "fixture-state")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let first = try SpotifyPKCE(), second = try SpotifyPKCE()
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertNotEqual(first.verifier, second.verifier); XCTAssertNotEqual(first.state, second.state)
        let url = try pkce.authorizationURL(config: SpotifyConfiguration(clientID: clientID))
        XCTAssertEqual(url.host, "accounts.spotify.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(items.contains { $0.name == "client_secret" || $0.name == "code_verifier" })
    }
    func testCallbackRejectsForgedStateHostPathAndDuplicateCode() throws {
        let pkce = SpotifyPKCE(verifier: "fixture", state: "expected")
        for callback in [
            SpotifyConfiguration.redirect + "?code=x&state=wrong",
            SpotifyConfiguration.redirect + "?code=x&state=expected&state=expected",
            SpotifyConfiguration.redirect + "?code=x&code=y&state=expected",
            "com.guohuiyuan.musicdl.spotify-login://attacker/callback?code=x&state=expected",
            "com.guohuiyuan.musicdl.spotify-login://oauth/other?code=x&state=expected"
        ] { XCTAssertThrowsError(try pkce.code(from: URL(string: callback)!)) }
        XCTAssertEqual(try pkce.code(from: URL(string: SpotifyConfiguration.redirect + "?code=valid&state=expected")!), "valid")
        XCTAssertThrowsError(try pkce.code(from: URL(string: SpotifyConfiguration.redirect + "?error=access_denied&state=expected")!)) { XCTAssertEqual($0 as? MusicAccountError, .denied) }
    }
    func testCodeExchangeProfileValidationAndSecurePersistence() async throws {
        let (defaults, oauth) = environment(); let storage = MemoryTokenStorage()
        OAuthProtocol.handler = { request in
            if request.url!.host == "accounts.spotify.com" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = OAuthProtocol.body(request)
                XCTAssertTrue(body.contains("code_verifier=")); XCTAssertFalse(body.contains("client_secret="))
                XCTAssertTrue(body.contains("grant_type=authorization_code")); XCTAssertTrue(body.contains("code=fixture-code"))
                return (200, Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","token_type":"Bearer","expires_in":3600,"scope":"playlist-read-private"}"#.utf8))
            }
            XCTAssertEqual(request.url!.absoluteString, "https://api.spotify.com/v1/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            return (200, Data(#"{"id":"fixture-user","display_name":"Test Listener"}"#.utf8))
        }
        var installed: String?
        let accounts = MusicAccounts(storage: storage, oauth: oauth, defaults: defaults, authenticate: successfulBrowser) { access, _ in installed = access }
        await accounts.connectSpotify()
        XCTAssertEqual(accounts.summary("spotify").connection, .connected)
        XCTAssertEqual(accounts.summary("spotify").account, "Test Listener")
        XCTAssertEqual(storage.tokens?.refresh, "fixture-refresh")
        XCTAssertEqual(installed, "fixture-access")
        XCTAssertNil(defaults.object(forKey: "refresh_token")); XCTAssertNil(defaults.object(forKey: "access_token"))
    }
    func testRestoreRefreshesExpiredTokenAndKeepsUnrotatedRefreshToken() async throws {
        let (defaults, oauth) = environment(); let storage = MemoryTokenStorage()
        storage.tokens = SpotifyTokens(clientID: clientID, access: "expired", refresh: "keep-refresh", expires: .distantPast, scopes: "playlist-read-private")
        OAuthProtocol.handler = { request in
            if request.url!.host == "accounts.spotify.com" {
                return (200, Data(#"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, Data(#"{"id":"restored"}"#.utf8))
        }
        let accounts = MusicAccounts(storage: storage, oauth: oauth, defaults: defaults, installSession: { _, _ in })
        await accounts.restore()
        XCTAssertEqual(accounts.summary("spotify").connection, .connected)
        XCTAssertEqual(storage.tokens?.refresh, "keep-refresh")
        XCTAssertEqual(storage.tokens?.access, "new-access")
    }
    func testInvalidGrantRequiresReauthorizationAndClearsGoSession() async {
        let (defaults, oauth) = environment(); let storage = MemoryTokenStorage()
        storage.tokens = SpotifyTokens(clientID: clientID, access: "expired", refresh: "invalid", expires: .distantPast, scopes: "")
        OAuthProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        var cleared = false
        let accounts = MusicAccounts(storage: storage, oauth: oauth, defaults: defaults, installSession: { access, _ in if access.isEmpty { cleared = true } })
        await accounts.restore()
        XCTAssertEqual(accounts.summary("spotify").connection, .expired)
        XCTAssertTrue(cleared)
        XCTAssertTrue(defaults.bool(forKey: "account.spotify.requiresReauth"))
    }
    func testCancelledLoginNeverMarksAccountConnected() async {
        let (defaults, oauth) = environment()
        OAuthProtocol.handler = { _ in XCTFail("Cancelled flow used network"); throw URLError(.cancelled) }
        let accounts = MusicAccounts(storage: MemoryTokenStorage(), oauth: oauth, defaults: defaults, authenticate: { _ in throw MusicAccountError.cancelled }, installSession: { _, _ in XCTFail("Cancelled flow installed a session") })
        await accounts.connectSpotify()
        XCTAssertEqual(accounts.summary("spotify").connection, .disconnected)
    }
    func testNetworkFailureKeepsStoredTokensButDoesNotClaimConnection() async {
        let (defaults, oauth) = environment(); let storage = MemoryTokenStorage()
        storage.tokens = SpotifyTokens(clientID: clientID, access: "valid", refresh: "keep", expires: .distantFuture, scopes: "")
        OAuthProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let accounts = MusicAccounts(storage: storage, oauth: oauth, defaults: defaults, installSession: { _, _ in })
        await accounts.restore()
        XCTAssertEqual(accounts.summary("spotify").connection, .unavailable)
        XCTAssertNotNil(storage.tokens)
        XCTAssertFalse(accounts.summary("spotify").detail.contains("http"))
    }
    func testDisconnectErasesStoredTokenEvenWhenBridgeIsUnavailable() async {
        let (defaults, oauth) = environment(); let storage = MemoryTokenStorage()
        storage.tokens = SpotifyTokens(clientID: clientID, access: "old", refresh: "old", expires: .distantFuture, scopes: "")
        let accounts = MusicAccounts(storage: storage, oauth: oauth, defaults: defaults, installSession: { _, _ in throw MusicAccountError.service })
        let success = await accounts.disconnectSpotify()
        XCTAssertFalse(success)
        XCTAssertNil(storage.tokens); XCTAssertTrue(storage.removed)
        XCTAssertTrue(defaults.bool(forKey: "account.spotify.requiresReauth"))
    }
    func testMissingClientIDRemainsPendingAndNeverStartsAuthentication() async {
        let (defaults, oauth) = environment(); defaults.set("", forKey: "account.spotify.clientID")
        let accounts = MusicAccounts(storage: MemoryTokenStorage(), oauth: oauth, defaults: defaults, authenticate: { _ in XCTFail("Pending source opened browser"); throw MusicAccountError.configuration }, installSession: { _, _ in XCTFail("Pending source touched bridge") })
        await accounts.connectSpotify()
        XCTAssertFalse(accounts.spotifyConfigured)
        XCTAssertEqual(accounts.summary("spotify").connection, .unavailable)
    }
}
