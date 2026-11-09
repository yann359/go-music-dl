import SwiftUI
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    let audio: AudioEngine
    let client = NativeClient()
    let accounts = MusicAccounts.shared
    let service = LocalService()
    @Published var isReady = false
    @Published var error: String?
    @Published var toast: String?
    @Published var showPlayer = false
    @Published var selectedTab = 0
    private var starting = false
    private var ai: NativeAIConnection?
    let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("musicdl-ui-fixture.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            if let file = try? AVAudioFile(forWriting: url, settings: format.settings),
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8) {
                buffer.frameLength = 48000 * 8
                memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                try? file.write(from: buffer)
            }
            audio = AudioEngine(files: AudioFiles { song, _ in
                AssetDescriptor(url: url, headers: [:], temporary: "", source: song.source, id: song.id)
            })
        } else { audio = AudioEngine() }
    }

    func start() async {
        guard !starting && !isReady else { return }
        starting = true; error = nil
        defer { starting = false }
        if isUITesting {
            client.loadOfflinePreview()
            let sample = Song(id: "visual-fixture", source: "local", name: "暮色里的漫游", artist: "澄音 · 界面演示", album: "慢一点，也很好", cover: "", duration: 240, extra: "")
            if !ProcessInfo.processInfo.arguments.contains("--ui-empty-player") {
                audio.handle(PlaybackRequest(action: "queue", songs: [sample], index: 0, loop: "all", order: "list"))
            }
            isReady = true
            return
        }
        #if DEBUG
        let nativeStartupTest = ProcessInfo.processInfo.arguments.contains("--ui-native-startup")
        #else
        let nativeStartupTest = false
        #endif
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil || nativeStartupTest else { return }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #if DEBUG
            _ = try await client.request("diagnostics.enable")
            let serviceStart = Date()
            #endif
            let url = try await service.connect(root: root.path)
            #if DEBUG
            print("[native-timing] local-service-start elapsed=\(Date().timeIntervalSince(serviceStart))s")
            #endif
            try await client.loadBootstrap()
            isReady = true
            ai = NativeAIConnection(baseURL: url, audio: audio)
            ai?.start()
            Task { await accounts.restore() }
        } catch { self.error = error.localizedDescription }
    }

    func play(_ songs: [Song], at index: Int = 0) {
        guard songs.indices.contains(index) else { return }
        let available = songs.filter(\.sourceAvailable)
        guard !available.isEmpty else { notify("此来源已移除，记录仍保留。请重新搜索或使用本地音乐。"); return }
        let selected = min(songs.prefix(index).filter(\.sourceAvailable).count, available.count - 1)
        if available.count != songs.count { notify("已跳过不可用来源的曲目，歌单记录仍保留。") }
        audio.playSongs(available, at: selected)
    }

    func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { notify(error.localizedDescription) }
        }
    }

    func notify(_ message: String) {
        guard toast != message else { return }
        toast = message
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if toast == message { toast = nil } }
    }

    func favorite(_ song: Song) async throws {
        try await client.loadLibrary()
        var favorite = client.collections.first { $0.name == "我喜欢的音乐" }
        if favorite == nil { favorite = try await client.createCollection(name: "我喜欢的音乐") }
        if let favorite { try await client.addToCollection(id: favorite.id, song: song); notify("已加入我喜欢的音乐") }
    }

    func resumeConnections() async {
        guard isReady, !isUITesting else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            _ = try await service.connect(root: root.path)
            ai?.stop(); ai?.start()
        } catch { notify("本地功能暂时不可用，请稍后重新打开 App 重试；已缓存音频仍可播放。") }
    }
}

@MainActor
final class NativeAIConnection {
    private let baseURL: URL
    private let audio: AudioEngine
    private let clientID = "ios-native-" + UUID().uuidString
    private var task: Task<Void, Never>?
    private var pendingState: Data?
    private var stateUpload: Task<Void, Never>?
    private var generation = 0
    init(baseURL: URL, audio: AudioEngine) { self.baseURL = baseURL; self.audio = audio }

    func start() {
        guard task == nil else { return }
        generation += 1; let token = generation
        audio.stateDidChange = { [weak self] state in self?.publish(state) }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            var attempts = 0
            while !Task.isCancelled && attempts < 3 {
                attempts += 1
                let connected = Date()
                do {
                    var components = URLComponents(url: self.baseURL.appendingPathComponent("api/ai/player/events"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "client_id", value: self.clientID)]
                    let (bytes, response) = try await URLSession.shared.bytes(from: components.url!)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NativeError.message("AI 播放连接失败") }
                    self.audio.publish()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("data:") {
                            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                self.command(object)
                            }
                        }
                    }
                } catch { /* reconnect control channel; native audio keeps playing */ }
                if Date().timeIntervalSince(connected) > 30 { attempts = 0 }
                do { try await Task.sleep(nanoseconds: UInt64(max(1, attempts)) * 500_000_000) } catch { break }
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        stateUpload?.cancel(); stateUpload = nil; pendingState = nil
        audio.stateDidChange = nil
    }

    private func command(_ object: [String: Any]) {
        guard (object["client_id"] as? String ?? clientID) == clientID, let action = object["action"] as? String else { return }
        if action == "play_song", let item = object["song"] as? [String: Any] {
            let extra = (try? JSONSerialization.data(withJSONObject: item["extra"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
            let song = Song(id: item["id"] as? String ?? "", source: item["source"] as? String ?? "", name: item["name"] as? String ?? "", artist: item["artist"] as? String ?? "", album: item["album"] as? String ?? "", cover: "", duration: item["duration"] as? Int ?? 0, extra: String(decoding: extra, as: UTF8.self))
            guard !song.id.isEmpty && !song.source.isEmpty else { return }
            audio.playSongs([song])
        } else if action == "toggle" { audio.isPlaying || audio.waiting ? audio.pause() : audio.play() }
        else {
            let value = object["position"] as? Double ?? object["volume"] as? Double ?? object["rate"] as? Double
            audio.handle(PlaybackRequest(action: action, value: value))
        }
    }

    private func publish(_ state: [String: Any]) {
        var payload: [String: Any] = ["client_id": clientID, "ready": true, "playing": audio.isPlaying,
            "position": audio.position, "duration": audio.duration, "volume": audio.player.volume,
            "playback_rate": audio.playbackRate, "queue_length": audio.songs.count, "queue_index": audio.index,
            "page_visible": UIApplication.shared.applicationState == .active]
        if let song = audio.currentSong {
            payload["current"] = ["id": song.id, "source": song.source, "name": song.name, "artist": song.artist,
                "album": song.album, "duration": song.duration,
                "extra": (try? JSONSerialization.jsonObject(with: Data(song.extra.utf8))) ?? [:]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        // Serialize updates and coalesce intermediate progress. A quick pause
        // must still be published, even immediately after a progress update.
        pendingState = data
        guard stateUpload == nil else { return }
        let token = generation
        stateUpload = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            defer { if self.generation == token { self.stateUpload = nil } }
            while let next = self.pendingState, !Task.isCancelled {
                self.pendingState = nil
                var request = URLRequest(url: self.baseURL.appendingPathComponent("api/ai/player/state"))
                request.httpMethod = "POST"; request.httpBody = next
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }
}
