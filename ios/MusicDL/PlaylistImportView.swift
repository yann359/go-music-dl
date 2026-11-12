import SwiftUI
import UniformTypeIdentifiers

struct SongSelectionScreen: View {
    var single = false
    var existing: Set<String> = []
    var initialQuery = ""
    let onSelect: ([Song]) async throws -> Void
    @EnvironmentObject private var client: NativeClient
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = SearchSession()
    @State private var query = ""
    @State private var selection: [Song] = []
    @State private var excluded: Set<String> = []
    @State private var saving = false
    @State private var problem: String?
    private var sources: [String] { client.searchSources.map(\.id).filter { !excluded.contains($0) } }
    var body: some View {
        List {
            Section {
                Menu {
                    Button("全部可用来源") { excluded = []; search() }
                    ForEach(client.searchSources, id: \.id) { source in
                        Button {
                            if excluded.contains(source.id) { excluded.remove(source.id) } else { excluded.insert(source.id) }
                            search()
                        } label: { Label(source.name, systemImage: excluded.contains(source.id) ? "circle" : "checkmark.circle") }
                    }
                } label: { Label("\(sources.count) 个搜索来源 · 含本地音乐", systemImage: "line.3.horizontal.decrease") }
                Text(single ? "请核对歌手、专辑和版本，再选择歌曲。" : "按歌名或歌手搜索，支持跨搜索结果多选，每次最多 200 首。")
                    .font(.caption).foregroundStyle(.secondary)
                if !selection.isEmpty { Button("清除已选 \(selection.count) 首") { selection = [] } }
            }
            if session.loading { ProgressView("正在搜索…") }
            if let problem { Text(problem).foregroundStyle(.red) }
            if let problem = session.problem { Text(problem).font(.subheadline).foregroundStyle(.secondary); Button("重新搜索") { search() } }
            ForEach(Array((session.result?.songs ?? []).prefix(session.visibleCount)), id: \.key) { song in
                let identity = song.source + ":" + song.id
                let selected = selection.contains { $0.source + ":" + $0.id == identity }
                let duplicate = existing.contains(identity)
                Button {
                    if selected { selection.removeAll { $0.source + ":" + $0.id == identity } }
                    else if single { selection = [song] }
                    else if selection.count < 200 { selection.append(song) }
                } label: {
                    HStack(spacing: 12) {
                        CoverArt(url: song.cover, title: song.name, radius: 10).frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.name).foregroundStyle(.primary).lineLimit(1)
                            Text([song.artist, song.album, song.source.uppercased()].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if duplicate { Text("已在当前歌单").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: selected || duplicate ? "checkmark.circle.fill" : "circle")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(duplicate || saving || !song.sourceAvailable)
            }
            if (session.result?.songs.count ?? 0) > session.visibleCount { Button("显示更多结果") { session.showMore() } }
            if session.phase == .empty { Text("没有找到歌曲，请调整歌名、歌手或来源。") }
            if let result = session.result, !result.errors.isEmpty { Text(result.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(single ? "手动匹配" : "添加其他歌曲").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "歌曲名称或歌手")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, _ in search(debounce: true) }
            .onAppear { if query.isEmpty { query = initialQuery }; if !query.isEmpty { search() } }
            .onDisappear { session.suspend() }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "正在保存…" : "完成 (\(selection.count))") {
                    saving = true; problem = nil
                    Task {
                        do { try await onSelect(selection); dismiss() }
                        catch { problem = error.localizedDescription }
                        saving = false
                    }
                }.disabled(selection.isEmpty || saving).accessibilityIdentifier("song-selection-done")
            } }
    }
    private func search(debounce: Bool = false) {
        // Reuse the existing search session, including debounce and stale-result protection.
        session.start(client: client, query: query, kind: "song", sources: sources, debounce: debounce)
    }
}

