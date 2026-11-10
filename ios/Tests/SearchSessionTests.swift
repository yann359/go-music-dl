import XCTest
@testable import MusicDL

/// Controlled transports test state transitions only. Real provider acceptance
/// is recorded separately by TestNativeSearchLive and the native-startup UI test.
@MainActor
final class SearchSessionTests: XCTestCase {
    private func client(search: @escaping (JSONValue) async throws -> Data) -> NativeClient {
        NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            switch request["action"].stringValue {
            case "sources": return Data(#"{"data":{"sources":[{"id":"qq","search":true,"album":true,"playlist":true},{"id":"netease","search":true,"album":true,"playlist":true}],"defaults":[]}}"#.utf8)
            case "collections.list": return Data(#"{"data":[]}"#.utf8)
            case "local.songs": return Data(#"{"data":{"songs":[]}}"#.utf8)
            case "settings.get": return Data(#"{"data":{}}"#.utf8)
            default: return try await search(request)
            }
        }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Search state did not settle")
    }

    func testPartialResultsSurviveAnotherSourceFailure() async throws {
        let client = client { request in
            if request["params"]["sources"].arrayValue == [.string("qq")] {
                try await Task.sleep(nanoseconds: 200_000_000)
                throw URLError(.notConnectedToInternet)
            }
            return Data(#"{"data":{"songs":[{"id":"one","source":"netease","name":"歌曲"}],"playlists":[],"errors":[]}}"#.utf8)
        }
        try await client.loadBootstrap()
        let session = SearchSession()
        session.start(client: client, query: "周杰伦", kind: "song", sources: ["netease", "qq"])
        try await waitFor { session.phase == .partial }
        XCTAssertEqual(session.result?.songs.count, 1)
        try await waitFor { session.phase == .complete }
        XCTAssertEqual(session.result?.songs.count, 1)
        XCTAssertEqual(session.result?.errors.count, 1)
    }

    func testRapidQueryChangeAndClearCannotPublishOldResults() async throws {
        let client = client { request in
            let query = request["params"]["q"].stringValue
            try? await Task.sleep(nanoseconds: query == "old" ? 250_000_000 : 10_000_000)
            return Data("{\"data\":{\"songs\":[{\"id\":\"\(query)\",\"source\":\"qq\"}],\"playlists\":[],\"errors\":[]}}".utf8)
        }
        try await client.loadBootstrap()
        let session = SearchSession()
        session.start(client: client, query: "old", kind: "song", sources: ["qq"])
        try await Task.sleep(nanoseconds: 30_000_000)
        session.start(client: client, query: "new", kind: "song", sources: ["qq"])
        try await waitFor { session.phase == .complete }
        XCTAssertEqual(session.result?.songs.first?.id, "new")
        session.start(client: client, query: "", kind: "song", sources: ["qq"])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.result)
    }

    func testSubmitFlushesDebounceAndCachesSuccessfulSourceOnly() async throws {
        var requests = 0
        let client = client { _ in
            requests += 1
            return Data(#"{"data":{"songs":[{"id":"one","source":"qq"}],"playlists":[],"errors":[]}}"#.utf8)
        }
        try await client.loadBootstrap()
        let session = SearchSession()
        session.start(client: client, query: "Mine Mine", kind: "song", sources: ["qq"], debounce: true)
        session.start(client: client, query: "Mine Mine", kind: "song", sources: ["qq"])
        try await waitFor { session.phase == .complete }
        XCTAssertEqual(requests, 1)
        session.start(client: client, query: "Mine Mine", kind: "song", sources: ["qq"])
        try await waitFor { session.phase == .complete }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(session.result?.cachedSources, 1)
        session.start(client: client, query: "Mine Mine", kind: "song", sources: ["qq"], refresh: true)
        try await waitFor { session.phase == .complete }
        XCTAssertEqual(requests, 2)
    }

    func testEmptyFailureAndNoSelectionAreDifferentFromIdle() async throws {
        var fail = false
        let client = client { _ in
            if fail { throw URLError(.networkConnectionLost) }
            return Data(#"{"data":{"songs":[],"playlists":[],"errors":[]}}"#.utf8)
        }
        try await client.loadBootstrap()
        let session = SearchSession()
        session.start(client: client, query: "不存在", kind: "song", sources: ["qq"])
        try await waitFor { session.phase == .empty }
        fail = true
        session.start(client: client, query: "断网", kind: "song", sources: ["qq"])
        try await waitFor { session.phase == .failed }
        fail = false
        session.start(client: client, query: "恢复", kind: "song", sources: ["qq"], refresh: true)
        try await waitFor { session.phase == .empty }
        session.start(client: client, query: "歌曲", kind: "song", sources: [])
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNotNil(session.problem)
    }

    func testMalformedSearchPayloadCannotBecomeEmptySuccess() async throws {
        let client = NativeClient { _ in Data(#"{"data":{}}"#.utf8) }
        do { _ = try await client.search(query: "周杰伦", sources: ["qq"]); XCTFail("Malformed payload accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("结果")) }
    }

    func testAllRegisteredDefaultsPublishEvenWithEmptyLegacyDefaultList() async throws {
        var searched = Set<String>()
        let client = client { request in
            searched.formUnion(request["params"]["sources"].arrayValue.map(\.stringValue))
            return Data(#"{"data":{"songs":[],"playlists":[],"errors":[]}}"#.utf8)
        }
        try await client.loadBootstrap()
        var updates = 0
        try await client.searchProgressively(query: "周杰伦", type: "song", sources: []) { _ in updates += 1 }
        XCTAssertEqual(searched, ["netease", "qq", "local"])
        XCTAssertEqual(updates, 3, "An empty legacy defaults array must never leave the page at its initial prompt")
    }

    func testAccountChangeInvalidatesSearchCacheAndLocalIsAlwaysLive() async throws {
        var calls = 0
        let client = client { request in
            if request["action"] == .string("cookies.get") { return Data(#"{"data":{"qq":"changed-account"}}"#.utf8) }
            calls += 1
            return Data(#"{"data":{"songs":[{"id":"one","source":"qq"}],"playlists":[],"errors":[]}}"#.utf8)
        }
        try await client.loadBootstrap()
        for _ in 0..<2 { try await client.searchProgressively(query: "晴天", type: "song", sources: ["qq"]) { _ in } }
        XCTAssertEqual(calls, 1)
        try await client.loadCookies()
        try await client.searchProgressively(query: "晴天", type: "song", sources: ["qq"]) { _ in }
        XCTAssertEqual(calls, 2)
        for _ in 0..<2 { try await client.searchProgressively(query: "晴天", type: "song", sources: ["local"]) { _ in } }
        XCTAssertEqual(calls, 4)
    }
}
