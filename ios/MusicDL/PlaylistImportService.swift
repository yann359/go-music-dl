import Foundation
import Combine

struct ImportTrack: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var source: String
    var sourceID: String
    var playlistID: String
    var isrc: String
    var cover: String
    var localPath: String
}

enum ImportMatchState: String, Codable { case pending, matched, needsReview, unmatched, failed }
struct ImportRow: Codable, Identifiable {
    // The occurrence id preserves the source order, including repeated tracks.
    var id = UUID().uuidString
    var track: ImportTrack
    var state: ImportMatchState = .pending
    var match: Song?
    var note = ""
    var committed = false
}
struct PlaylistImportDraft: Codable {
    var version = 1
    var collectionID: String
    var title = "导入预览"
    var cover = ""
    var rows: [ImportRow] = []
    var source = ""
    var link = ""
    var offset = 0
    var total = 0
    var readComplete = true
    var added = 0
    var duplicates = 0
    var confirmed = false
}
struct ImportPlaylistPage: Decodable {
    var title: String; var cover: String; var total: Int
    var tracks: [ImportTrack]; var next: Int; var more: Bool
}
struct ImportCommitResult: Decodable { var added: Int; var duplicates: Int }

enum SongMatchingService {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func version(_ title: String) -> Set<String> {
        let value = title.lowercased()
        let markers: [(String, [String])] = [
            ("live", ["live", "现场", "演唱会"]), ("remix", ["remix", "混音"]),
            ("instrumental", ["instrumental", "伴奏", "纯音乐", "karaoke"]),
            ("cover", ["cover", "翻唱"]), ("acoustic", ["acoustic", "不插电"]),
            ("remaster", ["remaster", "重制"]), ("edit", ["radio edit", "剪辑版"]),
            ("sped", ["sped up", "加速版", "slowed", "慢速版"])
        ]
        return Set(markers.filter { _, terms in terms.contains { term in
            if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
                return value.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b", options: .regularExpression) != nil
            }
            return value.contains(term)
        }}.map(\.0))
    }
    static func artists(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "/、&;；"))
            .map(normalized).filter { !$0.isEmpty }.sorted().joined(separator: "|")
    }
    static func isrc(_ song: Song) -> String {
        guard let data = song.extra.data(using: .utf8), let extra = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return extra["isrc"]?.uppercased() ?? ""
    }
    static func score(_ track: ImportTrack, _ song: Song) -> Double {
        guard song.sourceAvailable, version(track.title) == version(song.name) else { return 0 }
        let title = normalized(track.title), artist = artists(track.artist)
        guard !title.isEmpty, title == normalized(song.name) else { return 0 }
        // A conflicting artist must never be overridden by an untrusted file ID.
        guard !artist.isEmpty, artist == artists(song.artist) else { return 0 }
        if track.duration > 0 && song.duration > 0 && abs(track.duration - song.duration) > 8 { return 0.6 }
        if !track.isrc.isEmpty, track.isrc.uppercased() == isrc(song) { return 1 }
        if !track.sourceID.isEmpty, track.source == song.source, track.sourceID == song.id { return 1 }
        var score = 0.92
        if !track.album.isEmpty && normalized(track.album) == normalized(song.album) { score += 0.04 }
        if track.duration > 0 && song.duration > 0 && abs(track.duration - song.duration) <= 4 { score += 0.04 }
        return score
    }
    static func automatic(_ track: ImportTrack, candidates: [Song]) -> Song? {
        let ranked = candidates.map { ($0, score(track, $0)) }.filter { $0.1 >= 0.92 }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first else { return nil }
        if first.1 == 1 { return first.0 }
        let distinct = ranked.dropFirst().contains { item in
            // Same recording offered by several sources does not cause ambiguity.
            normalized(item.0.album) != normalized(first.0.album) ||
                (item.0.duration > 0 && first.0.duration > 0 && abs(item.0.duration - first.0.duration) > 4)
        }
        return distinct ? nil : first.0
    }
}

