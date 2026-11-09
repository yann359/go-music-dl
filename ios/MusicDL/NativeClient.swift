import Foundation
import Combine

/// Lossless JSON storage keeps every original setting available to native forms.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: box, debugDescription: "不支持的 JSON 值") }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }

    var stringValue: String {
        get {
            switch self {
            case .string(let value): return value
            case .number(let value): return value.rounded() == value ? String(format: "%.0f", value) : String(value)
            case .bool(let value): return value ? "true" : "false"
            default: return ""
            }
        }
        set { self = .string(newValue) }
    }
    var boolValue: Bool {
        get { if case .bool(let value) = self { return value }; return false }
        set { self = .bool(newValue) }
    }
    var numberValue: Double {
        get { if case .number(let value) = self { return value }; return Double(stringValue) ?? 0 }
        set { self = .number(newValue) }
    }
    var objectValue: [String: JSONValue] {
        get { if case .object(let value) = self { return value }; return [:] }
        set { self = .object(newValue) }
    }
    var arrayValue: [JSONValue] {
        get { if case .array(let value) = self { return value }; return [] }
        set { self = .array(newValue) }
    }
    subscript(key: String) -> JSONValue {
        get { objectValue[key] ?? .null }
        set { var values = objectValue; values[key] = newValue; self = .object(values) }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

struct NativeSource: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let search: Bool
    let album: Bool
    let playlist: Bool
    let recommend: Bool
    let toplist: Bool
    let category: Bool
    let configured: Bool
    let qrLogin: Bool
    let userPlaylists: Bool
    init(id: String, name: String, search: Bool = true, album: Bool = true, playlist: Bool = true, recommend: Bool = false, toplist: Bool = false, qrLogin: Bool = false, userPlaylists: Bool = false, category: Bool = false, configured: Bool = false) {
        self.id = id; self.name = name; self.search = search; self.album = album; self.playlist = playlist
        self.recommend = recommend; self.toplist = toplist; self.qrLogin = qrLogin; self.userPlaylists = userPlaylists
        self.category = category; self.configured = configured
    }
    private enum CodingKeys: String, CodingKey { case id, name, search, album, playlist, recommend, toplist, category, configured; case qrLogin = "qr_login", userPlaylists = "user_playlists" }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? box.decode(String.self, forKey: .id)) ?? ""
        name = (try? box.decode(String.self, forKey: .name)) ?? id
        search = (try? box.decode(Bool.self, forKey: .search)) ?? false
        album = (try? box.decode(Bool.self, forKey: .album)) ?? false
        playlist = (try? box.decode(Bool.self, forKey: .playlist)) ?? false
        recommend = (try? box.decode(Bool.self, forKey: .recommend)) ?? false
        toplist = (try? box.decode(Bool.self, forKey: .toplist)) ?? false
        category = (try? box.decode(Bool.self, forKey: .category)) ?? false
        configured = (try? box.decode(Bool.self, forKey: .configured)) ?? false
        qrLogin = (try? box.decode(Bool.self, forKey: .qrLogin)) ?? false
        userPlaylists = (try? box.decode(Bool.self, forKey: .userPlaylists)) ?? false
    }
}

struct NativeCollection: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var cover: String
    var creator: String
    var source: String
    var description: String
    var trackCount: Int
    var link: String
    var kind: String
    var contentType: String
    var externalID: String
    var key: String { source + ":" + id }

    init(id: String = "", name: String = "", cover: String = "", creator: String = "", source: String = "local", description: String = "", trackCount: Int = 0, link: String = "", kind: String = "manual", contentType: String = "playlist", externalID: String = "") {
        self.id = id; self.name = name; self.cover = cover; self.creator = creator; self.source = source
        self.description = description; self.trackCount = trackCount; self.link = link; self.kind = kind
        self.contentType = contentType; self.externalID = externalID
    }

    private enum CodingKeys: String, CodingKey { case id, name, cover, creator, source, description, link, kind; case trackCount = "track_count", contentType = "content_type", externalID = "external_id" }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? box.decode(String.self, forKey: .id) { id = value }
        else { id = String((try? box.decode(Int.self, forKey: .id)) ?? 0) }
        name = (try? box.decode(String.self, forKey: .name)) ?? "未命名歌单"
        cover = (try? box.decode(String.self, forKey: .cover)) ?? ""
        creator = (try? box.decode(String.self, forKey: .creator)) ?? ""
        source = (try? box.decode(String.self, forKey: .source)) ?? "local"
        description = (try? box.decode(String.self, forKey: .description)) ?? ""
        trackCount = (try? box.decode(Int.self, forKey: .trackCount)) ?? 0
        link = (try? box.decode(String.self, forKey: .link)) ?? ""
        kind = (try? box.decode(String.self, forKey: .kind)) ?? "manual"
        contentType = (try? box.decode(String.self, forKey: .contentType)) ?? "playlist"
        externalID = (try? box.decode(String.self, forKey: .externalID)) ?? ""
    }
}

