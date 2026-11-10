import XCTest
import AVFoundation
import MediaPlayer
@testable import MusicDL

@MainActor
final class MediaSessionTests: XCTestCase {
    private func engine() throws -> AudioEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        for i in 0..<96000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 48000)) * 0.02 }
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioEngine(files: AudioFiles { song, _ in
            AssetDescriptor(url: url, headers: [:], temporary: "", source: song.source, id: song.id)
        })
    }

    private func queue(_ engine: AudioEngine) async throws {
        let song = Song(id: "media-session", source: "fixture", name: "Session fixture", artist: "CI", album: "CI", cover: "", duration: 2, extra: "")
        engine.handle(PlaybackRequest(action: "queue", songs: [song], index: 0, loop: "one", order: "list"))
        for _ in 0..<100 {
            if engine.player.currentItem?.status == .readyToPlay { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("fixture failed to prepare")
    }

    func testSingleSessionPublishesActualPauseAndPlayState() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        let session = try XCTUnwrap(engine.nowPlayingSession)
        XCTAssertEqual(session.players.count, 1)
        XCTAssertTrue(session.players.first === engine.player)
        XCTAssertFalse(session.automaticallyPublishesNowPlayingInfo)
        try await queue(engine)
        engine.play()
        for _ in 0..<100 { if engine.isPlaying { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(session.nowPlayingInfoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 1)
        XCTAssertEqual(session.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Session fixture")
        engine.pause()
        XCTAssertEqual(session.nowPlayingInfoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 0)
        XCTAssertTrue(session.remoteCommandCenter.playCommand.isEnabled)
        XCTAssertTrue(engine.nowPlayingSession === session)
        engine.stop()
        XCTAssertNil(session.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(session.remoteCommandCenter.playCommand.isEnabled)
    }

    func testMediaResetRebindsSessionAndRetiresOldControls() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        let old = try XCTUnwrap(engine.nowPlayingSession)
        let oldPlayer = engine.player
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let next = try XCTUnwrap(engine.nowPlayingSession)
        XCTAssertFalse(old === next)
        XCTAssertFalse(oldPlayer === engine.player)
        // This test deliberately retains the old session. Its player lifetime
        // belongs to that session, while metadata and controls must be retired.
        XCTAssertNil(old.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(old.remoteCommandCenter.playCommand.isEnabled)
        XCTAssertEqual(next.players.count, 1)
        XCTAssertTrue(next.players.first === engine.player)
        engine.shutdown()
        XCTAssertNil(engine.nowPlayingSession)
        XCTAssertNil(next.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(next.remoteCommandCenter.playCommand.isEnabled)
    }

    func testBackgroundReturnRestoresPlayerOnceWithoutResumingPausedAudio() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        try await queue(engine)
        engine.pause()
        let model = AppModel(audio: engine); model.isReady = true
        let player = engine.player
        let session = engine.nowPlayingSession
        let songs = engine.songs
        model.sceneEnteredBackground()
        model.sceneBecameActive()
        XCTAssertTrue(model.showPlayer)
        XCTAssertTrue(engine.player === player)
        XCTAssertTrue(engine.nowPlayingSession === session)
        XCTAssertEqual(engine.songs, songs)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.player.rate, 0)
        model.showPlayer = false
        model.sceneBecameActive() // Control Center/inactive is not a background return.
        XCTAssertFalse(model.showPlayer)
        model.sceneEnteredBackground()
        engine.stop()
        model.sceneBecameActive()
        XCTAssertFalse(model.showPlayer)
    }
}
