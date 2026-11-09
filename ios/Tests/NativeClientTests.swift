import XCTest
@testable import MusicDL

@MainActor
final class NativeClientTests: XCTestCase {
    func testNativeSearchPreservesSourceMetadataAndAcceptsObjectExtra() async throws {
        let client = NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(request["action"].stringValue, "search")
            XCTAssertEqual(request["params"]["sources"].arrayValue, [.string("netease"), .string("qq")])
            return Data(#"{"data":{"songs":[{"id":"one","source":"netease","name":"曲目","extra":{"quality":"lossless"}}],"playlists":[],"errors":["QQ 音乐暂时不可用"]}}"#.utf8)
        }
        let result = try await client.search(query: "曲目", sources: ["netease", "qq"])
        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.songs[0].source, "netease")
        let extra = try JSONDecoder().decode(JSONValue.self, from: Data(result.songs[0].extra.utf8))
        XCTAssertEqual(extra["quality"], .string("lossless"))
        XCTAssertEqual(result.errors, ["QQ 音乐暂时不可用"])
    }

    func testSettingsPatchKeepsUnknownOriginalFields() async throws {
        let client = NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            let value: JSONValue
            if request["action"] == .string("settings.get") {
                value = .object(["webdavEnabled": .bool(true), "futureSetting": .string("keep-me"), "downloadConcurrency": .number(3)])
            } else {
                value = request["params"]["settings"]
                XCTAssertEqual(value["futureSetting"], .string("keep-me"))
                XCTAssertEqual(value["downloadConcurrency"], .number(5))
            }
            return try JSONEncoder().encode(JSONValue.object(["data": value]))
        }
        try await client.loadSettings()
        try await client.saveSettings(["downloadConcurrency": .number(5)])
        XCTAssertEqual(client.settings["futureSetting"], .string("keep-me"))
        XCTAssertEqual(client.settings["webdavEnabled"], .bool(true))
    }

    func testServiceErrorCannotBecomeFakeEmptySuccess() async {
        let client = NativeClient { _ in Data(#"{"error":"音源授权已过期"}"#.utf8) }
        do {
            _ = try await client.search(query: "test", sources: ["netease"])
            XCTFail("A failed provider request was treated as success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("音源授权已过期")) }
    }

    func testAllProviderFailuresAreReportedAsFailure() async {
        let client = NativeClient { _ in Data(#"{"data":{"songs":[],"playlists":[],"errors":["来源授权已过期"]}}"#.utf8) }
        do { _ = try await client.search(query: "test", sources: ["qq"]); XCTFail("Provider failures appeared as empty success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("授权已过期")) }
    }

    func testAlbumAndAuthorizationMetadataReachNativePlayer() async throws {
        let client = NativeClient { _ in Data(#"{"data":{"songs":[{"id":"one","source":"qq","album_id":"album","link":"https://example.com/track","is_vip":true}],"errors":[]}}"#.utf8) }
        let result = try await client.search(query: "test", sources: ["qq"])
        XCTAssertEqual(result.songs.first?.albumID, "album")
        XCTAssertEqual(result.songs.first?.isVIP, true)
        XCTAssertEqual(result.songs.first?.link, "https://example.com/track")
    }

    func testLibraryIDsAndDownloadStatusesDecodeOriginalGoFormats() throws {
        let collection = try JSONDecoder().decode(NativeCollection.self, from: Data(#"{"id":42,"name":"收藏","kind":"manual","source":"local"}"#.utf8))
        XCTAssertEqual(collection.id, "42")
        let task = try JSONDecoder().decode(NativeDownloadTask.self, from: Data(#"{"ID":7,"Name":"歌曲","Status":"failed","Error":"需要授权","Attempts":1}"#.utf8))
        XCTAssertEqual(task.id, 7)
        XCTAssertEqual(task.status, "failed")
        XCTAssertEqual(task.error, "需要授权")
    }

    func testOfflinePreviewNeverSilentlyRunsProviderOperations() async throws {
        let client = NativeClient { _ in XCTFail("Preview used the live transport"); return Data() }
        client.loadOfflinePreview()
        XCTAssertTrue(client.isOfflinePreview)
        let result = try await client.search(query: "界面", sources: [])
        XCTAssertFalse(result.songs.isEmpty)
        do {
            try await client.enqueueDownload(result.songs)
            XCTFail("Preview performed a write")
        } catch { XCTAssertTrue(error.localizedDescription.contains("演示模式")) }
    }

    func testDiscoveryPublishesFastSourceBeforeSlowSourceAndRetriesOnlyFailure() async throws {
        var calls: [String: Int] = [:]
        var qqAvailable = false
        let client = NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            let action = request["action"].stringValue
            let source = request["params"]["sources"].arrayValue.first!.stringValue
            let key = action + ":" + source
            calls[key, default: 0] += 1
            if source == "qq" {
                try await Task.sleep(nanoseconds: 250_000_000)
                if !qqAvailable { return Data(#"{"error":"unexpected EOF https://private.example"}"#.utf8) }
            } else { try await Task.sleep(nanoseconds: 20_000_000) }
            if action == "toplists" { return Data(#"{"data":{"toplists":[],"errors":[]}}"#.utf8) }
            return Data("{\"data\":{\"songs\":[],\"playlists\":[{\"id\":\"\(source)\",\"name\":\"Real\",\"source\":\"\(source)\"}],\"errors\":[]}}".utf8)
        }
        let load = Task { await client.loadDiscovery() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.discoveryPlaylists.map(\.source), ["netease"])
        XCTAssertTrue(client.discoveryLoading)
        await load.value
        XCTAssertEqual(Set(client.discoveryFailures.keys), ["recommend:qq"])
        XCTAssertFalse(client.discoveryFailures.values.contains { $0.contains("http") || $0.contains("EOF") })
        qqAvailable = true
        await client.loadDiscovery(onlyFailed: true)
        XCTAssertEqual(client.discoveryPlaylists.map(\.source), ["netease", "qq"])
        XCTAssertTrue(client.discoveryFailures.isEmpty)
        XCTAssertEqual(calls["recommend:netease"], 1)
        XCTAssertEqual(calls["recommend:qq"], 2)
        XCTAssertEqual(calls["toplists:netease"], 1)
    }

    func testDiscoveryWarmStartUsesPersistedValidatedCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("discovery.json")
        let cold = NativeClient(cacheURL: url) { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            if request["action"] == .string("toplists") { return Data(#"{"data":{"toplists":[],"errors":[]}}"#.utf8) }
            return Data(#"{"data":{"songs":[],"playlists":[{"id":"real","source":"netease"}],"errors":[]}}"#.utf8)
        }
        await cold.loadDiscovery()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let warm = NativeClient(cacheURL: url) { _ in XCTFail("Fresh valid cache requested again"); return Data() }
        let start = Date()
        await warm.loadDiscovery()
        XCTAssertFalse(warm.discoveryPlaylists.isEmpty)
        XCTAssertFalse(warm.discoveryLoading)
        print("[discovery-test] persisted warm cache elapsed=\(Date().timeIntervalSince(start))s")
    }

    func testLyricsCannotExposeTechnicalErrors() async {
        let client = NativeClient { _ in Data(#"{"error":"download lyric failed https://private.example unexpected EOF"}"#.utf8) }
        do {
            _ = try await client.lyrics(for: Song(id: "id", source: "soda", name: "Song", artist: "Singer", album: "", cover: "", duration: 200, extra: ""))
            XCTFail("Failure silently accepted")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("http"))
            XCTAssertFalse(error.localizedDescription.contains("EOF"))
        }
    }

    func testStaleDiscoverySurvivesRefreshFailureButExpiredCacheDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("discovery.json")
        let value: JSONValue = .object(["songs": .array([]), "playlists": .array([.object(["id": .string("cached"), "source": .string("netease")])]), "errors": .array([])])
        for age in [1800.0, 86401.0] {
            let cache: JSONValue = .object(["recommend:netease": .object(["saved": .number(Date().timeIntervalSinceReferenceDate - age), "value": value])])
            try JSONEncoder().encode(cache).write(to: url)
            let client = NativeClient(cacheURL: url) { _ in throw URLError(.notConnectedToInternet) }
            await client.loadDiscovery()
            XCTAssertEqual(client.discoveryPlaylists.isEmpty, age > 86400)
            XCTAssertEqual(client.discoveryFailures.count, 3)
            XCTAssertFalse(client.discoveryLoading)
        }
    }

    func testAccountChangeInvalidatesDiscoveryCache() async throws {
        let client = NativeClient { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            if request["action"] == .string("cookies.get") { return Data(#"{"data":{"qq":"new-account"}}"#.utf8) }
            if request["action"] == .string("toplists") { return Data(#"{"data":{"toplists":[],"errors":[]}}"#.utf8) }
            return Data(#"{"data":{"songs":[],"playlists":[{"id":"real"}],"errors":[]}}"#.utf8)
        }
        await client.loadDiscovery()
        XCTAssertFalse(client.discoveryPlaylists.isEmpty)
        try await client.loadCookies()
        XCTAssertTrue(client.discoveryPlaylists.isEmpty)
    }

    func testMalformedDiscoveryCannotBecomeSuccessfulCachedConnection() async {
        let client = NativeClient { _ in Data(#"{"data":{}}"#.utf8) }
        await client.loadDiscovery()
        XCTAssertTrue(client.discoveryPlaylists.isEmpty)
        XCTAssertEqual(client.discoveryFailures.count, 3)
        XCTAssertFalse(client.discoveryLoading)
    }

    func testPendingSpotifyNeverBlocksOtherSelectedSources() async throws {
        let client = NativeClient(spotifyAuthorization: { _ in throw MusicAccountError.configuration }) { data in
            let request = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(request["params"]["sources"].arrayValue, [.string("qq")])
            return Data(#"{"data":{"songs":[{"id":"real","source":"qq"}],"playlists":[],"errors":[]}}"#.utf8)
        }
        let result = try await client.search(query: "Song", sources: ["spotify", "qq"])
        XCTAssertEqual(result.songs.map(\.source), ["qq"])
        XCTAssertTrue(result.errors.contains { $0.contains("Spotify 待配置") })
    }

    func testSpotifyRefreshFailurePreservesOtherProviderResults() async throws {
        let client = NativeClient(spotifyAuthorization: { force in if force { throw MusicAccountError.network } }) { _ in
            Data(#"{"data":{"songs":[{"id":"real","source":"qq"}],"playlists":[],"errors":["Spotify API HTTP 401"]}}"#.utf8)
        }
        let result = try await client.search(query: "Song", sources: ["qq", "spotify"])
        XCTAssertEqual(result.songs.map(\.source), ["qq"])
        XCTAssertFalse(result.errors.contains { $0.contains("401") })
    }
}