struct NativeTopList: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var cover: String
    var source: String
    var description: String
    var trackCount: Int
    var link: String
    var key: String { source + ":" + id }
    init(id: String, name: String, cover: String = "", source: String, description: String = "", trackCount: Int = 0, link: String = "") {
        self.id = id; self.name = name; self.cover = cover; self.source = source; self.description = description; self.trackCount = trackCount; self.link = link
    }
    private enum CodingKeys: String, CodingKey { case id, name, cover, source, description, link; case trackCount = "track_count" }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? box.decode(String.self, forKey: .id)) ?? ""
        name = (try? box.decode(String.self, forKey: .name)) ?? "排行榜"
        cover = (try? box.decode(String.self, forKey: .cover)) ?? ""
        source = (try? box.decode(String.self, forKey: .source)) ?? ""
        description = (try? box.decode(String.self, forKey: .description)) ?? ""
        trackCount = (try? box.decode(Int.self, forKey: .trackCount)) ?? 0
        link = (try? box.decode(String.self, forKey: .link)) ?? ""
    }
}

struct NativeCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let source: String
    let group: String?
    var key: String { source + ":" + id }
}

private struct NativeSongPayload: Decodable {
    let song: Song
    private enum CodingKeys: String, CodingKey { case id, songID = "song_id", source, name, artist, album, cover, duration, extra, link; case albumID = "album_id", isVIP = "is_vip" }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let extra: String
        if let value = try? box.decode(String.self, forKey: .extra) { extra = value }
        else if let value = try? box.decode(JSONValue.self, forKey: .extra), value != .null {
            extra = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        } else { extra = "" }
        song = Song(id: (try? box.decode(String.self, forKey: .id)) ?? (try? box.decode(String.self, forKey: .songID)) ?? "",
                    source: (try? box.decode(String.self, forKey: .source)) ?? "",
                    name: (try? box.decode(String.self, forKey: .name)) ?? "未命名歌曲",
                    artist: (try? box.decode(String.self, forKey: .artist)) ?? "未知歌手",
                    album: (try? box.decode(String.self, forKey: .album)) ?? "",
                    cover: (try? box.decode(String.self, forKey: .cover)) ?? "",
                    duration: (try? box.decode(Int.self, forKey: .duration)) ?? 0, extra: extra,
                    albumID: try? box.decode(String.self, forKey: .albumID),
                    link: try? box.decode(String.self, forKey: .link),
                    isVIP: try? box.decode(Bool.self, forKey: .isVIP))
    }
}

struct NativeSearchResult {
    var songs: [Song] = []
    var playlists: [NativeCollection] = []
    var errors: [String] = []
}

struct NativeDownloadTask: Decodable, Identifiable {
    let id: Int
    let name: String
    let artist: String
    let source: String
    let status: String
    let error: String
    let warning: String
    let path: String
    let attempts: Int
    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        func field(_ lower: String, _ upper: String) -> JSONValue { value.objectValue[lower] ?? value.objectValue[upper] ?? .null }
        id = Int(field("id", "ID").numberValue)
        name = field("name", "Name").stringValue
        artist = field("artist", "Artist").stringValue
        source = field("source", "Source").stringValue
        status = field("status", "Status").stringValue
        error = field("error", "Error").stringValue
        warning = field("warning", "Warning").stringValue
        path = field("path", "Path").stringValue
        attempts = Int(field("attempts", "Attempts").numberValue)
    }
}

