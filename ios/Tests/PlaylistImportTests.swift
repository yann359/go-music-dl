import XCTest
@testable import MusicDL

@MainActor
final class PlaylistImportTests: XCTestCase {
    private func track(_ title: String = "晴天", artist: String = "周杰伦", album: String = "", duration: Int = 0) -> ImportTrack {
        ImportTrack(id: "metadata", title: title, artist: artist, album: album, duration: duration, source: "text", sourceID: "", playlistID: "", isrc: "", cover: "", localPath: "")
    }
    private func song(_ title: String = "晴天", artist: String = "周杰伦", album: String = "叶惠美", duration: Int = 269, source: String = "netease") -> Song {
        Song(id: "candidate", source: source, name: title, artist: artist, album: album, cover: "", duration: duration, extra: "{}")
    }
    func testMatchingRejectsWrongArtistAndVersions() {
        let input = track()
        XCTAssertNotNil(SongMatchingService.automatic(input, candidates: [song()]))
        XCTAssertNil(SongMatchingService.automatic(input, candidates: [song(artist: "同名的其他歌手")]))
        for title in ["晴天 (Live)", "晴天（现场版）", "晴天 Remix", "晴天 伴奏", "晴天 翻唱", "晴天 Acoustic"] {
            XCTAssertEqual(SongMatchingService.score(input, song(title)), 0, title)
        }
        XCTAssertEqual(SongMatchingService.normalized("Ｈｅｌｌｏ, World!"), SongMatchingService.normalized("hello world"))
        XCTAssertNil(SongMatchingService.automatic(track(artist: ""), candidates: [song()]))
    }
    func testAmbiguousAlbumsNeedManualChoiceAndDurationMatters() {
        XCTAssertNil(SongMatchingService.automatic(track(), candidates: [song(), song(album: "另一张专辑", duration: 240)]))
        XCTAssertNotNil(SongMatchingService.automatic(track(duration: 269), candidates: [song(), song(album: "另一张专辑", duration: 240)]))
        XCTAssertNil(SongMatchingService.automatic(track(duration: 300), candidates: [song()]))
        XCTAssertNil(SongMatchingService.automatic(track(), candidates: [song(source: "import-metadata")]))
    }
    func testMetadataIdentityAndISRCCannotOverrideWrongArtist() {
        var input = track(); input.source = "netease"; input.sourceID = "candidate"; input.isrc = "USABC1234567"
        var candidate = song(artist: "其他人"); candidate.extra = #"{"isrc":"USABC1234567"}"#
        XCTAssertEqual(SongMatchingService.score(input, candidate), 0)
    }
    func testDraftRoundTripAndOldLibraryAreIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = PlaylistImportRepository(directory: root)
        var draft = PlaylistImportDraft(collectionID: "42")
        draft.rows = [ImportRow(track: track()), ImportRow(track: track("江南", artist: "林俊杰"))]
        draft.offset = 50; draft.readComplete = false; draft.link = "https://music.163.com/playlist?id=1"
        try repo.save(draft)
        let loaded = try XCTUnwrap(repo.load("42"))
        XCTAssertEqual(loaded.rows.map(\.track.title), ["晴天", "江南"])
        XCTAssertEqual(loaded.offset, 50); XCTAssertFalse(loaded.readComplete)
        XCTAssertNil(try repo.load("43")); XCTAssertThrowsError(try repo.load("../42"))
        try Data("bad json".utf8).write(to: root.appendingPathComponent("42.json"))
        XCTAssertThrowsError(try repo.load("42"))
    }
    func testUTF16FilesAndBinaryErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "周杰伦 - 晴天"
        try text.data(using: .utf16)!.write(to: root)
        XCTAssertEqual(try PlaylistImportView.fileText(root), text)
        try Data([0, 0xFF, 0xAB]).write(to: root)
        XCTAssertThrowsError(try PlaylistImportView.fileText(root))
    }
    private func finished(_ service: PlaylistImportService) async {
        for _ in 0..<200 where service.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.busy)
    }
    func testPreviewIsSeparateFromConfirmedWriteAndSurvivesFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = PlaylistImportRepository(directory: root)
        let input = track(); var writes = 0
        let client = NativeClient { data in
            let r = try JSONDecoder().decode(JSONValue.self, from: data)
            switch r["action"].stringValue {
            case "playlist_import.parse": return try JSONEncoder().encode(JSONValue.object(["data": try .encoded([input])]))
            case "collections.add_batch":
                writes += 1
                XCTAssertEqual(r["params"]["songs"].arrayValue.first?["source"].stringValue, "import-metadata")
                return Data(#"{"data":{"added":1,"duplicates":0}}"#.utf8)
            case "collections.list": return Data(#"{"data":[]}"#.utf8)
            default: return Data(#"{"error":"网络超时"}"#.utf8)
            }
        }
        let service = PlaylistImportService(collectionID: "42", repository: repo)
        service.parse(text: "周杰伦 - 晴天", format: "text", client: client)
        await finished(service)
        XCTAssertEqual(service.draft.rows.count, 1); XCTAssertEqual(writes, 0)
        service.readLink("https://music.163.com/playlist?id=1", source: "netease", client: client)
        await finished(service)
        XCTAssertNotNil(service.problem); XCTAssertEqual(service.draft.rows.count, 1)
        service.commit(client: client, completed: {})
        await finished(service)
        XCTAssertEqual(writes, 1); XCTAssertTrue(service.draft.rows[0].committed)
        let restored = PlaylistImportService(collectionID: "42", repository: repo)
        XCTAssertTrue(restored.draft.confirmed); XCTAssertEqual(restored.draft.added, 1)
        restored.commit(client: client, completed: {}); await finished(restored)
        XCTAssertEqual(writes, 1, "reopening results must not write a second copy")
    }
    func testCanceledReadCannotOverwriteNewPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = track()
        let client = NativeClient { data in
            let r = try JSONDecoder().decode(JSONValue.self, from: data)
            if r["action"].stringValue == "playlist_import.page" { try await Task.sleep(nanoseconds: 100_000_000); return Data(#"{"error":"old failed request"}"#.utf8) }
            return try JSONEncoder().encode(JSONValue.object(["data": try .encoded([input])]))
        }
        let service = PlaylistImportService(collectionID: "42", repository: PlaylistImportRepository(directory: root))
        service.readLink("https://music.163.com/playlist?id=1", source: "netease", client: client)
        await Task.yield(); service.pause()
        service.parse(text: "周杰伦 - 晴天", format: "text", client: client)
        await finished(service); try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.draft.rows.first?.track.title, "晴天"); XCTAssertNil(service.problem)
    }
}
