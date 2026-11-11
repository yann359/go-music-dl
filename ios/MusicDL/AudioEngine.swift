import AVFoundation
import Combine
import MediaPlayer
import UIKit
import SwiftUI

/// The only playback owner. No WebView, JavaScript timer, or HTTP loopback
/// connection is used by the queue, remote controls, or interruption recovery.
@MainActor
final class AudioEngine: NSObject, ObservableObject, MPNowPlayingSessionDelegate {
    enum PlaybackState: String { case idle, preparing, ready, playing, paused, buffering, interrupted, recovering, error }
    @Published private(set) var playbackState: PlaybackState = .idle
    private var playbackError: String?
    private var recoveryAttempts = 0
    private var recoveryWatchdog: Task<Void, Never>?
    private var savedPosition: Double = 0
    private(set) var player = AVQueuePlayer()
    @Published private(set) var message = "原生播放器就绪"
    var stateDidChange: (([String: Any]) -> Void)?
    private let files: AudioFiles
    @Published private(set) var songs: [Song] = []
    @Published private(set) var index = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var waiting = false
    var currentSong: Song? { songs.indices.contains(index) ? songs[index] : nil }
    var playbackRate: Float { speed }
    var loopMode: String { loop }
    var orderMode: String { order }
    private var loop = "all"
    private var order = "list"
    private var sequence: [Int] = []
    private var itemIndices: [ObjectIdentifier: Int] = [:]
    private var itemSources: [ObjectIdentifier: String] = [:]
    private var failedFallbacks = Set<String>()
    private var revision = 0
    private var pipeline: Task<Void, Never>?
    private var wantsPlayback = false
    private var interrupted = false
    private var resumeAfterInterruption = false
    private var speed: Float = 1
    private var ticker: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []
    private static let liveEngines = NSHashTable<AudioEngine>.weakObjects()
    private let ownedSessions = NSHashTable<MPNowPlayingSession>.weakObjects()
    private var recentMetadataWrites: [TimeInterval] = []
    private var activationEvidence = "尚无本 App 的音频激活记录"
    private var audioSessionFailure: NSError?
    private var audioSessionFailureOperation = ""
    @Published private(set) var isRepairingMedia = false
    @Published private(set) var mediaRepairReport: MediaRepairReport?
    var registeredRemoteCommandCount: Int { commands.count }
    private(set) var nowPlayingSession: MPNowPlayingSession?
    private(set) var itemMetadataUpdateCount = 0
    private(set) var audioActivationCount = 0
    private var sessionID = ""
    private var shuttingDown = false
    private let engineID = UUID().uuidString
    private var preparing = false
    private var preparationTask: UIBackgroundTaskIdentifier = .invalid
    private var preparationTaskGeneration = 0
    var hasPreparationBackgroundTask: Bool { preparationTask != .invalid }
    private var artwork: MPMediaItemArtwork?
    private var artworkKey = ""
    private var artworkTask: Task<Void, Never>?
    private var pendingSeek: (item: AVPlayerItem, seconds: Double)?
    private var seekRevision = 0

