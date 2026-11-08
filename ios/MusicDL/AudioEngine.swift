import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The only playback owner. No WebView, JavaScript timer, or HTTP loopback
/// connection is used by the queue, remote controls, or interruption recovery.
@MainActor
final class AudioEngine: NSObject, ObservableObject {
    private(set) var player = AVQueuePlayer()
    @Published private(set) var message = "原生播放器就绪"
    var stateDidChange: (([String: Any]) -> Void)?
    private let files: AudioFiles
    private var songs: [Song] = []
    private var index = 0
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
    private var preparing = false

    init(files: AudioFiles = AudioFiles()) {
        self.files = files
        super.init()
        installPlayerObservers()
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.interruption($0) }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.routeChanged($0) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in self?.resetMediaServices() }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.publish(includeQueue: true) }
        observe(.AVPlayerItemDidPlayToEndTime) { [weak self] note in self?.didEnd(note) }
        configureRemoteCommands()
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
    }

    func play() {
        guard !songs.isEmpty else { return }
        do {
            try activate()
            wantsPlayback = true
            if !interrupted { player.playImmediately(atRate: speed) }
            if player.currentItem == nil && !preparing { rebuild(keepingCurrent: false) }
            publish()
        } catch { fail("音频会话启动失败：\(error.localizedDescription)") }
    }

    func pause() {
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause()
        publish()
    }

    func stop() {
        pause(); revision += 1; pipeline?.cancel(); preparing = false
        player.removeAllItems(); itemIndices.removeAll(); itemSources.removeAll()
        songs = []; sequence = []; index = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Task { await files.prune(keeping: []) }
        publish()
    }

    func shutdown() {
        stop()
        if let ticker { player.removeTimeObserver(ticker); self.ticker = nil }
        observations.removeAll(); itemObservation = nil
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        for (command, target) in commands { command.removeTarget(target) }
        commands.removeAll()
        stateDidChange = nil
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let target = max(0, duration.isFinite ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.publish() }
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
        revision += 1; pipeline?.cancel(); preparing = false
        let current = keepingCurrent ? player.currentItem : nil
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
            defer {
                if self.revision == token {
                    self.preparing = false
                    let keep = Set(self.player.items().compactMap { self.itemIndices[ObjectIdentifier($0)] }
                        .map { self.songs[$0].key })
                    Task { await self.files.prune(keeping: keep) }
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
                    if self.wantsPlayback && !self.interrupted { self.player.playImmediately(atRate: self.speed) }
                    self.message = "原生音频已缓存 · 队列就绪 \(self.player.items().count) 首"
                    self.publish()
                } catch {
                    guard self.revision == token && !Task.isCancelled else { return }
                    self.message = "\(song.name) 准备失败：\(error.localizedDescription)"
                    // Stop at a failed item; do not silently play a different song.
                    self.sequence.removeAll()
                    if self.player.currentItem == nil { self.pause() }
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
        let activeIDs = Set(player.items().map(ObjectIdentifier.init))
        itemIndices = itemIndices.filter { activeIDs.contains($0.key) }
        itemSources = itemSources.filter { activeIDs.contains($0.key) }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.itemFailed(item) }
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
        let seconds = player.currentTime().seconds
        if let ticker { player.removeTimeObserver(ticker); self.ticker = nil }
        observations.removeAll(); itemObservation = nil
        player.pause()
        player = AVQueuePlayer()
        installPlayerObservers()
        rebuild(keepingCurrent: false, position: seconds.isFinite ? seconds : 0)
        if wantsPlayback { play() }
    }

    private func fail(_ text: String) { message = text; pause() }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
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
        center.changePlaybackPositionCommand.isEnabled = true
        commands.append((center.changePlaybackPositionCommand, token))
    }

    func publish(includeQueue: Bool = false) {
        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        let position = elapsed.isFinite ? max(0, elapsed) : 0
        let length = duration.isFinite ? max(0, duration) : 0
        let playing = player.timeControlStatus == .playing
        if songs.indices.contains(index) {
            let song = songs[index]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: song.name, MPMediaItemPropertyArtist: song.artist,
                MPMediaItemPropertyAlbumTitle: song.album, MPMediaItemPropertyPlaybackDuration: length,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
                MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
                MPNowPlayingInfoPropertyPlaybackQueueCount: songs.count
            ]
        }
        var state: [String: Any] = ["index": index, "position": position, "duration": length,
                         "playing": playing, "waiting": wantsPlayback && !playing && !interrupted,
                         "rate": speed, "message": message, "readyCount": player.items().count,
                         "loop": loop, "order": order]
        if includeQueue {
            state["songs"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(songs))) ?? []
        }
        stateDidChange?(state)
    }
}
