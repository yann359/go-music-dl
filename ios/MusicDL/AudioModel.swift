import Foundation

struct Song: Codable, Equatable {
    var id: String
    var source: String
    var name: String
    var artist: String
    var album: String
    var cover: String
    var duration: Int
    var extra: String
    var key: String { source + ":" + id + ":" + extra }
}

struct PlaybackRequest: Decodable {
    var action: String
    var songs: [Song]?
    var index: Int?
    var loop: String?
    var order: String?
    var value: Double?
}

struct AssetDescriptor: Decodable {
    var url: URL
    var headers: [String: String]
    var temporary: String
    var source: String
    var id: String
}

enum NativeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum GoBridge {
    // Go may perform network I/O. Never call it on the UI/audio thread.
    private static let worker = DispatchQueue(label: "musicdl.resolver", qos: .userInitiated)

    static func start(root: String) async throws -> URL {
        let data = try await call { root.withCString { MusicDLStart(UnsafeMutablePointer(mutating: $0)) } }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = object["url"], let url = URL(string: value) else {
            throw NativeError.message("本地功能服务启动失败")
        }
        return url
    }

    static func resolve(_ song: Song, fallback: Bool) async throws -> AssetDescriptor {
        let encoded = String(decoding: try JSONEncoder().encode(song), as: UTF8.self)
        let data = try await call {
            encoded.withCString { MusicDLResolve(UnsafeMutablePointer(mutating: $0), fallback ? 1 : 0) }
        }
        return try JSONDecoder().decode(AssetDescriptor.self, from: data)
    }

    private static func call(_ operation: @escaping () -> UnsafeMutablePointer<CChar>?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                guard let pointer = operation() else {
                    continuation.resume(throwing: NativeError.message("原生 Go 桥接返回为空")); return
                }
                let data = Data(String(cString: pointer).utf8)
                MusicDLFree(pointer)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let error = object["error"] {
                    continuation.resume(throwing: NativeError.message(error))
                } else { continuation.resume(returning: data) }
            }
        }
    }
}

actor AudioFiles {
    struct Prepared { let url: URL; let source: String }
    private var files: [String: Prepared] = [:]
    private let root: URL
    private let session: URLSession
    private let resolver: (Song, Bool) async throws -> AssetDescriptor

    init(resolver: @escaping (Song, Bool) async throws -> AssetDescriptor = { song, fallback in
        try await GoBridge.resolve(song, fallback: fallback)
    }) {
        self.resolver = resolver
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeAudio", isDirectory: true)
        // Reclaim only our own abandoned preview-cache files after a restart.
        // Library files and downloaded exports live outside this directory.
        if let stale = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for file in stale where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        // Cookies only come from the authorized resolver, never from WebView JS.
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func prepare(_ song: Song, fallback: Bool = false) async throws -> Prepared {
        let key = song.key + (fallback ? ":fallback" : "")
        if let file = files[key], FileManager.default.fileExists(atPath: file.url.path) { return file }
        let descriptor = try await resolver(song, fallback)
        // Decoded source files are ours; local library files must never be deleted.
        defer { if !descriptor.temporary.isEmpty { try? FileManager.default.removeItem(atPath: descriptor.temporary) } }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination: URL
        if descriptor.url.isFileURL && descriptor.temporary.isEmpty {
            destination = descriptor.url
        } else {
            let staging: URL
            if descriptor.url.isFileURL { staging = descriptor.url }
            else {
                guard ["http", "https"].contains(descriptor.url.scheme?.lowercased() ?? ""),
                      !["127.0.0.1", "localhost", "::1", "[::1]"].contains(descriptor.url.host?.lowercased() ?? "") else {
                    throw NativeError.message("拒绝依赖本机 HTTP 服务的音频地址")
                }
                var request = URLRequest(url: descriptor.url)
                for (header, value) in descriptor.headers { request.setValue(value, forHTTPHeaderField: header) }
                let (url, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: url)
                    throw NativeError.message("音源下载失败")
                }
                staging = url
            }
            defer { if staging != descriptor.url { try? FileManager.default.removeItem(at: staging) } }
            try Task.checkCancellation()
            let size = (try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 && size <= 512 * 1024 * 1024 else {
                throw NativeError.message("音频为空或超过单曲 512 MB 缓存上限")
            }
            destination = root.appendingPathComponent(UUID().uuidString + "." + Self.audioExtension(staging, original: descriptor.url))
            try FileManager.default.copyItem(at: staging, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: destination.path)
        }
        let prepared = Prepared(url: destination, source: descriptor.source)
        files[key] = prepared
        return prepared
    }

    private static func audioExtension(_ file: URL, original: URL) -> String {
        let handle = try? FileHandle(forReadingFrom: file)
        defer { try? handle?.close() }
        let bytes = (try? handle?.read(upToCount: 32)) ?? Data()
        if bytes.starts(with: Data("fLaC".utf8)) { return "flac" }
        if bytes.starts(with: Data("RIFF".utf8)) { return "wav" }
        if bytes.starts(with: Data("OggS".utf8)) { return "ogg" }
        if bytes.count >= 8 && bytes[4..<8] == Data("ftyp".utf8) { return "m4a" }
        if bytes.starts(with: Data("ID3".utf8)) { return "mp3" }
        let ext = original.pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "aiff", "aif", "mp4"].contains(ext) ? ext : "audio"
    }

    // Bounded disk use; never remove files still held by an AVPlayerItem.
    func prune(keeping keys: Set<String>) {
        for key in Array(files.keys) where !keys.contains(key.replacingOccurrences(of: ":fallback", with: "")) {
            if let file = files.removeValue(forKey: key), file.url.deletingLastPathComponent() == root {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }
}
