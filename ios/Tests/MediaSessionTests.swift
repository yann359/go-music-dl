import XCTest
import AVFoundation
import MediaPlayer
import UIKit
@testable import MusicDL

private actor MediaPreparationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class MediaSessionTests: XCTestCase {
    private func engine(gate: MediaPreparationGate? = nil) throws -> AudioEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 576000))
        buffer.frameLength = 576000
        for i in 0..<576000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 48000)) * 0.02 }
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioEngine(files: AudioFiles { song, _ in
            if let gate { await gate.wait() }
            return AssetDescriptor(url: url, headers: [:], temporary: "", source: song.source, id: song.id)
        })
    }

    private var song: Song {
        Song(id: "media-session", source: "fixture", name: "Session fixture", artist: "CI", album: "CI", cover: "", duration: 12, extra: "")
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(description)
    }

    private func queue(_ engine: AudioEngine) async throws {
        engine.handle(PlaybackRequest(action: "queue", songs: [song], index: 0, loop: "one", order: "list"))
        try await waitFor("fixture failed to prepare") { engine.player.currentItem?.status == .readyToPlay }
    }

    private func systemNumber(_ session: MPNowPlayingSession, _ key: String) -> Double? {
        (session.nowPlayingInfoCenter.nowPlayingInfo?[key] as? NSNumber)?.doubleValue
    }

    func testSingleSessionPublishesActualPauseAndPlayState() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        let session = try XCTUnwrap(engine.nowPlayingSession)
        XCTAssertEqual(session.players.count, 1)
        XCTAssertTrue(session.players.first === engine.player)
        XCTAssertTrue(session.automaticallyPublishesNowPlayingInfo)
        try await queue(engine)
        engine.play()
        try await waitFor("native player did not start") { engine.isPlaying }
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        try await waitFor("automatic playing rate did not reach the session") {
            self.systemNumber(session, MPNowPlayingInfoPropertyPlaybackRate) == 1
        }
        XCTAssertEqual(session.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, song.name)
        XCTAssertEqual(try XCTUnwrap(systemNumber(session, MPMediaItemPropertyPlaybackDuration)), 12, accuracy: 0.1)
        engine.pause()
        try await waitFor("automatic paused rate did not reach the session") {
            self.systemNumber(session, MPNowPlayingInfoPropertyPlaybackRate) == 0
        }
        XCTAssertEqual(engine.player.rate, 0)
        XCTAssertTrue(session.remoteCommandCenter.playCommand.isEnabled)
        XCTAssertTrue(engine.nowPlayingSession === session)
        engine.stop()
        XCTAssertNil(session.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(session.remoteCommandCenter.playCommand.isEnabled)
        try await queue(engine)
        engine.play()
        try await waitFor("stopped session did not rearm on a real item") { engine.isPlaying }
        XCTAssertTrue(session.automaticallyPublishesNowPlayingInfo)
        XCTAssertTrue(engine.nowPlayingSession === session)
    }

    func testPreparationDoesNotPublishQueuedSongOrStartAnEmptyPlayer() async throws {
        let gate = MediaPreparationGate()
        let engine = try engine(gate: gate); defer { engine.shutdown() }
        let session = try XCTUnwrap(engine.nowPlayingSession)
        engine.playSongs([song])
        engine.handle(PlaybackRequest(action: "rate", value: 1.5))
        // Reproduces the real Build28 window: play was requested, but resolving
        // the first local asset has not completed. No guessed timing delay.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.playbackState, .preparing)
        XCTAssertTrue(engine.waiting)
        XCTAssertNil(engine.player.currentItem)
        XCTAssertEqual(engine.player.rate, 0)
        XCTAssertEqual(engine.itemMetadataUpdateCount, 0)
        XCTAssertNil(session.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle])
        XCTAssertFalse(session.remoteCommandCenter.playCommand.isEnabled)
        await gate.open()
        try await waitFor("real prepared item did not start") { engine.isPlaying }
        XCTAssertEqual(engine.player.currentItem?.status, .readyToPlay)
        XCTAssertEqual(engine.player.rate, 1.5)
        XCTAssertTrue(engine.nowPlayingSession === session)
        try await waitFor("real item title did not publish") {
            session.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == self.song.name
        }
    }

    func testPauseDuringPreparationDoesNotAutoplayWhenItemArrives() async throws {
        let gate = MediaPreparationGate()
        let engine = try engine(gate: gate); defer { engine.shutdown() }
        engine.playSongs([song])
        engine.pause()
        await gate.open()
        try await waitFor("paused item failed to prepare") { engine.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.player.rate, 0)
        XCTAssertTrue(engine.nowPlayingSession?.remoteCommandCenter.playCommand.isEnabled == true)
    }

    func testMediaResetRebindsSessionAndRetiresOldControls() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        let old = try XCTUnwrap(engine.nowPlayingSession)
        let oldPlayer = engine.player
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await waitFor("media reset did not replace the session") { engine.nowPlayingSession !== old }
        let next = try XCTUnwrap(engine.nowPlayingSession)
        XCTAssertFalse(oldPlayer === engine.player)
        // Retain the old session deliberately; its player lifetime belongs to
        // that session. Publishing/controls must be retired without removePlayer.
        XCTAssertFalse(old.automaticallyPublishesNowPlayingInfo)
        XCTAssertNil(old.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(old.remoteCommandCenter.playCommand.isEnabled)
        XCTAssertEqual(next.players.count, 1)
        XCTAssertTrue(next.players.first === engine.player)
        engine.shutdown()
        XCTAssertNil(engine.nowPlayingSession)
        XCTAssertNil(next.nowPlayingInfoCenter.nowPlayingInfo)
        XCTAssertFalse(next.remoteCommandCenter.playCommand.isEnabled)
    }

    func testProgressAndForegroundKeepContinuousSystemSession() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        try await queue(engine)
        let session = try XCTUnwrap(engine.nowPlayingSession)
        let player = engine.player
        engine.play()
        try await waitFor("native player did not start") { engine.isPlaying }
        try await Task.sleep(nanoseconds: 150_000_000)
        let writes = engine.itemMetadataUpdateCount
        let start = engine.position
        try await Task.sleep(nanoseconds: 1_200_000_000)
        for _ in 0..<10 { engine.publish() }
        XCTAssertGreaterThan(engine.position, start)
        XCTAssertEqual(engine.itemMetadataUpdateCount, writes)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.itemMetadataUpdateCount, writes)
        XCTAssertTrue(engine.player === player)
        XCTAssertTrue(engine.nowPlayingSession === session)
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
        try await waitFor("native pause was not automatically published") {
            self.systemNumber(session, MPNowPlayingInfoPropertyPlaybackRate) == 0
        }
        XCTAssertEqual(engine.itemMetadataUpdateCount, writes)
        engine.seek(0.5)
        try await waitFor("native paused seek was not automatically published") {
            guard let elapsed = self.systemNumber(session, MPNowPlayingInfoPropertyElapsedPlaybackTime) else { return false }
            return abs(elapsed - 0.5) < 0.1
        }
        XCTAssertEqual(engine.itemMetadataUpdateCount, writes)
        XCTAssertEqual(engine.player.rate, 0)
    }

    func testImmediateTrackChangePublishesMatchingIdentityBeforeKVOHop() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        try await queue(engine)
        var next = song; next.id = "next"; next.name = "Next fixture"
        engine.append(next)
        engine.setMode(loop: "none", order: "list")
        try await waitFor("next item failed to preload") { engine.player.items().count == 2 }
        let session = try XCTUnwrap(engine.nowPlayingSession)
        let upcoming = try XCTUnwrap(engine.player.items().last)
        XCTAssertEqual(upcoming.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, next.name)
        engine.skip(1)
        engine.publish() // Deliberately no await: currentItem KVO is still queued.
        XCTAssertEqual(engine.index, 1)
        let info = try XCTUnwrap(engine.player.currentItem?.nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, next.name)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, "fixture:next")
        XCTAssertEqual((info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? NSNumber)?.intValue, 1)
        XCTAssertTrue(engine.nowPlayingSession === session)
    }

    func testRepeatedTrackRestartsSystemTimelineWithoutReplacingSession() async throws {
        let engine = try engine(); defer { engine.shutdown() }
        try await queue(engine)
        try await waitFor("repeat item did not preload") { engine.player.items().count >= 2 }
        let item = try XCTUnwrap(engine.player.currentItem)
        let session = try XCTUnwrap(engine.nowPlayingSession)
        engine.seek(0.5)
        try await waitFor("initial seek failed") { abs(engine.player.currentTime().seconds - 0.5) < 0.1 }
        engine.skip(1)
        engine.publish()
        XCTAssertFalse(engine.player.currentItem === item)
        try await waitFor("repeated item did not reset the native timeline") {
            guard let elapsed = self.systemNumber(session, MPNowPlayingInfoPropertyElapsedPlaybackTime) else { return false }
            return abs(elapsed) < 0.1
        }
        XCTAssertTrue(engine.nowPlayingSession === session)
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
        model.sceneBecameActive()
        XCTAssertFalse(model.showPlayer)
        model.sceneEnteredBackground()
        engine.stop()
        model.sceneBecameActive()
        XCTAssertFalse(model.showPlayer)
    }
}