struct NativeQRSession: Decodable {
    var source: String
    var key: String
    var url: String
    var imageURL: String?
    var expiresAt: Int64?
    private enum CodingKeys: String, CodingKey { case source, key, url; case imageURL = "image_url", expiresAt = "expires_at" }
}
struct NativeQRResult: Decodable {
    var source: String
    var key: String
    var status: String
    var message: String?
}

/// A real C-ABI transport. UI requests use Go directly; no hidden WebView is needed.
@MainActor
final class NativeClient: ObservableObject {
    typealias Transport = (Data) async throws -> Data
    @Published private(set) var sources: [NativeSource] = []
    @Published private(set) var defaultSources: [String] = []
    @Published private(set) var qrSources: [String] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var collections: [NativeCollection] = []
    @Published private(set) var localSongs: [Song] = []
    @Published var settings: [String: JSONValue] = [:]
    @Published var cookies: [String: String] = [:]
    @Published private(set) var downloads: [NativeDownloadTask] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var isOfflinePreview = false
    private let transport: Transport
    private static let queue = DispatchQueue(label: "musicdl.native-client", qos: .userInitiated, attributes: .concurrent)

    init(transport: Transport? = nil) { self.transport = transport ?? Self.goTransport }

    private var previewSongs: [Song] {
        [Song(id: "preview-firstlight", source: "local", name: "第一缕晨光", artist: "澄音 · 界面样例", album: "慢慢听见", cover: "", duration: 248, extra: ""),
         Song(id: "preview-city", source: "local", name: "沿着城市散步", artist: "澄音 · 界面样例", album: "慢慢听见", cover: "", duration: 213, extra: ""),
         Song(id: "preview-moon", source: "local", name: "月光落在窗边", artist: "澄音 · 界面样例", album: "夜色留白", cover: "", duration: 276, extra: "")]
    }

    /// Explicit screenshot/QA fixture only; never call during normal startup.
    /// These entries describe a designed UI state, not playable provider results.
    func loadOfflinePreview() {
        isOfflinePreview = true
        sources = [NativeSource(id: "netease", name: "网易云音乐", recommend: true, toplist: true, qrLogin: true, userPlaylists: true),
                   NativeSource(id: "qq", name: "QQ 音乐", recommend: true, toplist: true, qrLogin: true, userPlaylists: true),
                   NativeSource(id: "bilibili", name: "哔哩哔哩", album: false),
                   NativeSource(id: "local", name: "本地音乐", album: false, playlist: false)]
        defaultSources = ["netease", "qq"]
        collections = [NativeCollection(id: "9001", name: "慢慢听见", creator: "我的收藏", description: "为忙碌留一点空白", trackCount: 12),
                       NativeCollection(id: "9002", name: "夜色留白", creator: "我的收藏", description: "适合一个人的夜晚", trackCount: 8)]
        localSongs = previewSongs
        settings = ["downloadToLocal": .bool(true), "autoSwitchInvalidSources": .bool(true), "downloadConcurrency": .number(3), "webdavEnabled": .bool(false), "webdavUrl": .string("")]
        error = nil
    }

