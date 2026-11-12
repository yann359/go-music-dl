import XCTest
@testable import MusicDL

@MainActor
final class NativeBridgeIntegrationTests: XCTestCase {
    func testActualGoBridgeBootstrapsAndPersistsNativeLibrary() async throws {
        // The embedded server is process-scoped. Keep its disposable test root
        // alive until the test host exits; never use the real app library here.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBridgeTests-" + UUID().uuidString)
        let baseURL = try await GoBridge.start(root: root.path)
        let client = NativeClient()
        try await client.loadBootstrap()
        XCTAssertEqual(client.sources.map(\.id), ["netease", "apple", "qq", "soda", "kugou", "spotify", "kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili"])
        // Device files remain a separate library capability, not an online account.
        XCTAssertFalse(client.sources.contains { $0.id == "local" })
        let collection = try await client.createCollection(name: "Native bridge acceptance")
        let sample = Song(id: "native-bridge-fixture", source: "netease", name: "仅用于数据库验收", artist: "测试样本", album: "", cover: "", duration: 0, extra: "{}")
        try await client.addToCollection(id: collection.id, song: sample)
        let songs = try await client.detail(kind: "collection", id: collection.id)
        XCTAssertEqual(songs.first?.id, sample.id)
        try await client.removeFromCollection(id: collection.id, song: sample)
        let afterRemoval = try await client.detail(kind: "collection", id: collection.id)
        XCTAssertTrue(afterRemoval.isEmpty)
        try await client.deleteCollection(id: collection.id)
        XCTAssertFalse(client.collections.contains { $0.id == collection.id })

        // Real public provider responses through the exact Swift -> C ABI -> Go path.
        // No fixture transport participates in these timing measurements.
        var cold = NativeSearchResult(), warm = NativeSearchResult()
        // Also exercise the opt-in Go HTTP tracing path with real providers.
        _ = try await client.request("diagnostics.enable")
        let searchStart = Date()
        var firstMS: Int?
        try await client.searchProgressively(query: "周杰伦 晴天", type: "song", sources: ["kugou", "kuwo", "migu"], refresh: true) { value in
            cold = value
            if firstMS == nil && !value.songs.isEmpty { firstMS = Int(Date().timeIntervalSince(searchStart) * 1000) }
        }
        let coldMS = Int(Date().timeIntervalSince(searchStart) * 1000)
        XCTAssertFalse(cold.songs.isEmpty, "Real providers returned no songs; inspect network/source errors")
        let warmStart = Date()
        try await client.searchProgressively(query: "周杰伦 晴天", type: "song", sources: ["kugou", "kuwo", "migu"]) { warm = $0 }
        let warmMS = Int(Date().timeIntervalSince(warmStart) * 1000)
        XCTAssertGreaterThan(warm.cachedSources, 0)
        XCTAssertEqual(Set(cold.songs.map(\.key)), Set(warm.songs.map(\.key)))
        print("[search-real-api] first_ms=\(firstMS ?? -1) cold_ms=\(coldMS) warm_ms=\(warmMS) songs=\(cold.songs.count) cached_sources=\(warm.cachedSources)")

        // Actual search results are added in one SQLite transaction through the
        // production batch boundary. Includes a retry and a local file parse.
        let destination = try await client.createCollection(name: "Real search import acceptance")
        var selectedIdentities = Set<String>()
        let selected = Array(cold.songs.filter { selectedIdentities.insert($0.source + ":" + $0.id).inserted }.prefix(2))
        XCTAssertEqual(selected.count, 2)
        for actual in selected {
            let metadata = ImportTrack(id: "actual-network-metadata", title: actual.name, artist: actual.artist,
                                       album: actual.album, duration: actual.duration, source: actual.source,
                                       sourceID: actual.id, playlistID: "", isrc: "", cover: actual.cover, localPath: "")
            XCTAssertEqual(SongMatchingService.automatic(metadata, candidates: cold.songs)?.id, actual.id)
        }
        let added = try await client.addSongsToCollection(id: destination.id, songs: selected)
        XCTAssertEqual(added.added, 2)
        let repeated = try await client.addSongsToCollection(id: destination.id, songs: selected)
        XCTAssertEqual(repeated.duplicates, 2)
        let imported = try await client.detail(kind: "collection", id: destination.id)
        XCTAssertEqual(imported.map(\.id), selected.map(\.id))
        XCTAssertEqual(imported.map(\.album), selected.map(\.album))
        let reloadedClient = NativeClient()
        let reloadedSongs = try await reloadedClient.detail(kind: "collection", id: destination.id)
        XCTAssertEqual(reloadedSongs.count, 2)
        let file = root.appendingPathComponent("playlist.csv")
        try Data("title,artist,album\n晴天,周杰伦,叶惠美\n".utf8).write(to: file)
        let parsed = try await client.request("playlist_import.parse", params: ["format": .string("csv"), "text": .string(try PlaylistImportView.fileText(file))]).decoded([ImportTrack].self)
        XCTAssertEqual(parsed.first?.title, "晴天")
        let textParsed = try await client.request("playlist_import.parse", params: ["format": .string("text"), "text": .string("周杰伦 - 晴天\n林俊杰 - 江南")]).decoded([ImportTrack].self)
        XCTAssertEqual(textParsed.count, 2)
        try await client.removeFromCollection(id: destination.id, song: selected[0])
        let afterBatchRemoval = try await client.detail(kind: "collection", id: destination.id)
        XCTAssertEqual(afterBatchRemoval.count, 1)
        try await client.deleteCollection(id: destination.id)

        let engine = AudioEngine()
        let connection = NativeAIConnection(baseURL: baseURL, audio: engine)
        defer { connection.stop(); engine.shutdown() }
        connection.start()
        var connected = false
        // Wait for actual readiness through the client's finite reconnect
        // window. A cold simulator's first URLSession startup can exceed 3s.
        for _ in 0..<100 {
            let state = try await client.request("ai.state")
            if state["connected_clients"].numberValue > 0 { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(connected, "Native AI SSE client did not connect")
        guard connected else { return } // Do not obscure this with a second 409.
        _ = try await client.request("ai.command", params: ["action": .string("volume"), "volume": .number(0.25)])
        for _ in 0..<30 {
            if abs(engine.player.volume - 0.25) < 0.01 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(engine.player.volume, 0.25, accuracy: 0.01)
    }
}
