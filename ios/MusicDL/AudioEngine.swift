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
    private(set) var nowPlayingSession: MPNowPlayingSession?
    private var ownershipRequestPending = false
    private var ownershipAttempted = false
    private var shuttingDown = false
    private let engineID = UUID().uuidString
    private var preparing = false
    private var artwork: MPMediaItemArtwork?
    private var artworkKey = ""
    private var artworkTask: Task<Void, Never>?
    private var pendingSeek: (item: AVPlayerItem, seconds: Double)?
    private var seekRevision = 0

    init(files: AudioFiles = AudioFiles()) {
        self.files = files
        super.init()
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
            if wantsPlayback && !interrupted { player.rate = speed }
            publish()
        case "volume": player.volume = Float(min(1, max(0, request.value ?? 1)))
        case "state": publish(includeQueue: true)
        default: break
        }
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try session.setActive(true)
        recordMediaEvent("audio-activated")
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
        ownershipAttempted = false
        do {
            try activate()
            // A suspended app may receive began without a matching ended. A
            // successful explicit activation is the authority to clear it.
            interrupted = false; resumeAfterInterruption = false
            playbackError = nil
            wantsPlayback = true
            let missingFile = (player.currentItem?.asset as? AVURLAsset).map { $0.url.isFileURL && !FileManager.default.fileExists(atPath: $0.url.path) } ?? false
            if player.status == .failed || player.currentItem?.status == .failed || missingFile {
                recreatePlayer()
            } else if player.currentItem == nil && !preparing {
                rebuild(keepingCurrent: false, position: savedPosition)
            }
            player.playImmediately(atRate: speed)
            watchRecovery()
            publish()
        } catch { fail("暂时无法恢复音频，请稍后点击播放重试。") }
    }

    func pause() {
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
        player.removeAllItems(); itemIndices.removeAll(); itemSources.removeAll()
        songs = []; sequence = []; index = 0; savedPosition = 0; playbackError = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
                if finished { self.pendingSeek = nil }
                self.publish()
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
                    guard self.player.canInsert(item, after: self.player.items().last) else {
                        throw NativeError.message("无法加入原生播放队列")
                    }
                    self.player.insert(item, after: self.player.items().last)
                    if first && position > 0 { self.seek(position) }
                    if self.wantsPlayback && !self.interrupted {
                        self.player.playImmediately(atRate: self.speed)
                        self.watchRecovery()
                    }
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
        if pendingSeek == nil { savedPosition = 0 }
        loadArtwork()
        let activeIDs = Set(player.items().map(ObjectIdentifier.init))
        itemIndices = itemIndices.filter { activeIDs.contains($0.key) }
        itemSources = itemSources.filter { activeIDs.contains($0.key) }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                if item.status == .failed { self.itemFailed(item) }
                else if item.status == .readyToPlay { self.applyPendingSeek(for: item) }
            }
        }
        // A native preloaded queue bridges track boundaries even while WKWebView sleeps.
        if !preparing && player.items().count < 3, let last = player.items().last,
           let lastIndex = itemIndices[ObjectIdentifier(last)], let next = nextIndex(after: lastIndex) {
            sequence.append(next); fill()
        }
        publish()
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
            rememberPosition()
            recoveryWatchdog?.cancel(); recoveryWatchdog = nil
            resumeAfterInterruption = wantsPlayback
            interrupted = true; player.pause(); publish()
        } else {
            interrupted = false
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            let resume = resumeAfterInterruption && wantsPlayback && shouldResume
            resumeAfterInterruption = false
            if resume { play() } else { pause() }
        }
    }

    private func routeChanged(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
    }

    private func resetMediaServices() {
        rememberPosition()
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
        // Keep the existing player-derived metadata path as the sole author.
        // Do not combine automatic publishing with manual global-center writes.
        session.automaticallyPublishesNowPlayingInfo = false
        session.delegate = self
        nowPlayingSession = session
        configureRemoteCommands(session.remoteCommandCenter)
        recordMediaEvent("session-created")
    }

    private func removeNowPlayingSession() {
        for (command, target) in commands { command.removeTarget(target); command.isEnabled = false }
        commands.removeAll()
        guard let session = nowPlayingSession else { return }
        session.delegate = nil
        session.nowPlayingInfoCenter.nowPlayingInfo = nil
        // This entire session is being retired, not edited in place. Let its
        // lifetime own its KVO teardown. Removing every player first caused a
        // reproducible duplicate currentItem-observer removal on iOS 26.5.
        nowPlayingSession = nil
        ownershipRequestPending = false
        ownershipAttempted = false
    }

    func recordMediaEvent(_ event: String) {
        let session = AVAudioSession.sharedInstance()
        MediaSessionDiagnostics.record(event, fields: [
            "engine": engineID,
            "session_active": String(nowPlayingSession?.isActive ?? false),
            "can_become_active": String(nowPlayingSession?.canBecomeActive ?? false),
            "session_players": String(nowPlayingSession?.players.count ?? 0),
            "registered_commands": String(commands.count),
            "queue_count": String(songs.count),
            "state": playbackState.rawValue,
            "rate": String(player.rate),
            "category": session.category.rawValue,
            "mixing": String(session.categoryOptions.contains(.mixWithOthers)),
            "app_state": String(UIApplication.shared.applicationState.rawValue)
        ])
    }

    private func claimNowPlayingSession() {
        guard !shuttingDown, wantsPlayback, !interrupted, player.currentItem != nil,
              let session = nowPlayingSession, !session.isActive, session.canBecomeActive,
              !ownershipRequestPending, !ownershipAttempted else { return }
        ownershipRequestPending = true
        ownershipAttempted = true
        session.becomeActiveIfPossible { [weak self, weak session] accepted in
            Task { @MainActor in
                guard let self, let session, self.nowPlayingSession === session else { return }
                self.ownershipRequestPending = false
                self.recordMediaEvent(accepted ? "ownership-accepted" : "ownership-declined")
            }
        }
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
            if session.canBecomeActive { self.ownershipAttempted = false }
            self.claimNowPlayingSession()
        }
    }

    private func configureRemoteCommands(_ center: MPRemoteCommandCenter) {
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = false
            let token = command.addTarget { [weak self] _ in
                guard self != nil else { return .commandFailed }
                Task { @MainActor [weak self] in
                    guard let self, self.currentSong != nil, !self.shuttingDown else { return }
                    self.recordMediaEvent("remote-command")
                    action()
                }
                return .success
            }
            commands.append((command, token))
        }
        bind(center.playCommand) { [weak self] in self?.play() }
        bind(center.pauseCommand) { [weak self] in self?.pause() }
        bind(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }; self.wantsPlayback ? self.pause() : self.play()
        }
        bind(center.nextTrackCommand) { [weak self] in self?.skip(1) }
        bind(center.previousTrackCommand) { [weak self] in self?.skip(-1) }
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = false
        commands.append((center.changePlaybackPositionCommand, token))
    }

    func publish(includeQueue: Bool = false) {
        guard !shuttingDown else { return }
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
        if songs.indices.contains(index) {
            let song = songs[index]
            var information: [String: Any] = [
                MPMediaItemPropertyTitle: song.name, MPMediaItemPropertyArtist: song.artist,
                MPMediaItemPropertyAlbumTitle: song.album, MPMediaItemPropertyPlaybackDuration: length,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : Float(0),
                MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
                MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
                MPNowPlayingInfoPropertyPlaybackQueueCount: songs.count
            ]
            information[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            information[MPNowPlayingInfoPropertyIsLiveStream] = false
            information[MPNowPlayingInfoPropertyExternalContentIdentifier] = song.source + ":" + song.id
            if let artwork { information[MPMediaItemPropertyArtwork] = artwork }
            nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = information
        }
        for (command, _) in commands { command.isEnabled = currentSong != nil }
        if playing { claimNowPlayingSession() }
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
