import XCTest
@testable import MusicDL

@MainActor
final class StabilityTests: XCTestCase {
    private let complete = JSONValue.object(["songs": .array([.object(["id": .string("one"), "source": .string("netease")])]), "errors": .array([])])

    func testMalformedDetailIsNotAnEmptySuccessfulCache() async {
        let client = NativeClient { _ in Data(#"{"data":{}}"#.utf8) }
        do { _ = try await client.detail(kind: "album", id: "one", source: "netease"); XCTFail("malformed detail accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不完整")) }
        XCTAssertNil(client.cachedDetail(kind: "album", id: "one", source: "netease"))
    }

    func testDetailCacheCoalescesReadersAndExpiresWithoutLosingStaleData() async throws {
        var time = Date(timeIntervalSince1970: 100000)
        let store = DetailStore(now: { time })
        var calls = 0
        let load = { [self] in calls += 1; try await Task.sleep(nanoseconds: 30_000_000); return complete }
        async let first = store.load("chart", loader: load)
        async let second = store.load("chart", loader: load)
        _ = try await (first, second)
        XCTAssertEqual(calls, 1)
        _ = try await store.load("chart", loader: load)
        XCTAssertEqual(calls, 1)
        time = time.addingTimeInterval(901)
        XCTAssertNotNil(store.cached("chart"))
        _ = try await store.load("chart", loader: load)
        XCTAssertEqual(calls, 2)
        time = time.addingTimeInterval(86401)
        XCTAssertNil(store.cached("chart"))
    }

    func testPartialResponseIsVisibleButNotPromotedToCompleteCache() async throws {
        let store = DetailStore()
        var partial = complete; partial["errors"] = .array([.string("partial")])
        _ = try await store.load("album") { partial }
        XCTAssertNil(store.cached("album"))
        let client = NativeClient { _ in try JSONEncoder().encode(JSONValue.object(["data": partial])) }
        let result = try await client.detailPage(kind: "album", id: "one", source: "netease")
        XCTAssertEqual(result.songs.count, 1); XCTAssertTrue(result.partial)
    }

    func testOldAuthorizationResultCannotRepopulateInvalidatedCache() async throws {
        let store = DetailStore()
        let request = Task { [self] in try await store.load("playlist") {
            // Model a transport that finishes after cancellation.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return complete
        } }
        try await Task.sleep(nanoseconds: 20_000_000)
        store.invalidate()
        do { _ = try await request.value; XCTFail("stale authorization result accepted") }
        catch is CancellationError { }
        XCTAssertNil(store.cached("playlist"))
    }

    func testServiceRetriesAreFiniteAndCallersShareStartup() async throws {
        var calls = 0
        let service = LocalService { _ in
            calls += 1
            if calls == 1 { throw NativeError.message("temporary") }
            return URL(string: "http://127.0.0.1:37777/music/")!
        }
        async let first = service.connect(root: "/fixture")
        async let second = service.connect(root: "/fixture")
        _ = try await (first, second)
        XCTAssertEqual(calls, 2); XCTAssertEqual(service.state, .available)
        let failed = LocalService { _ in calls += 1; throw NativeError.message("offline") }
        do { _ = try await failed.connect(root: "/fixture"); XCTFail("false success") } catch { }
        XCTAssertEqual(calls, 5); XCTAssertEqual(failed.state, .unavailable)
    }

    func testRestoredSongSourcesDecodeWithoutChangingSavedMetadata() throws {
        for source in ["kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili"] {
            let song = Song(id: "old-id", source: source, name: "原有收藏", artist: "Artist", album: "", cover: "", duration: 120, extra: "{\"quality\":\"old\"}")
            let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
            XCTAssertEqual(song, restored); XCTAssertTrue(restored.sourceAvailable)
        }
    }

    func testProgressiveSearchPublishesFastSourceBeforeFailure() async throws {
        let client = NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            let source = request["params"]["sources"].arrayValue.first!.stringValue
            if source == "qq" { try await Task.sleep(nanoseconds: 120_000_000); return Data(#"{"error":"offline"}"#.utf8) }
            return Data(#"{"data":{"songs":[{"id":"one","source":"netease"}],"errors":[]}}"#.utf8)
        }
        var snapshots: [NativeSearchResult] = []
        try await client.searchProgressively(query: "Song", type: "song", sources: ["netease", "qq"]) { snapshots.append($0) }
        XCTAssertEqual(snapshots.first?.songs.count, 1)
        XCTAssertTrue(snapshots.first?.errors.isEmpty == true)
        XCTAssertEqual(snapshots.last?.songs.count, 1)
        XCTAssertEqual(snapshots.last?.errors.count, 1)
    }
}