    private static func goTransport(_ input: Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let text = String(decoding: input, as: UTF8.self)
                guard let pointer = text.withCString({ MusicDLRequest(UnsafeMutablePointer(mutating: $0)) }) else {
                    continuation.resume(throwing: NativeError.message("音乐服务未返回结果，请重试")); return
                }
                let result = Data(String(cString: pointer).utf8)
                MusicDLFree(pointer)
                continuation.resume(returning: result)
            }
        }
    }

    func request(_ action: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard !isOfflinePreview else { throw NativeError.message("当前为界面演示模式，不会执行联网、播放或数据修改。请正常启动后使用。") }
        try Task.checkCancellation()
        let input = try JSONEncoder().encode(JSONValue.object(["action": .string(action), "params": .object(params)]))
        let data: Data
        do { data = try await transport(input) }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeError.message("音乐服务暂时不可用：\(error.localizedDescription)") }
        try Task.checkCancellation()
        let envelope: JSONValue
        do { envelope = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw NativeError.message("音乐服务返回了无法识别的数据，请重试") }
        if !envelope["error"].stringValue.isEmpty { throw NativeError.message("音乐服务：" + envelope["error"].stringValue) }
        return envelope["data"]
    }

    func loadBootstrap() async throws {
        if isOfflinePreview { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let result = try await request("sources")
            sources = try result["sources"].decoded([NativeSource].self)
            defaultSources = (try? result["defaults"].decoded([String].self)) ?? []
            qrSources = (try? result["qr_sources"].decoded([String].self)) ?? []
            try await loadLibrary()
            try await loadSettings()
        } catch { self.error = error.localizedDescription; throw error }
    }

    private func results(_ value: JSONValue) throws -> NativeSearchResult {
        let result = NativeSearchResult(songs: try decodeSongs(value["songs"]),
                           playlists: value["playlists"] == .null ? [] : try value["playlists"].decoded([NativeCollection].self),
                           errors: (try? value["errors"].decoded([String].self)) ?? [])
        if result.songs.isEmpty && result.playlists.isEmpty && !result.errors.isEmpty {
            throw NativeError.message(result.errors.joined(separator: "\n"))
        }
        return result
    }
    private func decodeSongs(_ value: JSONValue) throws -> [Song] {
        guard value != .null else { return [] }
        return try value.decoded([NativeSongPayload].self).map(\.song)
    }
    private func checkWarnings(_ value: JSONValue, empty: Bool) throws {
        warnings = (try? value["errors"].decoded([String].self)) ?? []
        if empty && !warnings.isEmpty { throw NativeError.message(warnings.joined(separator: "\n")) }
    }

    func search(query: String, type: String = "song", sources: [String]) async throws -> NativeSearchResult {
        if isOfflinePreview { return NativeSearchResult(songs: type == "song" ? previewSongs : [], playlists: type == "song" ? [] : collections) }
        return try results(await request("search", params: ["q": .string(query), "type": .string(type), "sources": .array(sources.map(JSONValue.string))]))
    }
    func recommendations(sources: [String]) async throws -> NativeSearchResult {
        if isOfflinePreview { return NativeSearchResult(songs: previewSongs, playlists: collections) }
        return try results(await request("recommend", params: ["sources": .array(sources.map(JSONValue.string))]))
    }
    func topLists(sources: [String]) async throws -> [NativeTopList] {
        if isOfflinePreview { return [NativeTopList(id: "preview-top", name: "今日灵感", source: "local", description: "界面演示榜单", trackCount: 20)] }
        let result = try await request("toplists", params: ["sources": .array(sources.map(JSONValue.string))])
        let values = try result["toplists"].decoded([NativeTopList].self)
        try checkWarnings(result, empty: values.isEmpty)
        return values
    }
    func detail(kind: String, id: String, source: String = "") async throws -> [Song] {
        if isOfflinePreview { return previewSongs }
        let result = try await request("detail", params: ["kind": .string(kind), "id": .string(id), "source": .string(source)])
        let values = try decodeSongs(result["songs"])
        try checkWarnings(result, empty: values.isEmpty)
        return values
    }
    func loadLibrary() async throws {
        if isOfflinePreview { return }
        let result = try await request("collections.list", params: ["include_imported": .bool(true)])
        collections = try result.decoded([NativeCollection].self)
    }
    func createCollection(name: String) async throws -> NativeCollection {
        let result = try await request("collections.create", params: ["name": .string(name)])
        let created = try result.decoded(NativeCollection.self)
        try await loadLibrary()
        return created
    }
    func deleteCollection(id: String) async throws {
        _ = try await request("collections.delete", params: ["id": .string(id)])
        try await loadLibrary()
    }
    func addToCollection(id: String, song: Song) async throws {
        _ = try await request("collections.add", params: ["id": .string(id), "song": try .encoded(song)])
        try await loadLibrary()
    }
    func removeFromCollection(id: String, song: Song) async throws {
        _ = try await request("collections.remove", params: ["id": .string(id), "song": try .encoded(song)])
    }
    func importCollection(_ playlist: NativeCollection, kind: String = "playlist") async throws {
        var params = try JSONValue.encoded(playlist).objectValue
        params["external_id"] = .string(playlist.id)
        params["content_type"] = .string(kind)
        _ = try await request("collections.import", params: params)
        try await loadLibrary()
    }
    func loadLocalMusic() async throws {
        if isOfflinePreview { return }
        let result = try await request("local.list")
        localSongs = try decodeSongs(result["tracks"] == .null ? result["songs"] : result["tracks"])
    }
    func deleteLocalSong(id: String) async throws {
        _ = try await request("local.delete", params: ["id": .string(id)])
        try await loadLocalMusic()
    }
    func importLocalFile(url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = url.lastPathComponent.isEmpty ? "music.audio" : url.lastPathComponent
        let staged = directory.appendingPathComponent(UUID().uuidString + "-" + safeName)
        try FileManager.default.copyItem(at: url, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await request("local.import", params: ["path": .string(staged.path), "filename": .string(safeName)])
        try await loadLocalMusic()
    }
    func loadSettings() async throws { if !isOfflinePreview { settings = try await request("settings.get").objectValue } }
    func saveSettings(_ patch: [String: JSONValue]) async throws {
        let combined = settings.merging(patch) { _, new in new }
        let result = try await request("settings.save", params: ["settings": .object(combined)])
        settings = result.objectValue
    }
    func loadCookies() async throws { if !isOfflinePreview { cookies = try await request("cookies.get").decoded([String: String].self) } }
    func saveCookies(_ values: [String: String]) async throws {
        _ = try await request("cookies.save", params: ["cookies": .object(values.mapValues(JSONValue.string))])
        try await loadCookies()
    }
    func switchSource(_ song: Song, target: String = "") async throws -> Song {
        let value = try await request("switch_source", params: ["song": try .encoded(song), "target": .string(target)])
        return try value.decoded(NativeSongPayload.self).song
    }
    func lyrics(for song: Song) async throws -> String {
        if isOfflinePreview { return "[00:00.00]界面演示歌词 · 澄音\n[00:08.00]让忙碌慢一点\n[00:16.00]让声音陪着你\n[00:24.00]把此刻留给自己" }
        return try await request("lyric", params: ["song": try .encoded(song)])["text"].stringValue
    }
    func loadDownloads() async throws {
        if isOfflinePreview { return }
        let result = try await request("downloads.list")
        downloads = try result["tasks"].decoded([NativeDownloadTask].self)
    }
    func enqueueDownload(_ songs: [Song]) async throws {
        _ = try await request("downloads.enqueue", params: ["songs": try .encoded(songs), "request_id": .string(UUID().uuidString)])
        try await loadDownloads()
    }
    func downloadAction(id: Int, action: String) async throws {
        _ = try await request("downloads.action", params: ["id": .number(Double(id)), "action": .string(action)])
        try await loadDownloads()
    }
    func removeDownload(id: Int) async throws {
        _ = try await request("downloads.remove", params: ["id": .number(Double(id))])
        try await loadDownloads()
    }
    func createQR(source: String) async throws -> NativeQRSession {
        try await request("qr.create", params: ["source": .string(source)]).decoded(NativeQRSession.self)
    }
    func checkQR(source: String, key: String) async throws -> NativeQRResult {
        try await request("qr.check", params: ["source": .string(source), "key": .string(key)]).decoded(NativeQRResult.self)
    }
    func aiIndex() async throws -> JSONValue { try await request("ai.index") }

    func userPlaylists(source: String, page: Int = 1, limit: Int = 20) async throws -> [NativeCollection] {
        if isOfflinePreview { return collections }
        let result = try await request("user_playlists", params: ["sources": .array([.string(source)]), "page": .number(Double(page)), "limit": .number(Double(limit))])
        let values = try result["playlists"].decoded([NativeCollection].self)
        try checkWarnings(result, empty: values.isEmpty)
        return values
    }
    func categories(source: String) async throws -> [NativeCategory] {
        if isOfflinePreview { return [] }
        let result = try await request("categories", params: ["sources": .array([.string(source)])])
        let values = try result["categories"].decoded([NativeCategory].self)
        try checkWarnings(result, empty: values.isEmpty)
        return values
    }
    func categoryPlaylists(source: String, id: String, page: Int = 1, limit: Int = 20) async throws -> [NativeCollection] {
        if isOfflinePreview { return collections }
        let result = try await request("category_playlists", params: ["source": .string(source), "category_id": .string(id), "page": .number(Double(page)), "limit": .number(Double(limit))])
        let values = try result["playlists"].decoded([NativeCollection].self)
        try checkWarnings(result, empty: values.isEmpty)
        return values
    }
}
