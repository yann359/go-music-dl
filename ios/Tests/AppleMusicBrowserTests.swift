import XCTest
@testable import MusicDL

// Isolated transport/storage fixtures only. Never presented as Apple account
// authorization or an end-to-end Safari/Universal Links success test.
private final class AppleMemoryStorage: AppleWebStorage {
    var record: AppleWebRecord?
    var fails = false
    func read() throws -> AppleWebRecord? { if fails { throw AppleBrowserError.storage }; return record }
    func write(_ value: AppleWebRecord?) throws { if fails { throw AppleBrowserError.storage }; record = value }
}
private final class AppleProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

@MainActor
final class AppleMusicBrowserTests: XCTestCase {
    private let origin = "https://relay.example.com"
    private let flow = String(repeating: "f", count: 43)
    private let secret = String(repeating: "b", count: 43)
    private let code = String(repeating: "c", count: 43)
    private let capability = String(repeating: "s", count: 43)
    private func environment(configured: Bool = true) -> (UserDefaults, AppleRelayClient) {
        let suite = "MusicDL.AppleBrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(configured ? origin : "", forKey: "account.apple.browser.origin")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); AppleProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AppleProtocol.self]
        return (defaults, AppleRelayClient(session: URLSession(configuration: config)))
    }
    private func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func handler(_ request: URLRequest) throws -> (Int, Data) {
        XCTAssertEqual(request.url?.host, "relay.example.com")
        switch request.url!.path {
        case "/v1/config": return (200, data(["version":1,"ready":true,"callback":AppleMusicBrowser.customCallback]))
        case "/v1/flows":
            let body = AppleProtocol.body(request)
            XCTAssertTrue(AppleMusicBrowser.opaque(body["challenge"] ?? "")); XCTAssertTrue(AppleMusicBrowser.opaque(body["state"] ?? ""))
            XCTAssertNil(body["verifier"])
            return (200, data(["id":flow,"browserURL":origin + "/connect#" + flow + "." + secret]))
        case "/v1/exchange": return (200, data(["session":capability,"expires":Date().addingTimeInterval(3600).timeIntervalSince1970]))
        case "/v1/read":
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + capability)
            if AppleProtocol.body(request)["path"] == "/v1/me/storefront" { return (200, data(["data":[["id":"cn","type":"storefronts"]]])) }
            return (200, data(["data":[]]))
        case "/v1/cancel", "/v1/session": return (204, Data())
        default: throw AppleBrowserError.response
        }
    }
    private func callback(_ pending: AppleWebPending, state: String? = nil) -> URL {
        var u = URLComponents(string: pending.callback)!
        u.queryItems = [URLQueryItem(name:"id",value:pending.id),URLQueryItem(name:"state",value:state ?? pending.state),URLQueryItem(name:"code",value:code)]
        return u.url!
    }
    func testMissingConfigurationDoesNotOpenBrowserOrClaimConnected() async {
        let (defaults, client) = environment(configured: false)
        AppleProtocol.handler = { _ in XCTFail("Unconfigured client used network"); throw AppleBrowserError.configuration }
        let browser = AppleMusicBrowser(storage: AppleMemoryStorage(), client: client, defaults: defaults, openBrowser: { _ in XCTFail("Unconfigured browser opened"); return true })
        await browser.connect()
        XCTAssertEqual(browser.summary.connection, .configurationUnavailable)
        XCTAssertTrue(browser.summary.detail.contains("Apple Developer Program"))
    }
    func testOriginsAndPKCEValidation() {
        for value in ["http://relay.example.com","https://user:password@relay.example.com","https://relay.example.com/path","https://relay.example.com:443","https://127.0.0.1","https://localhost","https://relay.local","https://relay.example.com?token=x"] { XCTAssertFalse(AppleMusicBrowser.validOrigin(value), value) }
        XCTAssertTrue(AppleMusicBrowser.validOrigin(origin))
        XCTAssertEqual(AppleMusicBrowser.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testRepeatedConnectOpensOnceAndPersistsPendingWithoutMusicToken() async throws {
        let (defaults, client) = environment(); let storage = AppleMemoryStorage(); var opened = 0
        AppleProtocol.handler = handler
        let browser = AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{ url in
            opened += 1; XCTAssertEqual(url.host,"relay.example.com"); XCTAssertNil(URLComponents(url:url,resolvingAgainstBaseURL:false)?.query)
            return true
        })
        await browser.connect(); await browser.connect()
        XCTAssertEqual(opened,1); XCTAssertEqual(browser.summary.connection,.authorizing)
        XCTAssertNotNil(storage.record?.pending); XCTAssertNil(storage.record?.session)
        XCTAssertNil(defaults.object(forKey:"music_user_token"))
        await browser.cancel()
    }
    func testCallbackRequiresStateExactTargetAndNoDuplicateFields() async throws {
        let (defaults, client) = environment(); let storage = AppleMemoryStorage(); var exchanged = 0
        AppleProtocol.handler = { request in if request.url!.path == "/v1/exchange" { exchanged += 1 }; return try self.handler(request) }
        let browser = AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{ _ in true })
        await browser.connect(); let pending = try XCTUnwrap(storage.record?.pending)
        for url in [callback(pending,state:"forged"),URL(string:callback(pending).absoluteString + "&code=duplicate")!,URL(string:callback(pending).absoluteString.replacingOccurrences(of:"//callback?",with:"//callback/other?"))!] {
            _ = await browser.handleCallback(url)
            XCTAssertNotEqual(browser.summary.connection,.connected)
        }
        XCTAssertEqual(exchanged,0)
        XCTAssertNotNil(storage.record?.pending); XCTAssertTrue(browser.hasPending)
        await browser.cancel(); XCTAssertFalse(browser.hasPending)
    }
    func testSuccessfulFixtureExchangeVerifiesBothAppleDataReadsBeforeConnected() async throws {
        let (defaults, client) = environment(); let storage = AppleMemoryStorage(); var reads: [String] = []
        AppleProtocol.handler = { request in if request.url!.path == "/v1/read" { reads.append(AppleProtocol.body(request)["path"] ?? "") }; return try self.handler(request) }
        let browser = AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{ _ in true })
        await browser.connect(); let pending = try XCTUnwrap(storage.record?.pending)
        let handled = await browser.handleCallback(callback(pending))
        XCTAssertTrue(handled); XCTAssertEqual(browser.summary.connection,.connected)
        XCTAssertEqual(reads,["/v1/me/storefront","/v1/me/library/playlists?limit=1"])
        XCTAssertEqual(storage.record?.session?.capability,capability); XCTAssertNil(storage.record?.pending)
        XCTAssertTrue(browser.summary.detail.contains("原生 MusicKit"))
        await browser.disconnect(); XCTAssertNil(storage.record); XCTAssertEqual(browser.summary.connection,.disconnected)
        do { _ = try await browser.read("/v1/me/storefront"); XCTFail("Disconnected session readable") } catch {}
    }
    func testRestorePendingSupportsAppTerminationBeforeBrowserReturns() async throws {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();AppleProtocol.handler=handler
        let first=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await first.connect();let pending=try XCTUnwrap(storage.record?.pending)
        let restored=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in XCTFail("Restoration reopened browser");return false})
        await restored.restore();XCTAssertEqual(restored.summary.connection,.authorizing)
        _ = await restored.handleCallback(callback(pending));XCTAssertEqual(restored.summary.connection,.connected)
        await first.cancel();await restored.disconnect()
    }
    func testCancelledCallbackCannotResurrectSession() async throws {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();AppleProtocol.handler=handler
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await browser.connect();let pending=try XCTUnwrap(storage.record?.pending);await browser.cancel()
        _ = await browser.handleCallback(callback(pending));XCTAssertNotEqual(browser.summary.connection,.connected);XCTAssertNil(storage.record?.session)
    }
    func testDeniedLibraryNeverReportsConnectedAndDoesNotExposeServerErrors() async throws {
        let (defaults,client)=environment();let storage=AppleMemoryStorage()
        AppleProtocol.handler={ request in
            if request.url!.path == "/v1/read" && AppleProtocol.body(request)["path"]?.contains("playlists") == true { return (403,self.data(["error":"music_access_denied","debug":"DO-NOT-DISPLAY-token-secret"])) }
            return try self.handler(request)
        }
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await browser.connect();let pending=try XCTUnwrap(storage.record?.pending);_ = await browser.handleCallback(callback(pending))
        XCTAssertEqual(browser.summary.connection,.failed);XCTAssertNil(storage.record?.session)
        XCTAssertFalse(browser.summary.detail.contains("DO-NOT-DISPLAY"));XCTAssertTrue(browser.summary.detail.contains("MusicKit"))
    }
    func testRedirectedBrowserURLAndServiceFailureAreRejected() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage()
        AppleProtocol.handler={ request in
            if request.url!.path == "/v1/flows" { return (200,self.data(["id":self.flow,"browserURL":"https://attacker.example/connect#"+self.flow+"."+self.secret])) }
            return try self.handler(request)
        }
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in XCTFail("Unsafe browser destination opened");return true})
        await browser.connect();XCTAssertEqual(browser.summary.connection,.failed)
        AppleProtocol.handler={_ in (503,self.data(["error":"developer_unavailable"]))}
        await browser.connect();XCTAssertEqual(browser.summary.connection,.configurationUnavailable)
    }
    func testNetworkAndRateLimitHaveActionableReasons() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage()
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        AppleProtocol.handler={_ in throw URLError(.notConnectedToInternet)}
        await browser.connect();XCTAssertEqual(browser.summary.connection,.failed);XCTAssertTrue(browser.summary.detail.contains("网络"))
        AppleProtocol.handler={_ in (429,self.data(["error":"apple_rate_limited"]))}
        await browser.connect();XCTAssertTrue(browser.summary.detail.contains("稍后重试"))
        AppleProtocol.handler={_ in throw URLError(.serverCertificateUntrusted)}
        await browser.connect();XCTAssertTrue(browser.summary.detail.contains("证书"))
        AppleProtocol.handler={_ in throw URLError(.timedOut)}
        await browser.connect();XCTAssertTrue(browser.summary.detail.contains("超时"))
    }
    func testStorageFailurePreventsOpeningBrowser() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();storage.fails=true
        AppleProtocol.handler=handler
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in XCTFail("Unpersisted auth opened browser");return true})
        await browser.connect();XCTAssertEqual(browser.summary.connection,.failed);XCTAssertTrue(browser.summary.detail.contains("解锁"))
    }
    func testDisconnectionBlocksRestorationEvenIfKeychainDeleteFails() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage()
        storage.record=AppleWebRecord(origin:origin,session:AppleWebSession(capability:capability,expires:Date().addingTimeInterval(3600)))
        storage.fails=true;AppleProtocol.handler=handler
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await browser.disconnect();XCTAssertTrue(defaults.bool(forKey:"account.apple.browser.disabled"))
        storage.fails=false;await browser.restore();XCTAssertNotEqual(browser.summary.connection,.connected)
    }
    func testBrowserAuthorizationDoesNotMarkNativeMusicKitConnected() async throws {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();AppleProtocol.handler=handler
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        let accounts=MusicAccounts(defaults:defaults,appleBrowser:browser,installSession:{_,_ in})
        await accounts.connectAppleBrowser();let pending=try XCTUnwrap(storage.record?.pending)
        await accounts.handleAppleCallback(callback(pending))
        XCTAssertEqual(accounts.summary("apple").connection,.connected)
        XCTAssertEqual(accounts.appleSystemSummary.connection,.disconnected)
        XCTAssertFalse(defaults.bool(forKey:"account.apple.enabled"))
        await accounts.disconnectApple()
    }
    func testStateBoundSafariCancellationClearsPendingWithoutExchanging() async throws {
        let (defaults,client)=environment();let storage=AppleMemoryStorage()
        AppleProtocol.handler={ request in
            XCTAssertNotEqual(request.url?.path,"/v1/exchange")
            return try self.handler(request)
        }
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await browser.connect();let pending=try XCTUnwrap(storage.record?.pending)
        let url=URL(string:callback(pending).absoluteString.replacingOccurrences(of:"code="+code,with:"error=cancelled"))!
        _ = await browser.handleCallback(url)
        XCTAssertNil(storage.record?.pending);XCTAssertNil(storage.record?.session)
        XCTAssertEqual(browser.summary.connection,.disconnected)
    }
    func testBrowserLaunchFailureCancelsPendingAndShowsActualReason() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();AppleProtocol.handler=handler
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in false})
        await browser.connect();XCTAssertNil(storage.record?.pending)
        XCTAssertEqual(browser.summary.connection,.failed);XCTAssertTrue(browser.summary.detail.contains("未能打开浏览器"))
    }
    func testExpiredPendingRequiresFreshAuthorizationAndRejectsOldCallback() async {
        let (defaults,client)=environment();let storage=AppleMemoryStorage();AppleProtocol.handler=handler
        let pending=AppleWebPending(id:flow,state:String(repeating:"t",count:43),verifier:String(repeating:"v",count:43),callback:AppleMusicBrowser.customCallback,expires:.distantPast)
        storage.record=AppleWebRecord(origin:origin,pending:pending)
        let browser=AppleMusicBrowser(storage:storage,client:client,defaults:defaults,openBrowser:{_ in true})
        await browser.restore();XCTAssertEqual(browser.summary.connection,.failed)
        XCTAssertNil(storage.record?.pending)
        _ = await browser.handleCallback(callback(pending));XCTAssertNotEqual(browser.summary.connection,.connected)
    }
}