    init(files: AudioFiles = AudioFiles()) {
        self.files = files
        super.init()
        Self.liveEngines.add(self)
        installPlayerObservers()
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.interruption($0) }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.routeChanged($0) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in self?.resetMediaServices() }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.foregrounded() }
        observe(.AVPlayerItemDidPlayToEndTime) { [weak self] note in self?.didEnd(note) }
        installNowPlayingSession()
    }

    private func installPlayerObservers() {
        player.actionAtItemEnd = .advance
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.publish()
                self?.recordMediaEvent("player-time-control-changed")
            }
        })
        observations.append(player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.publish() }
        })
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor (Notification) -> Void) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            Task { @MainActor in handler(note) }
        })
    }

    func handle(_ request: PlaybackRequest) {
        switch request.action {
        case "queue":
            guard let incoming = request.songs, incoming.count <= 10000 else { return }
            if incoming.isEmpty { stop(); return }
            let selected = request.index ?? 0
            guard incoming.isEmpty || incoming.indices.contains(selected) else { return }
            let sameCurrent = !songs.isEmpty && !incoming.isEmpty && songs.indices.contains(index)
                && songs[index] == incoming[selected] && player.currentItem != nil
            let changed = incoming != songs || selected != index || request.loop != loop || request.order != order
            guard changed else { return }
            songs = incoming; index = selected
            if !sameCurrent { savedPosition = 0; recoveryAttempts = 0 }
            loop = ["all", "one", "none"].contains(request.loop ?? "") ? request.loop! : "all"
            order = request.order == "random" ? "random" : "list"
            failedFallbacks.removeAll()
            rebuild(keepingCurrent: sameCurrent)
        case "play": play()
        case "pause": pause()
        case "stop": stop()
        case "next": skip(1)
        case "previous": skip(-1)
        case "seek": seek(request.value ?? 0)
        case "rate":
            speed = Float(min(3, max(0.25, request.value ?? 1)))
            startPreparedPlayback()
            publish()
        case "volume": player.volume = Float(min(1, max(0, request.value ?? 1)))
        case "state": publish(includeQueue: true)
        default: break
        }
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            audioSessionFailure = nil
            audioActivationCount += 1
            activationEvidence = "上次激活调用成功；不是实时激活状态查询"
            recordMediaEvent("audio-activated")
        } catch {
            audioSessionFailure = error as NSError
            audioSessionFailureOperation = "音频配置或激活"
            activationEvidence = "最近的音频配置或激活调用失败"
            recordMediaEvent("audio-activation-failed", extra: ["error_code": String((error as NSError).code)])
            throw error
        }
    }

    func playSongs(_ items: [Song], at selected: Int = 0) {
        guard items.indices.contains(selected) else { return }
        handle(PlaybackRequest(action: "queue", songs: items, index: selected, loop: loop, order: order))
        play()
    }

    func append(_ song: Song, playNext: Bool = false) {
        var updated = songs
        updated.insert(song, at: playNext && !updated.isEmpty ? min(index + 1, updated.count) : updated.count)
        handle(PlaybackRequest(action: "queue", songs: updated, index: index, loop: loop, order: order))
    }

    func replaceCurrentSource(_ song: Song, expectedKey: String) {
        guard currentSong?.key == expectedKey, songs.indices.contains(index) else { return }
        let elapsed = player.currentTime().seconds
        let seconds = pendingSeek?.seconds ?? (elapsed.isFinite ? elapsed : position)
        songs[index] = song
        failedFallbacks.removeAll()
        rebuild(keepingCurrent: false, position: seconds)
    }

    func remove(at offsets: IndexSet) {
        let selected = currentSong
        var updated = songs; updated.remove(atOffsets: offsets)
        let next = selected.flatMap { song in updated.firstIndex(where: { $0.key == song.key }) } ?? min(index, max(0, updated.count - 1))
        handle(PlaybackRequest(action: "queue", songs: updated, index: next, loop: loop, order: order))
    }

    func move(from offsets: IndexSet, to destination: Int) {
        let selected = currentSong
        var updated = songs; updated.move(fromOffsets: offsets, toOffset: destination)
        let next = selected.flatMap { song in updated.firstIndex(where: { $0.key == song.key }) } ?? 0
        handle(PlaybackRequest(action: "queue", songs: updated, index: next, loop: loop, order: order))
    }

    func setMode(loop: String, order: String) {
        handle(PlaybackRequest(action: "queue", songs: songs, index: index, loop: loop, order: order))
        objectWillChange.send()
    }

    func play() {
        guard !songs.isEmpty else { return }
        // Explicit intent supersedes an unmatched old interruption. Actual
        // audio-session activation is checked below when media is ready.
        interrupted = false; resumeAfterInterruption = false
        playbackError = nil
        wantsPlayback = true
        let missingFile = (player.currentItem?.asset as? AVURLAsset).map { $0.url.isFileURL && !FileManager.default.fileExists(atPath: $0.url.path) } ?? false
        if player.status == .failed || player.currentItem?.status == .failed || missingFile {
            recreatePlayer()
        } else if player.currentItem == nil && !preparing {
            rebuild(keepingCurrent: false, position: savedPosition)
        }
        beginPreparationBackgroundTask()
        startPreparedPlayback()
        publish()
        recordMediaEvent("play-requested")
    }

    private func startPreparedPlayback() {
        // rate > 0 on an empty player is a future playback request, not audio
        // playback. Keep the intent local until there is a real, ready item.
        guard wantsPlayback, !interrupted, pendingSeek == nil,
              player.currentItem?.status == .readyToPlay else { return }
        // A positive requested rate may briefly be waiting for output. Do not
        // reactivate audio for each preloaded item during that same request.
        if player.rate != speed {
            do {
                if player.rate == 0 { try activate() }
                player.playImmediately(atRate: speed)
            } catch { fail("暂时无法恢复音频，请稍后点击播放重试。"); return }
        }
        watchRecovery()
        endPreparationBackgroundTask()
    }

    private func beginPreparationBackgroundTask() {
        guard wantsPlayback, !interrupted, player.currentItem?.status != .readyToPlay,
              preparationTask == .invalid else { return }
        preparationTaskGeneration += 1
        let token = preparationTaskGeneration
        preparationTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare native playback") { [weak self] in
            // UIKit guarantees this handler runs synchronously on the main
            // thread. End the task before returning, not in a deferred Task.
            MainActor.assumeIsolated {
                guard let self, self.preparationTaskGeneration == token, self.preparationTask != .invalid else { return }
                self.endPreparationBackgroundTask()
                self.revision += 1; self.pipeline?.cancel(); self.preparing = false; self.sequence.removeAll()
                self.fail("后台音频准备超时，请返回 App 后点击播放重试。")
                self.recordMediaEvent("background-preparation-expired")
            }
        }
        recordMediaEvent("background-preparation-began")
    }

    private func endPreparationBackgroundTask() {
        guard preparationTask != .invalid else { return }
        let task = preparationTask; preparationTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
        recordMediaEvent("background-preparation-ended")
    }

    func pause() {
        endPreparationBackgroundTask()
        rememberPosition()
        recoveryWatchdog?.cancel(); recoveryWatchdog = nil; recoveryAttempts = 0
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause()
        publish()
        recordMediaEvent("audio-paused")
    }

    func stop() {
        pause(); revision += 1; pipeline?.cancel(); preparing = false
        nowPlayingSession?.automaticallyPublishesNowPlayingInfo = false
        player.removeAllItems(); itemIndices.removeAll(); itemSources.removeAll()
        songs = []; sequence = []; index = 0; savedPosition = 0; playbackError = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionFailure = nil
            activationEvidence = "上次停用调用成功"
        } catch {
            audioSessionFailure = error as NSError
            audioSessionFailureOperation = "音频停用"
            activationEvidence = "最近的音频停用调用失败"
        }
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
        artworkTask?.cancel(); artwork = nil; artworkKey = ""
        let token = revision
        Task { await files.prune(keeping: [], generation: token) }
        publish()
        recordMediaEvent("audio-stopped")
    }

    func shutdown() {
        guard !shuttingDown else { return }
        stop()
        shuttingDown = true
        Self.liveEngines.remove(self)
        if let ticker { player.removeTimeObserver(ticker); self.ticker = nil }
        observations.removeAll(); itemObservation = nil
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        removeNowPlayingSession()
        stateDidChange = nil
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, let item = player.currentItem else { return }
        pendingSeek = (item, max(0, seconds))
        applyPendingSeek(for: item)
    }

    private func applyPendingSeek(for item: AVPlayerItem) {
        guard item === player.currentItem, item.status == .readyToPlay,
              let pending = pendingSeek, pending.item === item else { return }
        let duration = item.duration.seconds
        let target = max(0, duration.isFinite && duration > 0 ? min(pending.seconds, duration) : pending.seconds)
        seekRevision += 1; let token = seekRevision
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, token == self.seekRevision, item === self.player.currentItem else { return }
                self.pendingSeek = nil
                self.startPreparedPlayback()
                self.publish()
                self.recordMediaEvent(finished ? "seek-completed" : "seek-cancelled")
            }
        }
    }

    func skip(_ direction: Int) {
        guard !songs.isEmpty else { return }
        if direction < 0 && player.currentTime().seconds > 3 { seek(0); return }
        if direction > 0, player.items().count > 1 {
            player.advanceToNextItem()
            return
        }
        if direction > 0, order == "random", songs.count > 1 {
            index = songs.indices.filter { $0 != index }.randomElement() ?? index
        } else { index = (index + direction + songs.count) % songs.count }
        rebuild(keepingCurrent: false)
    }

    private func nextIndex(after current: Int) -> Int? {
        if loop == "one" { return current }
        if order == "random" { return songs.indices.filter { $0 != current }.randomElement() ?? current }
        if current + 1 < songs.count { return current + 1 }
        return loop == "all" ? 0 : nil
    }

    private func rebuild(keepingCurrent: Bool, position: Double = 0, forceFallback: Bool = false) {
        recoveryWatchdog?.cancel(); recoveryWatchdog = nil
        playbackError = nil
        revision += 1; pipeline?.cancel(); preparing = false
        let current = keepingCurrent ? player.currentItem : nil
        if current == nil { pendingSeek = nil; seekRevision += 1; savedPosition = max(0, position) }
        let currentSource = current.flatMap { itemSources[ObjectIdentifier($0)] }
        for item in player.items() where item !== current { player.remove(item) }
        itemIndices = [:]; itemSources = [:]
        if let current {
            itemIndices[ObjectIdentifier(current)] = index
            itemSources[ObjectIdentifier(current)] = currentSource
        }
        sequence = current == nil && !songs.isEmpty ? [index] : []
        var cursor = index
        for _ in 0..<2 {
            guard !songs.isEmpty, let next = nextIndex(after: cursor) else { break }
            sequence.append(next); cursor = next
        }
        beginPreparationBackgroundTask()
        fill(position: position, forceFallback: forceFallback)
    }

    private func fill(position: Double = 0, forceFallback: Bool = false) {
        guard !preparing && !sequence.isEmpty else { return }
        preparing = true
        let token = revision
        pipeline = Task { [weak self] in
            guard let self else { return }
            await self.files.beginGeneration(token)
            guard self.revision == token && !Task.isCancelled else { return }
            defer {
                if self.revision == token {
                    self.preparing = false
                    let keep = Set(self.player.items().compactMap { self.itemIndices[ObjectIdentifier($0)] }
                        .map { self.songs[$0].key })
                    Task { await self.files.prune(keeping: keep, generation: token) }
                }
            }
            var first = true
            while !self.sequence.isEmpty && self.revision == token && !Task.isCancelled {
                let next = self.sequence.removeFirst()
                guard self.songs.indices.contains(next) else { break }
                let song = self.songs[next]
                do {
                    let prepared: AudioFiles.Prepared
                    do { prepared = try await self.files.prepare(song, fallback: first && forceFallback) }
                    catch {
                        if Task.isCancelled { return }
                        if (first && forceFallback) || song.source == "local" || song.source == "local-file" { throw error }
                        prepared = try await self.files.prepare(song, fallback: true)
                    }
                    guard self.revision == token && !Task.isCancelled else { return }
                    if prepared.source != song.source { self.failedFallbacks.insert(song.key) }
                    let item = AVPlayerItem(url: prepared.url)
                    self.itemIndices[ObjectIdentifier(item)] = next
                    self.itemSources[ObjectIdentifier(item)] = prepared.source
                    self.updateItemMetadata(item, at: next)
                    guard self.player.canInsert(item, after: self.player.items().last) else {
                        throw NativeError.message("无法加入原生播放队列")
                    }
                    self.player.insert(item, after: self.player.items().last)
                    if self.nowPlayingSession?.automaticallyPublishesNowPlayingInfo == false {
                        self.nowPlayingSession?.automaticallyPublishesNowPlayingInfo = true
                    }
                    if first && position > 0 { self.seek(position) }
                    self.startPreparedPlayback()
                    self.message = prepared.source == song.source
                        ? "原生音频已缓存 · 队列就绪 \(self.player.items().count) 首"
                        : "已自动换源：\(song.source) → \(prepared.source) · 已缓存"
                    self.publish()
                } catch {
                    guard self.revision == token && !Task.isCancelled else { return }
                    self.message = "\(song.name) 准备失败：\(error.localizedDescription)"
                    // Stop at a failed item; do not silently play a different song.
                    self.sequence.removeAll()
                    if self.player.currentItem == nil { self.fail(self.message + "；点击播放重试。") }
                    self.publish()
                    break
                }
                first = false
            }
        }
    }

    private func currentItemChanged() {
        itemObservation = nil
        guard let item = player.currentItem, let selected = itemIndices[ObjectIdentifier(item)] else { publish(); return }
        index = selected
        if let pending = pendingSeek, pending.item !== item {
            pendingSeek = nil; seekRevision += 1
        }
        if pendingSeek == nil { savedPosition = 0 }
        loadArtwork()
        let activeIDs = Set(player.items().map(ObjectIdentifier.init))
        itemIndices = itemIndices.filter { activeIDs.contains($0.key) }
        itemSources = itemSources.filter { activeIDs.contains($0.key) }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                if item.status == .failed { self.itemFailed(item) }
                else if item.status == .readyToPlay {
                    self.applyPendingSeek(for: item)
                    self.startPreparedPlayback()
                    self.publish()
                    self.recordMediaEvent("player-item-ready")
                }
            }
        }
        // A native preloaded queue bridges track boundaries even while WKWebView sleeps.
        if !preparing && player.items().count < 3, let last = player.items().last,
           let lastIndex = itemIndices[ObjectIdentifier(last)], let next = nextIndex(after: lastIndex) {
            sequence.append(next); fill()
        }
        publish()
        recordMediaEvent("player-item-changed")
    }

    private func itemFailed(_ item: AVPlayerItem) {
        guard item === player.currentItem, songs.indices.contains(index) else { return }
        let key = songs[index].key
        guard !failedFallbacks.contains(key) else { fail("原生解码及换源均失败，请手动选择其他音源"); return }
        failedFallbacks.insert(key)
        let position = player.currentTime().seconds
        message = "音源不可播放，正在尝试换源"
        rebuild(keepingCurrent: false, position: position.isFinite ? position : 0, forceFallback: true)
    }

    private func didEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, itemIndices[ObjectIdentifier(item)] != nil else { return }
        // KVO may already have delivered the next item. Only finish an exhausted queue.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player.currentItem == nil, !self.preparing else { return }
            self.wantsPlayback = false; self.publish()
        }
    }

    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            endPreparationBackgroundTask()
            rememberPosition()
            recoveryWatchdog?.cancel(); recoveryWatchdog = nil
            resumeAfterInterruption = wantsPlayback
            interrupted = true; player.pause(); publish()
            activationEvidence = "已收到系统音频中断，未主动重新激活"
            recordMediaEvent("interruption-began")
        } else {
            interrupted = false
            activationEvidence = "系统音频中断已结束，等待正常播放流程"
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            let resume = resumeAfterInterruption && wantsPlayback && shouldResume
            resumeAfterInterruption = false
            if resume { play() } else { pause() }
            recordMediaEvent("interruption-ended")
        }
    }

    private func routeChanged(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
    }

    private func resetMediaServices() {
        rememberPosition()
        activationEvidence = "媒体服务已重置，原激活记录不再代表当前状态"
        audioSessionFailure = nil
        interrupted = false; resumeAfterInterruption = false
        recreatePlayer()
        if wantsPlayback { play() }
    }

    private func rememberPosition() {
        if let pendingSeek { savedPosition = pendingSeek.seconds; return }
        guard player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savedPosition = max(0, seconds) }
    }

    private func foregrounded() {
        // Never start paused music just because the user opened the app.
        rememberPosition()
        if wantsPlayback && !interrupted { watchRecovery() }
        publish(includeQueue: true)
    }

    private func recreatePlayer() {
        recoveryWatchdog?.cancel(); recoveryWatchdog = nil
        rememberPosition()
        if let ticker { player.removeTimeObserver(ticker); self.ticker = nil }
        observations.removeAll(); itemObservation = nil
        player.pause()
        removeNowPlayingSession()
        player = AVQueuePlayer()
        installNowPlayingSession()
        installPlayerObservers()
        rebuild(keepingCurrent: false, position: savedPosition)
    }

    private func watchRecovery() {
        guard recoveryWatchdog == nil, wantsPlayback, !interrupted, player.currentItem != nil else { return }
        let token = revision
        let initialItem = player.currentItem
        let initialPosition = player.currentTime().seconds
        recoveryWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, token == self.revision, self.wantsPlayback, !self.interrupted else { return }
            self.recoveryWatchdog = nil
            let advanced = self.player.currentItem !== initialItem || self.player.currentTime().seconds > initialPosition + 0.05
            if self.player.timeControlStatus == .playing && advanced { self.recoveryAttempts = 0; return }
            guard self.recoveryAttempts < 1 else { self.fail("播放恢复失败，请点击播放重试，或手动更换音源。"); return }
            self.recoveryAttempts += 1
            do {
                try self.activate()
                self.message = "正在恢复原生播放与进度…"
                self.recreatePlayer()
                self.publish()
            } catch { self.fail("音频暂不可用，请点击播放重试。") }
        }
    }

    private func fail(_ text: String) { pause(); playbackError = text; message = text; publish() }

    private func loadArtwork() {
        guard let song = currentSong, artworkKey != song.key else { return }
        artworkKey = song.key; artwork = nil; artworkTask?.cancel()
        guard let url = CoverArt.imageURL(song.cover) else { return }
        let key = song.key
        artworkTask = Task { [weak self] in
            guard let self else { return }
            // Artwork is optional; it never participates in audio preparation.
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               data.count <= 12 * 1024 * 1024, let image = UIImage(data: data),
               !Task.isCancelled, self.currentSong?.key == key {
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publish()
            }
        }
    }

    private func installNowPlayingSession() {
        let session = MPNowPlayingSession(players: [player])
        // A single session is selected by the system as the default session.
        // Explicit promotion is for choosing among multiple app sessions, not
        // for requesting Dynamic Island presentation when playback starts.
        // The system derives duration, elapsed time and rate from the actual
        // player. Titles/artwork belong to each item, including preloaded ones.
        session.automaticallyPublishesNowPlayingInfo = true
        session.delegate = self
        nowPlayingSession = session
        ownedSessions.add(session)
        sessionID = UUID().uuidString
        configureRemoteCommands(session.remoteCommandCenter)
        recordMediaEvent("session-created")
    }

    private func removeNowPlayingSession() {
        for (command, target) in commands { command.removeTarget(target); command.isEnabled = false }
        commands.removeAll()
        guard let session = nowPlayingSession else { return }
        session.delegate = nil
        session.automaticallyPublishesNowPlayingInfo = false
        session.nowPlayingInfoCenter.nowPlayingInfo = nil
        // This entire session is being retired, not edited in place. Let its
        // lifetime own its KVO teardown. Removing every player first caused a
        // reproducible duplicate currentItem-observer removal on iOS 26.5.
        nowPlayingSession = nil
    }

    func recordMediaEvent(_ event: String, command: String? = nil, extra: [String: String] = [:]) {
        let session = AVAudioSession.sharedInstance()
        var fields: [String: String] = [
            "engine": engineID,
            "session": sessionID,
            "session_active": String(nowPlayingSession?.isActive ?? false),
            "can_become_active": String(nowPlayingSession?.canBecomeActive ?? false),
            "session_players": String(nowPlayingSession?.players.count ?? 0),
            "registered_commands": String(commands.count),
            "enabled_commands": String(commands.filter { $0.0.isEnabled }.count),
            "metadata_mode": "player-auto",
            "item_metadata_updates": String(itemMetadataUpdateCount),
            "audio_activations": String(audioActivationCount),
            "item_present": String(player.currentItem != nil),
            "item_status": String(player.currentItem?.status.rawValue ?? -1),
            "time_control_status": String(player.timeControlStatus.rawValue),
            "elapsed": String(player.currentTime().seconds),
            "wants_playback": String(wantsPlayback),
            "background_preparation": String(hasPreparationBackgroundTask),
            "item_metadata_present": String(player.currentItem?.nowPlayingInfo != nil),
            "queue_count": String(songs.count),
            "state": playbackState.rawValue,
            "rate": String(player.rate),
            "category": session.category.rawValue,
            "mixing": String(session.categoryOptions.contains(.mixWithOthers)),
            "app_state": String(UIApplication.shared.applicationState.rawValue),
            "scene_states": UIApplication.shared.connectedScenes.map { String($0.activationState.rawValue) }.sorted().joined(separator: ",")
        ]
        if let command { fields["command"] = command }
        fields.merge(extra) { _, new in new }
        MediaSessionDiagnostics.record(event, fields: fields)
    }

    nonisolated func nowPlayingSessionDidChangeActive(_ session: MPNowPlayingSession) {
        Task { @MainActor [weak self] in
            guard let self, self.nowPlayingSession === session else { return }
            self.recordMediaEvent("ownership-changed")
        }
    }

    nonisolated func nowPlayingSessionDidChangeCanBecomeActive(_ session: MPNowPlayingSession) {
        Task { @MainActor [weak self] in
            guard let self, self.nowPlayingSession === session else { return }
            self.recordMediaEvent("eligibility-changed")
        }
    }

    // Idempotent registration: retain and remove only our own opaque tokens.
    // Public MediaPlayer APIs cannot enumerate handlers installed elsewhere.
    func configureRemoteCommands(_ center: MPRemoteCommandCenter) {
        let expected = remoteCommands(center)
        let actualIDs = commands.map { ObjectIdentifier($0.0) }
        if actualIDs.count == expected.count && Set(actualIDs) == Set(expected.map(ObjectIdentifier.init)) { return }
        for (command, target) in commands { command.removeTarget(target) }
        commands.removeAll()
        func bind(_ command: MPRemoteCommand, name: String, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = false
            let token = command.addTarget { [weak self] _ in
                guard self != nil else { return .commandFailed }
                Task { @MainActor [weak self] in
                    guard let self, self.player.currentItem != nil, !self.shuttingDown else { return }
                    self.recordMediaEvent("remote-command", command: name)
                    action()
                }
                return .success
            }
            commands.append((command, token))
        }
        bind(center.playCommand, name: "play") { [weak self] in self?.play() }
        bind(center.pauseCommand, name: "pause") { [weak self] in self?.pause() }
        bind(center.togglePlayPauseCommand, name: "toggle") { [weak self] in
            guard let self else { return }; self.wantsPlayback ? self.pause() : self.play()
        }
        bind(center.nextTrackCommand, name: "next") { [weak self] in self?.skip(1) }
        bind(center.previousTrackCommand, name: "previous") { [weak self] in self?.skip(-1) }
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.recordMediaEvent("remote-command", command: "seek")
                self?.seek(event.positionTime)
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = false
        commands.append((center.changePlaybackPositionCommand, token))
    }

    private func remoteCommands(_ center: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
         center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand]
    }

    private func updateItemMetadata(_ item: AVPlayerItem, at selected: Int) {
        guard let information = itemMetadata(item, at: selected) else { return }
        guard item.nowPlayingInfo.map({ $0 as NSDictionary })?.isEqual(information as NSDictionary) != true else { return }
        item.nowPlayingInfo = information
        itemMetadataUpdateCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        recentMetadataWrites.removeAll { now - $0 > 10 }
        recentMetadataWrites.append(now)
        if recentMetadataWrites.count > 128 { recentMetadataWrites.removeFirst(recentMetadataWrites.count - 128) }
    }

    private func itemMetadata(_ item: AVPlayerItem, at selected: Int) -> [String: Any]? {
        guard songs.indices.contains(selected) else { return nil }
        let song = songs[selected]
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: song.name, MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: selected,
            MPNowPlayingInfoPropertyPlaybackQueueCount: songs.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExternalContentIdentifier: song.source + ":" + song.id
        ]
        if item === player.currentItem, artworkKey == song.key, let artwork {
            information[MPMediaItemPropertyArtwork] = artwork
        }
        return information
    }

    func publish(includeQueue: Bool = false) {
        guard !shuttingDown else { return }
        // KVO callbacks hop to MainActor. A rate/timer callback can arrive before
        // currentItemChanged, so read track identity from the same player item
        // as its timing instead of briefly publishing the previous track.
        if let item = player.currentItem, let selected = itemIndices[ObjectIdentifier(item)] {
            index = selected
        }
        if currentSong?.key != artworkKey { loadArtwork() }
        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        let position = elapsed.isFinite ? max(0, elapsed) : savedPosition
        let length = duration.isFinite ? max(0, duration) : 0
        let playing = player.timeControlStatus == .playing
        self.position = position; self.duration = length; self.isPlaying = playing
        self.waiting = wantsPlayback && !playing && !interrupted
        if songs.isEmpty { playbackState = .idle }
        else if playbackError != nil { playbackState = .error }
        else if interrupted { playbackState = .interrupted }
        else if playing { playbackState = .playing; recoveryAttempts = 0 }
        else if recoveryAttempts > 0 { playbackState = .recovering }
        else if player.currentItem == nil && preparing { playbackState = .preparing }
        else if wantsPlayback { playbackState = .buffering }
        else { playbackState = player.currentItem?.status == .readyToPlay ? .paused : .ready }
        for item in player.items() {
            if let selected = itemIndices[ObjectIdentifier(item)] { updateItemMetadata(item, at: selected) }
        }
        for (command, _) in commands { command.isEnabled = player.currentItem != nil }
        var state: [String: Any] = ["index": index, "position": position, "duration": length,
                         "playing": playing, "waiting": wantsPlayback && !playing && !interrupted,
                         "rate": speed, "message": message, "readyCount": player.items().count,
                         "loop": loop, "order": order, "state": playbackState.rawValue]
        if includeQueue {
            state["songs"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(songs))) ?? []
        }
        if let current = player.currentItem { state["activeSource"] = itemSources[ObjectIdentifier(current)] }
        stateDidChange?(state)
    }
}

