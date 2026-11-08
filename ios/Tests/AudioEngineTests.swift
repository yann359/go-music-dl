import XCTest
import AVFoundation
@testable import MusicDL

@MainActor
final class AudioEngineTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 72000)!
        buffer.frameLength = 72000
        for n in 0..<72000 { buffer.floatChannelData![0][n] = Float(sin(Double(n) * 440 * 2 * .pi / 48000)) * 0.02 }
        try file.write(from: buffer)
        return url
    }

    private func songs(_ count: Int = 3) -> [Song] {
        (0..<count).map { Song(id: "\($0)", source: "fixture", name: "Fixture \($0)",
                             artist: "CI", album: "Native queue", cover: "", duration: 2, extra: "") }
    }

    func testThreeTracksAdvanceWithoutJavaScriptOrHTTP() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let files = AudioFiles { song, _ in
            AssetDescriptor(url: url, headers: [:], temporary: "", source: song.source, id: song.id)
        }
        let engine = AudioEngine(files: files)
        defer { engine.shutdown() }
        let completed = expectation(description: "all three native tracks played")
        var played = Set<Int>()
        engine.stateDidChange = { state in
            if state["playing"] as? Bool == true, let index = state["index"] as? Int {
                played.insert(index)
                if played == [0, 1, 2] { completed.fulfill(); engine.stateDidChange = nil }
            }
        }
        engine.handle(PlaybackRequest(action: "queue", songs: songs(), index: 0, loop: "none", order: "list"))
        engine.play()
        await fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(played, [0, 1, 2])
    }

    func testUserPauseDuringInterruptionDoesNotResume() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine(files: AudioFiles { song, _ in
            AssetDescriptor(url: url, headers: [:], temporary: "", source: song.source, id: song.id)
        })
        defer { engine.shutdown() }
        engine.handle(PlaybackRequest(action: "queue", songs: songs(1), index: 0, loop: "one", order: "list"))
        engine.play()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.pause()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(engine.player.rate, 0)
    }

    func testRemovingHeadphoneRoutePauses() async throws {
        let engine = AudioEngine()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.player.rate, 0)
        engine.shutdown()
    }

    func testReplacingQueueDiscardsStalePreparation() async throws {
        let oldURL = try fixture()
        let newURL = try fixture()
        defer { try? FileManager.default.removeItem(at: oldURL); try? FileManager.default.removeItem(at: newURL) }
        let engine = AudioEngine(files: AudioFiles { song, _ in
            if song.id == "old" { try await Task.sleep(nanoseconds: 250_000_000) }
            return AssetDescriptor(url: song.id == "old" ? oldURL : newURL, headers: [:], temporary: "", source: song.source, id: song.id)
        })
        defer { engine.shutdown() }
        var old = songs(1)[0]; old.id = "old"
        var new = songs(1)[0]; new.id = "new"
        engine.handle(PlaybackRequest(action: "queue", songs: [old], index: 0, loop: "one", order: "list"))
        engine.play()
        try await Task.sleep(nanoseconds: 30_000_000)
        engine.handle(PlaybackRequest(action: "queue", songs: [new], index: 0, loop: "one", order: "list"))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(engine.player.items().isEmpty)
        for item in engine.player.items() { XCTAssertEqual((item.asset as? AVURLAsset)?.url, newURL) }
    }

    func testMediaServiceResetPreservesExplicitPause() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let previousPlayer = engine.player
        engine.pause()
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(engine.player === previousPlayer)
        XCTAssertEqual(engine.player.rate, 0)
    }
}
