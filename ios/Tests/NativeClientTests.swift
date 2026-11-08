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
}