struct PlaylistImportView: View {
    @EnvironmentObject private var client: NativeClient
    @StateObject private var service: PlaylistImportService
    var onChange: () -> Void
    @State private var filePicker = false
    @State private var review = false
    @State private var fileError: String?
    init(collectionID: String, onChange: @escaping () -> Void) {
        _service = StateObject(wrappedValue: PlaylistImportService(collectionID: collectionID)); self.onChange = onChange
    }
    var body: some View {
        List {
            Section {
                Text("将歌单中的歌曲信息带到这里，再通过已有音乐来源匹配。导入不会迁移音频文件或增加播放权限。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !service.draft.rows.isEmpty {
                    Button(service.draft.confirmed ? "查看上次导入结果" : "继续上次导入") { review = true }
                }
                if let problem = service.problem { Text(problem).foregroundStyle(.red) }
            }
            Section("选择音乐平台") {
                platform("网易云音乐", id: "netease", detail: "公开完整歌单链接 · 分页读取")
                platform("QQ 音乐", id: "qq", detail: "公开完整歌单链接 · 分页读取")
                platform("Spotify", id: "spotify", detail: "需要官方授权及接口访问权限 · 真机待验证")
                platform("Apple Music", id: "apple", detail: "需要 MusicKit 权限与兼容签名 · 真机待验证")
            }
            Section("通过文件或文字") {
                Button { filePicker = true } label: { Label("选择歌单文件", systemImage: "doc.badge.plus") }
                NavigationLink { TextPlaylistImportScreen(service: service, onChange: onChange) } label: { Label("粘贴歌曲列表", systemImage: "text.alignleft") }
                Text("CSV 支持 title/artist/album/duration，JSON 支持曲目数组或 tracks/songs；TXT 使用“歌手 - 歌名”。M3U 仅匹配已有本地歌曲，不下载流地址。")
                    .font(.caption).foregroundStyle(.secondary)
                if let fileError { Text(fileError).foregroundStyle(.red) }
            }
            Section("尚未开放直接链接导入") {
                ForEach(["酷狗音乐", "YouTube Music", "SoundCloud"], id: \.self) { name in
                    VStack(alignment: .leading, spacing: 4) { Text(name); Text("尚未完成适用于本 App 的接口接入验证，请使用文件或文字导入。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("导入其他软件的歌单").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $review) { PlaylistImportReviewScreen(service: service, onChange: onChange) }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .plainText, .json, UTType(filenameExtension: "m3u") ?? .data, UTType(filenameExtension: "m3u8") ?? .data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let text = try Self.fileText(url)
                    fileError = nil; service.parse(text: text, format: url.pathExtension.lowercased(), client: client); review = true
                } catch { fileError = error.localizedDescription }
            }
    }
    private func platform(_ name: String, id: String, detail: String) -> some View {
        NavigationLink { PlatformPlaylistImportScreen(name: name, source: id, service: service, onChange: onChange) } label: {
            VStack(alignment: .leading, spacing: 5) { Text(name); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
    static func fileText(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 5 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 5 * 1024 * 1024 else { throw NativeError.message("歌单文件不能超过 5 MB") }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        throw NativeError.message("文件编码无法识别，请另存为 UTF-8 或 UTF-16")
    }
}

private struct TextPlaylistImportScreen: View {
    @ObservedObject var service: PlaylistImportService
    var onChange: () -> Void
    @EnvironmentObject private var client: NativeClient
    @State private var text = ""
    @State private var review = false
    var body: some View {
        Form {
            Section("每行一首：歌手 - 歌名") {
                TextEditor(text: $text).frame(minHeight: 230).accessibilityIdentifier("playlist-import-text")
                Text("例如：周杰伦 - 晴天\n林俊杰 - 江南\n陈奕迅 - 十年").font(.caption).foregroundStyle(.secondary)
            }
            Button("读取并预览") { service.parse(text: text, format: "text", client: client); review = true }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 5 * 1024 * 1024 || service.busy)
        }.navigationTitle("文本导入").navigationDestination(isPresented: $review) { PlaylistImportReviewScreen(service: service, onChange: onChange) }
    }
}

private struct PlatformPlaylistImportScreen: View {
    let name: String
    let source: String
    @ObservedObject var service: PlaylistImportService
    var onChange: () -> Void
    @EnvironmentObject private var client: NativeClient
    @State private var link = ""
    @State private var review = false
    var body: some View {
        Form {
            Section("歌单分享链接") {
                TextField("粘贴完整 HTTPS 歌单链接", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("读取歌单并预览") { service.readLink(link, source: source, client: client); review = true }.disabled(link.isEmpty || service.busy)
                Text("仅接受所选平台的标准歌单域名。私有、已删除或无权限歌单会显示实际错误；不会索取密码或读取浏览器 Cookie。").font(.caption).foregroundStyle(.secondary)
            }
            if source == "spotify" || source == "apple" {
                Section("已授权平台") {
                    NavigationLink("选择自己的平台歌单") { AuthorizedPlaylistImportScreen(source: source, service: service, onChange: onChange) }
                    NavigationLink("账号授权与权限") { AccountsScreen() }
                    Text(source == "spotify" ? "复用已有 Spotify PKCE 授权。开发模式可能只允许读取本人拥有或协作的歌单。" : "复用已有 Apple Music 系统授权。当前 IPA 的签名与 MusicKit 能力可能限制读取，授权成功不等于接口已可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(name).navigationDestination(isPresented: $review) { PlaylistImportReviewScreen(service: service, onChange: onChange) }
    }
}

private struct AuthorizedPlaylistImportScreen: View {
    let source: String
    @ObservedObject var service: PlaylistImportService
    var onChange: () -> Void
    @EnvironmentObject private var client: NativeClient
    @State private var values: [NativeCollection] = []
    @State private var offset = 0
    @State private var more = true
    @State private var loading = false
    @State private var problem: String?
    @State private var review = false
    var body: some View {
        List {
            if loading { ProgressView("正在读取已授权歌单…") }
            if let problem { Text(problem).foregroundStyle(.secondary); NavigationLink("检查账号授权") { AccountsScreen() }; Button("重试") { Task { await load() } } }
            ForEach(values, id: \.identityKey) { item in
                Button(item.name) {
                    let link = source == "spotify" ? "https://open.spotify.com/playlist/" + item.id : item.link
                    service.readLink(link, source: source, client: client); review = true
                }.disabled(service.busy)
            }
            if more && !values.isEmpty { Button("加载更多") { Task { await load() } }.disabled(loading) }
            if values.isEmpty && !loading && problem == nil { Text("当前账号没有可读取的歌单。") }
        }.navigationTitle("选择平台歌单").task { if values.isEmpty { await load() } }
            .navigationDestination(isPresented: $review) { PlaylistImportReviewScreen(service: service, onChange: onChange) }
    }
    private func load() async {
        guard !loading else { return }; loading = true; problem = nil; defer { loading = false }
        do {
            let items: [NativeCollection]
            if source == "apple" { let result = try await ApplePlaylistImport.playlists(offset: offset); items = result.items; more = result.more }
            else { items = try await client.userPlaylists(source: source, page: offset / 50 + 1, limit: 50); more = items.count == 50 }
            try Task.checkCancellation()
            let known = Set(values.map(\.identityKey)); values += items.filter { !known.contains($0.identityKey) }; offset += items.count
        } catch is CancellationError { }
        catch { problem = error.localizedDescription }
    }
}

struct PlaylistImportReviewScreen: View {
    @ObservedObject var service: PlaylistImportService
    var onChange: () -> Void
    @EnvironmentObject private var client: NativeClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter = "all"
    @State private var confirm = false
    private var rows: [ImportRow] { service.draft.rows.filter { filter == "all" || (filter == "matched" ? $0.state == .matched : $0.state != .matched) } }
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CoverArt(url: service.draft.cover, title: service.draft.title).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 5) { Text(service.draft.title).font(.headline); Text(service.phase).font(.caption).foregroundStyle(.secondary) }
                }
                Text("已读取 \(service.draft.rows.count) · 已匹配 \(service.matched) · 待处理 \(service.unresolved) · 待匹配 \(service.pending)").font(.caption)
                if service.draft.confirmed { Text("已新增 \(service.draft.added) · 已跳过重复 \(service.draft.duplicates)").font(.subheadline) }
                Text("已匹配表示元数据匹配，实际播放时由当前来源验证。未匹配信息会保留，并标记暂不可播放。重复曲目在保存时核对并跳过。").font(.caption).foregroundStyle(.secondary)
                if let problem = service.problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("playlist-import-error") }
            }
            Section {
                if service.busy { ProgressView(); Button("暂停 / 取消尚未完成的导入", role: .cancel) { service.pause() } }
                else {
                    if !service.draft.readComplete { Button("继续读取失败页面") { service.resumeReading(client: client) } }
                    if service.pending > 0 { Button("开始 / 继续匹配") { service.match(client: client) } }
                    if service.unresolved > 0 { Button("再次尝试未匹配和失败歌曲") { service.match(client: client, retry: true) } }
                    if service.draft.rows.contains(where: { !$0.committed }) {
                        Button(service.draft.confirmed ? "保存剩余曲目和重新匹配结果" : "确认导入到当前歌单") { confirm = true }
                            .accessibilityIdentifier("playlist-import-confirm")
                    }
                }
            }
            Section {
                Picker("筛选", selection: $filter) { Text("全部").tag("all"); Text("已匹配").tag("matched"); Text("待处理").tag("unresolved") }.pickerStyle(.segmented)
                ForEach(rows) { row in
                    NavigationLink {
                        SongSelectionScreen(single: true, initialQuery: [row.track.title, row.track.artist].joined(separator: " ")) { songs in
                            if let song = songs.first { service.select(song, rowID: row.id) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.track.title).lineLimit(1)
                            Text([row.track.artist, row.track.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            Text(status(row)).font(.caption).foregroundStyle(.secondary)
                            if let song = row.match { Text("→ \(song.name) · \(song.artist) · \(song.source.uppercased())").font(.caption2).foregroundStyle(.secondary) }
                            if !row.note.isEmpty { Text(row.note).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.disabled(service.busy || (row.committed && row.state == .matched))
                }
            }
        }.navigationTitle(service.draft.confirmed ? "导入结果" : "导入预览").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("将 \(service.draft.rows.filter { !$0.committed }.count) 首曲目追加到当前歌单？原有歌曲会保留；重复项将跳过，未匹配项仅保存信息。", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认导入") { service.commit(client: client, completed: onChange) }
            }
            .onDisappear { service.pause() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { service.pause() } }
    }
    private func status(_ row: ImportRow) -> String {
        switch row.state {
        case .pending: return "等待匹配 · 可手动选择"
        case .matched: return row.committed ? "已保存匹配" : "已匹配 · 待确认保存"
        case .needsReview: return "版本或候选不确定 · 请手动选择"
        case .unmatched: return "暂不可播放 · 未找到唯一匹配"
        case .failed: return "匹配失败 · 可重试或手动选择"
        }
    }
}
