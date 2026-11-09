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
        XCTAssertEqual(client.sources.count, 14)
        XCTAssertTrue(client.sources.contains { $0.id == "local" })
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

        let engine = AudioEngine()
        let connection = NativeAIConnection(baseURL: baseURL, audio: engine)
        defer { connection.stop(); engine.shutdown() }
        connection.start()
        var connected = false
        for _ in 0..<30 {
            let state = try await client.request("ai.state")
            if state["connected_clients"].numberValue > 0 { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(connected, "Native AI SSE client did not connect")
        _ = try await client.request("ai.command", params: ["action": .string("volume"), "volume": .number(0.25)])
        for _ in 0..<30 {
            if abs(engine.player.volume - 0.25) < 0.01 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(engine.player.volume, 0.25, accuracy: 0.01)
    }
}
