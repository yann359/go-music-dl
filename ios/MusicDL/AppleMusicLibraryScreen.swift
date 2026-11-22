import SwiftUI

/// Read-only, paginated metadata. Existing playlists change only in the import
/// confirmation flow. These rows never send a playback request to AudioEngine.
struct AppleMusicLibraryScreen: View {
    @EnvironmentObject private var accounts: MusicAccounts
    @State private var category = "playlists"
    @State private var query = ""
    @State private var rows: [JSONValue] = []
    @State private var offset = 0
    @State private var more = false
    @State private var busy = false
    @State private var problem: String?
    @State private var synced: Date?
    @State private var revision = 0
    var body: some View {
        List {
            Section {
                Picker("资料类型", selection: $category) {
                    Text("我的歌单").tag("playlists"); Text("资料库歌曲").tag("songs"); Text("目录搜索").tag("search")
                }.pickerStyle(.segmented)
                if category == "search" {
                    TextField("歌曲名称或歌手", text: $query).submitLabel(.search).onSubmit { Task { await load(reset: true) } }
                    Button("搜索 Apple Music 目录") { Task { await load(reset: true) } }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { Button("同步当前资料") { Task { await load(reset: true) } }.disabled(busy) }
                if let synced { Text("最近读取：\(synced.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Text("展示实际接口返回的音乐资料；下拉可刷新。此页不授予整曲播放权限，也不会修改已有本地歌单。导入请进入目标自建歌单确认。").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView("正在读取…") }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row["attributes"]["name"].stringValue.isEmpty ? "未提供名称" : row["attributes"]["name"].stringValue)
                    let detail = [row["attributes"]["artistName"].stringValue, row["attributes"]["albumName"].stringValue].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if category == "playlists" {
                        NavigationLink("查看曲目") {
                            AppleLibraryTracks(link: "https://music.apple.com/library/playlist/" + row["id"].stringValue)
                        }
                    }
                }
            }
            if more { Button("加载更多") { Task { await load(reset: false) } }.disabled(busy) }
            if !busy && rows.isEmpty && problem == nil { Text(category == "search" ? "请输入歌名或歌手后搜索。" : "当前没有可读取的资料。") }
        }.navigationTitle("Apple Music 资料").navigationBarTitleDisplayMode(.inline)
            .task { await load(reset: true) }
            .onChange(of: category) { _, _ in revision += 1; busy = false; rows = []; offset = 0; more = false; problem = nil; synced = nil; if category != "search" { Task { await load(reset: true) } } }
            .refreshable { await load(reset: true) }
            .onDisappear { revision += 1; busy = false }
    }
    private func load(reset: Bool) async {
        guard !busy, category != "search" || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; problem = nil; let expected = revision, kind = category
        defer { if expected == revision { busy = false } }
        do {
            let start = reset ? 0 : offset
            guard start < 5000 else { throw NativeError.message("本次最多读取5000项，请缩小范围。") }
            let path: String
            if kind == "search" {
                let region = try await accounts.readApple("/v1/me/storefront")["data"].arrayValue.first?["id"].stringValue ?? ""
                guard region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw AppleBrowserError.response }
                var components = URLComponents(); components.queryItems = [URLQueryItem(name: "term", value: String(query.prefix(200))), URLQueryItem(name: "types", value: "songs"), URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "offset", value: String(start))]
                path = "/v1/catalog/\(region.lowercased())/search?" + (components.percentEncodedQuery ?? "")
            } else { path = "/v1/me/library/\(kind)?limit=50&offset=\(start)" }
            let response = try await accounts.readApple(path)
            try Task.checkCancellation()
            guard expected == revision else { return }
            let value = kind == "search" ? response["results"]["songs"] : response
            guard case .array(let data) = value["data"] else { throw AppleBrowserError.response }
            let hasNext = !value["next"].stringValue.isEmpty
            guard !hasNext || !data.isEmpty else { throw AppleBrowserError.response }
            if reset { rows = [] }
            var known = Set(rows.map { $0["id"].stringValue })
            rows += data.filter { known.insert($0["id"].stringValue).inserted }
            offset = start + data.count; more = hasNext; synced = Date()
        } catch { if expected == revision { problem = error.localizedDescription } }
    }
}

private struct AppleLibraryTracks: View {
    let link: String
    @State private var tracks: [ImportTrack] = []
    @State private var offset = 0
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                VStack(alignment: .leading) {
                    Text(track.title)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error) }
            if busy { ProgressView() }
            else if more { Button(error == nil ? "读取曲目" : "重试") { Task { await load() } } }
            else if tracks.isEmpty { Text("这个歌单暂无曲目") }
        }.navigationTitle("歌单曲目")
            .task { if tracks.isEmpty && more { await load() } }
    }
    private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let page = try await ApplePlaylistImport.page(link: link, offset: offset)
            try Task.checkCancellation()
            tracks += page.tracks; offset = page.next; more = page.more
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}