extension AudioEngine {
    /// An explicit, bounded reconciliation. Never calls play/pause/seek,
    /// setActive, removePlayer, or rebuild, including on the error paths.
    @discardableResult
    func detectAndRepairMediaState() async -> MediaRepairReport {
        var report = MediaRepairReport()
        guard !isRepairingMedia else {
            report.errors = ["已有检测正在进行，请等待完成后重新检测。"]
            return report
        }
        isRepairingMedia = true
        recordMediaEvent("repair-started")
        defer {
            mediaRepairReport = report
            isRepairingMedia = false
            recordMediaEvent(report.errors.isEmpty ? "repair-completed" : "repair-failed", extra: [
                "findings": String(report.findings.count), "repairs": String(report.repairs.count),
                "errors": String(report.errors.count)
            ])
        }
        func check(_ id: String, _ title: String, _ detail: String, _ status: MediaRepairCheck.Status = .normal) {
            report.checks.append(MediaRepairCheck(id: id, title: title, detail: detail, status: status))
            recordMediaEvent("repair-check", extra: ["check": id, "result": String(describing: status)])
        }
        func repaired(_ code: String, _ detail: String) {
            report.repairs.append(detail)
            recordMediaEvent("repair-action", extra: ["action": code])
        }
        guard !shuttingDown else {
            report.errors.append("播放引擎已关闭，无法同步。请重新进入 App 后检测。")
            return report
        }
        let audioSession = AVAudioSession.sharedInstance()
        let configured = audioSession.category == .playback && audioSession.mode == .default
            && audioSession.routeSharingPolicy == .longFormAudio
            && !audioSession.categoryOptions.contains(.mixWithOthers)
        let notConfiguredYet = audioActivationCount == 0 && player.rate == 0 && audioSessionFailure == nil
        if !configured && !notConfiguredYet {
            report.findings.append("音频配置偏离本 App 的后台媒体播放配置。为避免切换音频线路或中断歌曲，本次保留现状；下次手动播放会应用正常配置。")
        }
        check("audio-session", "音频配置与激活记录",
              notConfiguredYet ? "尚未开始实际音频播放，按原流程在就绪时配置与激活。" :
                "\(configured ? "后台媒体播放配置符合预期" : "配置偏离预期，未强行改动")；\(activationEvidence)。输出线路数：\(audioSession.currentRoute.outputs.count)。",
              (configured || notConfiguredYet) && audioSessionFailure == nil ? .normal : .attention)
        if let failure = audioSessionFailure {
            report.errors.append("最近的\(audioSessionFailureOperation)调用失败：\(failure.localizedDescription)（\(failure.domain)，\(failure.code)）。本次没有强行激活或停用，请通过正常播放入口重试后重新检测。")
        }
        if interrupted { report.findings.append("当前处于系统音频中断；没有自动抢占音频或恢复播放。") }
        let engineFailed = player.status == .failed || player.currentItem?.status == .failed || playbackError != nil
        check("engine", "播放引擎与音频中断",
              "播放器：\(engineFailed ? "错误" : player.currentItem == nil ? "暂无播放项" : player.currentItem?.status == .readyToPlay ? "媒体就绪" : "媒体准备中")；\(interrupted ? "中断中" : "未记录到进行中的中断")。",
              interrupted || engineFailed ? .attention : .normal)
        if engineFailed {
            let detail = player.currentItem?.error?.localizedDescription ?? player.error?.localizedDescription ?? playbackError ?? "系统未提供错误详情"
            report.errors.append("播放引擎报告错误：\(detail)。本次没有替换播放器，请使用播放器的重试入口。")
            let nativeError = (player.currentItem?.error ?? player.error) as NSError?
            recordMediaEvent("repair-engine-error", extra: ["error_code": String(nativeError?.code ?? -1)])
        }

        if nowPlayingSession == nil {
            report.findings.append("当前播放器缺少媒体会话。")
            installNowPlayingSession() // Same player, same items and timebase.
            repaired("missing-session", "已将媒体会话重新绑定现有播放器，保留播放进度与队列。")
        }
        guard let session = nowPlayingSession else {
            report.errors.append("未能建立媒体会话，请重新检测。")
            return report
        }
        let engineCount = Self.liveEngines.allObjects.filter { !$0.shuttingDown }.count
        if engineCount > 1 { report.findings.append("App 内存在\(engineCount)个存活播放引擎；无法确认其他引擎的用途，未自动停止或清理。") }
        let playerBindingValid = session.players.count == 1 && session.players.first === player
        if !playerBindingValid { report.errors.append("媒体会话关联的播放器数量或身份异常；为避免中断播放，未移除或重建播放器。") }
        for old in ownedSessions.allObjects where old !== session {
            // Only previously owned, retired sessions with no active player.
            // Never touch the current player or another live engine's session.
            guard old.players.allSatisfy({ $0 !== player && $0.rate == 0 }),
                  old.automaticallyPublishesNowPlayingInfo || old.nowPlayingInfoCenter.nowPlayingInfo != nil else { continue }
            old.automaticallyPublishesNowPlayingInfo = false
            old.nowPlayingInfoCenter.nowPlayingInfo = nil
            report.findings.append("发现本引擎已退休且未播放的旧媒体会话仍在发布信息。")
            repaired("retired-session", "已关闭本引擎闲置旧会话的信息发布，未移除播放器或停止其他音频。")
        }
        check("sessions", "媒体会话与活动范围",
              "本 App 存活引擎\(engineCount)个；当前会话关联播放器\(session.players.count)个。当前版本未接入 Live Activity。",
              engineCount == 1 && playerBindingValid ? .normal : .attention)

        let expectedCommands = remoteCommands(session.remoteCommandCenter)
        let ids = commands.map { ObjectIdentifier($0.0) }
        if ids.count != expectedCommands.count || Set(ids) != Set(expectedCommands.map(ObjectIdentifier.init)) {
            report.findings.append("本 App 持有的远程控制注册有缺失、重复或中心不匹配。")
            configureRemoteCommands(session.remoteCommandCenter)
            repaired("remote-registration", "已按持有的注册令牌重新绑定六项远程指令，未移除未知处理器。")
        }
        let enableCommands = player.currentItem != nil
        if expectedCommands.contains(where: { $0.isEnabled != enableCommands }) {
            report.findings.append("远程控制的启用状态与真实播放项不一致。")
            expectedCommands.forEach { $0.isEnabled = enableCommands }
            repaired("remote-enabled", "已按真实播放项同步播放、暂停、切歌与进度控制的启用状态。")
        }
        check("commands", "远程控制注册", "本 App 持有\(commands.count)项注册，每个指令一个令牌；\(enableCommands ? "已启用" : "无实际播放项，保持禁用")。不代表可枚举系统内部处理器。")

        let originalPlayer = player
        let originalItem = player.currentItem
        let originalSongs = songs
        let originalRevision = revision, originalSeek = seekRevision
        let originalIntent = wantsPlayback, originalInterruption = interrupted
        let originalRate = player.rate, originalSpeed = speed
        let originalActivations = audioActivationCount
        let startTime = player.currentTime().seconds
        func unchanged() -> Bool {
            player === originalPlayer && player.currentItem === originalItem && nowPlayingSession === session
                && songs == originalSongs && revision == originalRevision && seekRevision == originalSeek
                && wantsPlayback == originalIntent && interrupted == originalInterruption && speed == originalSpeed
                && player.rate == originalRate && audioActivationCount == originalActivations
        }

        let writesBefore = itemMetadataUpdateCount
        for item in player.items() {
            guard let selected = itemIndices[ObjectIdentifier(item)], let expected = itemMetadata(item, at: selected) else {
                report.errors.append("播放项与歌曲队列的对应关系缺失；未猜测或覆盖曲目信息。")
                continue
            }
            let differences = MediaMetadataInspection.staticDifferences(actual: item.nowPlayingInfo, expected: expected)
            if !differences.isEmpty {
                report.findings.append("真实播放项的媒体信息不一致：" + differences.joined(separator: "、") + "。")
                updateItemMetadata(item, at: selected)
            }
        }
        if itemMetadataUpdateCount > writesBefore { repaired("item-metadata", "已从真实播放项对应的歌曲恢复静态媒体信息，包含当前项及已预加载项。") }
        if player.currentItem == nil && songs.isEmpty && !preparing && !wantsPlayback,
           session.nowPlayingInfoCenter.nowPlayingInfo != nil {
            report.findings.append("队列为空且没有播放意图，当前会话仍留有媒体信息。")
            session.automaticallyPublishesNowPlayingInfo = false
            session.nowPlayingInfoCenter.nowPlayingInfo = nil
            repaired("idle-metadata", "已清除本 App 空闲会话的残留媒体信息，未修改任何歌曲或队列。")
        }
        if player.currentItem != nil && !session.automaticallyPublishesNowPlayingInfo {
            report.findings.append("真实播放项存在，但系统自动发布被关闭。")
            session.automaticallyPublishesNowPlayingInfo = true
            repaired("automatic-publishing", "已恢复当前媒体会话的原生自动发布。")
        }

        if let item = player.currentItem, item.status == .readyToPlay,
           let selected = itemIndices[ObjectIdentifier(item)], let expected = itemMetadata(item, at: selected),
           pendingSeek == nil, !interrupted, playerBindingValid {
            func differences() -> [String] {
                MediaMetadataInspection.systemDifferences(actual: session.nowPlayingInfoCenter.nowPlayingInfo,
                    expected: expected, duration: item.duration.seconds, elapsed: player.currentTime().seconds,
                    rate: player.rate, checkPausedPosition: player.rate == 0)
            }
            let drift = differences()
            if !drift.isEmpty {
                report.findings.append("系统媒体信息与真实播放器有偏差：" + drift.joined(separator: "、") + "。")
                // One explicit reconciliation, retaining automatic publishing.
                // No nil clearing, mode toggle, pause, seek or audio activation.
                var information = expected
                let previous = session.nowPlayingInfoCenter.nowPlayingInfo
                if information[MPMediaItemPropertyArtwork] == nil,
                   previous?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == expected[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
                   let existingCover = previous?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
                    information[MPMediaItemPropertyArtwork] = existingCover
                }
                let elapsed = player.currentTime().seconds, length = item.duration.seconds
                if elapsed.isFinite { information[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed) }
                if length.isFinite && length > 0 { information[MPMediaItemPropertyPlaybackDuration] = length }
                information[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
                session.nowPlayingInfoCenter.nowPlayingInfo = information
                repaired("system-snapshot", "已向当前会话重新发布真实歌曲、封面、时长、进度基准及\(player.rate == 0 ? "暂停零速率" : "实际播放速率")，保留原生自动更新。")
                // Read-back is bounded, not an animation delay. Abort stale
                // work if a user command, track transition or interruption wins.
                for _ in 0..<8 {
                    if !unchanged() || differences().isEmpty { break }
                    do { try await Task.sleep(nanoseconds: 50_000_000) }
                    catch { report.errors.append("检测被取消，请重新检测。"); break }
                }
                if unchanged() && !differences().isEmpty {
                    report.errors.append("系统媒体信息回读仍不一致：" + differences().joined(separator: "、") + "。请重新检测；本次没有重启播放器。")
                    recordMediaEvent("repair-readback-failed")
                }
            }
            check("now-playing", "歌曲、封面与播放时间",
                  "已核对当前会话信息；真实进度\(Int(max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)))秒，实际速率\(player.rate)。播放中系统按进度基准推算，不将基准与当前时间的差值误判为异常。",
                  unchanged() && differences().isEmpty ? .normal : .attention)
            if expected[MPMediaItemPropertyArtwork] == nil && !(currentSong?.cover.isEmpty ?? true) {
                report.limitations.append("当前封面尚未取得可用图像，无法核对图像内容；没有清除缓存或强制重新下载，请加载完成后重新检测。")
            }
        } else {
            check("now-playing", "歌曲、封面与播放时间", "尚无就绪项、正在定位或处于音频中断，未向系统发布猜测进度；可在状态稳定后重新检测。", .unavailable)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let recentWrites = recentMetadataWrites.filter { now - $0 <= 10 }.count
        check("updates", "媒体信息更新频率", "近10秒静态播放项写入\(recentWrites)次；正常刷新按内容去重，进度交由系统推算。频繁切歌或队列调整也会产生合法写入。",
              recentWrites > 30 ? .attention : .normal)
        if recentWrites > 30 { report.findings.append("近期静态媒体信息更新较多；无法确认是异常循环，保留用户操作与正常切歌，未关闭更新。") }
        let endTime = player.currentTime().seconds
        let positionPreserved = !startTime.isFinite || !endTime.isFinite || endTime >= startTime - 0.1
        if !unchanged() || !positionPreserved {
            report.errors.append("检测期间播放项、进度或用户播放意图发生变化，无法完成同一状态的核验。请在状态稳定后重新检测。")
            recordMediaEvent("repair-context-changed")
        }
        check("continuity", "播放保持", "本次未停止、跳转或重建播放器，未更改队列，也未调用音频激活或停用。",
              unchanged() && positionPreserved ? .normal : .attention)
        return report
    }
}