/// Additive sidecar only; original SQLite, favorites and queue data stay intact.
/// One recoverable draft per destination playlist. No third-party credentials.
struct PlaylistImportRepository {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaylistImports", isDirectory: true)
    }
    private func url(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isNumber }), id.count <= 20 else { throw NativeError.message("无效的目标歌单") }
        return directory.appendingPathComponent(id + ".json")
    }
    func load(_ id: String) throws -> PlaylistImportDraft? {
        let file = try url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw NativeError.message("导入记录过大，原歌单仍然保留") }
        let draft = try JSONDecoder().decode(PlaylistImportDraft.self, from: Data(contentsOf: file))
        guard draft.version == 1, draft.collectionID == id, draft.rows.count <= 5000 else { throw NativeError.message("导入记录版本或内容不兼容，原歌单仍然保留") }
        return draft
    }
    func save(_ draft: PlaylistImportDraft) throws {
        let file = try url(draft.collectionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        guard data.count <= 32 * 1024 * 1024 else { throw NativeError.message("导入记录超过安全大小") }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
final class PlaylistImportService: ObservableObject {
    @Published private(set) var draft: PlaylistImportDraft
    @Published private(set) var busy = false
    @Published private(set) var phase = "准备导入"
    @Published var problem: String?
    private let repository: PlaylistImportRepository
    private var task: Task<Void, Never>?
    private var generation = 0
    init(collectionID: String, repository: PlaylistImportRepository = PlaylistImportRepository()) {
        self.repository = repository
        self.draft = PlaylistImportDraft(collectionID: collectionID)
        do { if let saved = try repository.load(collectionID) { draft = saved; phase = saved.confirmed ? "上次导入结果" : "已恢复上次预览" } }
        catch { problem = "无法恢复上次预览：" + error.localizedDescription }
    }
    var matched: Int { draft.rows.filter { $0.state == .matched }.count }
    var unresolved: Int { draft.rows.filter { [.unmatched, .needsReview, .failed].contains($0.state) }.count }
    var pending: Int { draft.rows.filter { $0.state == .pending }.count }
    private func save() throws { try repository.save(draft) }
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; problem = nil; generation += 1
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { busy = false; task = nil } }
            do { try await operation() }
            catch is CancellationError { }
            catch { if token == generation { problem = error.localizedDescription; phase = "已暂停，已读取内容保留" } }
        }
    }
    func pause() {
        guard busy else { return }
        task?.cancel(); task = nil; generation += 1; busy = false; phase = "已暂停，可继续"
        do { try save() } catch { problem = "保存进度失败：" + error.localizedDescription }
    }
    func parse(text: String, format: String, client: NativeClient) {
        run { [self] in
            phase = "正在解析歌单"
            let tracks = try await client.request("playlist_import.parse", params: ["text": .string(text), "format": .string(format)]).decoded([ImportTrack].self)
            try Task.checkCancellation()
            var next = PlaylistImportDraft(collectionID: draft.collectionID)
            next.rows = tracks.map { ImportRow(track: $0) }; next.total = tracks.count
            // Persist successfully before replacing an older recoverable draft.
            try repository.save(next); draft = next; phase = "已读取 \(tracks.count) 首，请开始匹配"
        }
    }
    func readLink(_ link: String, source: String, client: NativeClient) {
        run { [self] in
            var next = PlaylistImportDraft(collectionID: draft.collectionID)
            next.link = link.trimmingCharacters(in: .whitespacesAndNewlines); next.source = source; next.readComplete = false
            // Validate/load the first page before replacing an earlier draft.
            let page = try await Self.page(next, client: client)
            try Task.checkCancellation(); try apply(page, to: &next); try repository.save(next); draft = next
            try await readRemaining(client: client)
        }
    }
    private static func page(_ draft: PlaylistImportDraft, client: NativeClient) async throws -> ImportPlaylistPage {
        if draft.source == "apple" { return try await ApplePlaylistImport.page(link: draft.link, offset: draft.offset) }
        return try await client.request("playlist_import.page", params: ["url": .string(draft.link), "source": .string(draft.source), "offset": .number(Double(draft.offset))]).decoded(ImportPlaylistPage.self)
    }
    private func apply(_ page: ImportPlaylistPage, to next: inout PlaylistImportDraft) throws {
        guard page.total <= 5000, next.rows.count + page.tracks.count <= 5000,
              !page.more || page.next > next.offset else { throw NativeError.message("分页异常或超出 5000 首限制") }
        if next.offset > 0, page.total >= 0, next.total >= 0, page.total != next.total { throw NativeError.message("来源歌单已发生变化，请重新读取以保持曲目顺序") }
        let priorIDs = Set(next.rows.map { $0.track.id })
        if page.more, !page.tracks.isEmpty, page.tracks.allSatisfy({ priorIDs.contains($0.id) }) {
            throw NativeError.message("来源重复返回上一页，已停止读取，请检查歌单")
        }
        next.title = page.title; next.cover = page.cover; next.total = page.total
        next.rows += page.tracks.map { ImportRow(track: $0) }; next.offset = page.next; next.readComplete = !page.more
    }
    private func readRemaining(client: NativeClient) async throws {
        while !draft.readComplete {
            phase = "正在读取歌单 · 已读取 \(draft.rows.count)" + (draft.total >= 0 ? " / \(draft.total) 首" : " 首")
            try await Task.sleep(nanoseconds: 350_000_000)
            let page = try await Self.page(draft, client: client)
            try Task.checkCancellation(); var next = draft; try apply(page, to: &next)
            try repository.save(next); draft = next
        }
        phase = "已读取 \(draft.rows.count) 首，请开始匹配"
    }
    func resumeReading(client: NativeClient) { run { [self] in try await readRemaining(client: client) } }
    func match(client: NativeClient, retry: Bool = false) {
        run { [self] in
            if retry {
                for index in draft.rows.indices where draft.rows[index].state != .matched {
                    draft.rows[index].state = .pending
                }
            }
            for index in draft.rows.indices where draft.rows[index].state == .pending {
                try Task.checkCancellation()
                phase = "正在匹配歌曲 · \(index + 1) / \(draft.rows.count)"
                let track = draft.rows[index].track
                do {
                    var candidates: [Song] = []; var failures: [String] = []
                    if !track.localPath.isEmpty {
                        let value = try await client.request("playlist_import.local", params: ["path": .string(track.localPath)])
                        candidates = try value.decoded([NativeSongPayload].self).map(\.song)
                        try Task.checkCancellation()
                        if candidates.count == 1 { draft.rows[index].match = candidates[0]; draft.rows[index].state = .matched }
                        else { draft.rows[index].state = candidates.isEmpty ? .unmatched : .needsReview; draft.rows[index].note = "本地路径未唯一匹配；未打开或下载路径中的内容" }
                    } else {
                        // Same search implementation and three-source concurrency cap as the search tab.
                        let query = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " ")
                        // Never let an imported field enter the search tab's URL parser.
                        guard !query.contains("://"), !query.hasPrefix("spotify:") else { throw NativeError.message("歌名包含链接，请手动搜索匹配") }
                        try await client.searchProgressively(query: query, type: "song", sources: client.searchSources.map(\.id)) { result in
                            candidates = result.songs; failures = result.errors
                        }
                        try Task.checkCancellation()
                        if let selected = SongMatchingService.automatic(track, candidates: candidates) {
                            draft.rows[index].match = selected; draft.rows[index].state = .matched
                        } else { draft.rows[index].state = candidates.isEmpty ? (failures.isEmpty ? .unmatched : .failed) : .needsReview }
                        draft.rows[index].note = failures.isEmpty ? "" : "部分来源暂不可用，可重试或手动匹配"
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); draft.rows[index].state = .failed; draft.rows[index].note = error.localizedDescription }
                // Checkpoints survive process death. At most nine metadata-only matches need redoing.
                if index % 10 == 0 { try save() }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            try save(); phase = "匹配完成，请检查预览后确认导入"
        }
    }
    func select(_ song: Song, rowID: String) {
        guard !busy, let index = draft.rows.firstIndex(where: { $0.id == rowID }),
              !(draft.rows[index].committed && draft.rows[index].state == .matched) else { return }
        draft.rows[index].match = song; draft.rows[index].state = .matched; draft.rows[index].committed = false
        do { try save() } catch { problem = error.localizedDescription }
    }
    func commit(client: NativeClient, completed: @escaping () -> Void) {
        run { [self] in
            draft.confirmed = true; try save()
            let indices = draft.rows.indices.filter { !draft.rows[$0].committed }
            for start in stride(from: 0, to: indices.count, by: 100) {
                try Task.checkCancellation(); phase = "正在保存 · \(start) / \(indices.count)"
                let batch = Array(indices[start..<min(start + 100, indices.count)])
                let songs = try batch.map { try storedSong(draft.rows[$0]) }
                let result = try await client.addSongsToCollection(id: draft.collectionID, songs: songs)
                // A canceled write may already have committed. Retrying is safe
                // through the SQLite unique constraint; never touch a newer draft.
                try Task.checkCancellation()
                for index in batch { draft.rows[index].committed = true }
                draft.added += result.added; draft.duplicates += result.duplicates; try save(); completed()
                try Task.checkCancellation()
            }
            try await client.loadLibrary(); phase = "导入完成"; completed()
        }
    }
    private func storedSong(_ row: ImportRow) throws -> Song {
        let t = row.track
        var song = row.match ?? Song(id: t.id, source: "import-metadata", name: t.title, artist: t.artist, album: t.album, cover: t.cover, duration: t.duration, extra: "{}")
        var extra = (try? JSONDecoder().decode([String: String].self, from: Data(song.extra.utf8))) ?? [:]
        extra["musicdl_import_key"] = t.id
        extra["musicdl_import_metadata"] = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        extra["musicdl_match_state"] = row.state.rawValue
        if !t.isrc.isEmpty { extra["isrc"] = t.isrc }
        song.extra = String(decoding: try JSONEncoder().encode(extra), as: UTF8.self)
        return song
    }
}

extension NativeClient {
    func addSongsToCollection(id: String, songs: [Song]) async throws -> ImportCommitResult {
        try await request("collections.add_batch", params: ["id": .string(id), "songs": try .encoded(songs)]).decoded(ImportCommitResult.self)
    }
}
