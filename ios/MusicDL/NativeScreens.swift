import SwiftUI
import UniformTypeIdentifiers

struct DiscoverScreen: View {
    @Environment(\.musicAccent) private var accent
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var client: NativeClient
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    private var playlists: [NativeCollection] { client.discoveryPlaylists }
    private var charts: [NativeTopList] { client.discoveryCharts }
    private var songs: [Song] { client.discoverySongs }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text("CHENGYIN / MUSICDL").font(.caption2.weight(.semibold)).tracking(2.4).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "waveform.path").foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("给此刻，\n一点好声音。").font(.system(size: 39, weight: .semibold, design: .rounded))
                        .tracking(-1.8).fixedSize(horizontal: false, vertical: true)
                    Text("从熟悉的旋律，到下一次心动。\n连接你的音乐来源，慢慢发现。").font(.subheadline).lineSpacing(5).foregroundStyle(.secondary)
                    Button { model.selectedTab = 1 } label: {
                        Label("寻找一首歌", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 13)
                    }.buttonStyle(.borderedProminent).foregroundStyle(MusicDesign.onAccent).buttonBorderShape(.capsule)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
                    .background(MusicDesign.panel(scheme), in: RoundedRectangle(cornerRadius: 30))
                if client.discoveryLoading { HStack { ProgressView(); Text("正在连接音乐来源…").font(.subheadline).foregroundStyle(.secondary) } }
                if !playlists.isEmpty {
                    SectionHeading(title: "发现你的下一张歌单", subtitle: "来自已连接平台的推荐")
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(playlists, id: \.identityKey) { playlist in
                                NavigationLink { CollectionDetailScreen(collection: playlist, kind: "playlist") } label: { CollectionCard(collection: playlist) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if !charts.isEmpty {
                    SectionHeading(title: "正在被听见", subtitle: "平台排行榜")
                    ForEach(charts.prefix(8), id: \.identityKey) { chart in
                        NavigationLink { SongDetailScreen(title: chart.name, kind: "toplist", id: chart.id, source: chart.source, cover: chart.cover) } label: {
                            HStack(spacing: 15) {
                                CoverArt(url: chart.cover, title: chart.name).frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chart.name).font(.headline).foregroundStyle(.primary)
                                    Text(sourceName(chart.source)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(12).background(MusicDesign.panel(scheme), in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    }
                }
                if !songs.isEmpty {
                    SectionHeading(title: "再听一首")
                    SongRows(songs: songs)
                }
                if !client.discoveryFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("部分来源暂时无法连接", systemImage: "antenna.radiowaves.left.and.right.slash").font(.subheadline.weight(.medium))
                        ForEach(client.discoveryFailures.keys.sorted(), id: \.self) { key in
                            let source = key.split(separator: ":").last.map(String.init) ?? key
                            HStack {
                                Text(sourceName(source) + (key.hasPrefix("toplists:") ? " · 排行榜" : " · 推荐")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("重试") { Task { await client.loadDiscovery(force: true, key: key) } }
                                    .font(.subheadline).disabled(client.discoveryLoading)
                            }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MusicDesign.panel(scheme), in: RoundedRectangle(cornerRadius: 20))
                }
                NavigationLink { SourceBrowserScreen() } label: {
                    Label("浏览所有音乐来源", systemImage: "globe.asia.australia").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).padding(16)
                }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 18))
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 28)
        }.background(MusicDesign.canvas(scheme)).navigationTitle("发现")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { model.selectedTab = 3 } label: { Image(systemName: "person.crop.circle").font(.title3) }.accessibilityLabel("我的账号") } }
            .refreshable { await client.loadDiscovery(force: true) }
            .task { await client.loadDiscovery() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await client.loadDiscovery(onlyFailed: true) } }
            }
    }
    private func sourceName(_ source: String) -> String { client.sources.first { $0.id == source }?.name ?? source }

}

extension NativeCollection { var identityKey: String { source + ":" + id } }
extension NativeTopList { var identityKey: String { source + ":" + id } }

struct CollectionCard: View {
    let collection: NativeCollection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverArt(url: collection.cover, title: collection.name, radius: 21).frame(width: 172, height: 172)
            Text(collection.name).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
            Text(collection.creator.isEmpty ? collection.source.uppercased() : collection.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: 172, alignment: .leading)
    }
}

struct SearchScreen: View {
    @EnvironmentObject private var client: NativeClient
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SearchSession()
    @State private var query = ""
    @State private var kind = "song"
    @State private var sourceSheet = false
    @AppStorage("music.search.sources") private var sourcesJSON = ""
    @AppStorage("music.search.recent") private var recentJSON = "[]"
    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentJSON.utf8))) ?? [] }
    private var selected: Set<String> {
        sourcesJSON.isEmpty ? Set(client.searchSources.map(\.id)) : Set((try? JSONDecoder().decode([String].self, from: Data(sourcesJSON.utf8))) ?? [])
    }
    private var eligible: [NativeSource] { client.searchSources.filter { kind == "song" ? $0.search : (kind == "album" ? $0.album : $0.playlist) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("搜索类型", selection: $kind) {
                    Text("歌曲").tag("song"); Text("专辑").tag("album"); Text("歌单").tag("playlist")
                }.pickerStyle(.segmented)
                HStack {
                    Text(sourcesJSON.isEmpty ? "全部可用来源 · 包含本地" : "已选 \(selected.intersection(Set(eligible.map(\.id))).count) 个支持的来源").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { sourceSheet = true } label: { Label("音源", systemImage: "line.3.horizontal.decrease") }.font(.subheadline)
                }
                if session.loading { ProgressView(session.phase == .partial ? "已有结果，其他来源继续搜索…" : "正在搜索…").frame(maxWidth: .infinity).padding(.vertical, 16).accessibilityIdentifier("search-loading") }
                if let problem = session.problem {
                    NativeEmptyState(symbol: "wifi.exclamationmark", title: "搜索遇到了一点问题", detail: problem)
                    Button("重试") { search(refresh: true) }
                }
                if let result = session.result {
                    if !result.songs.isEmpty { SongRows(songs: Array(result.songs.prefix(session.visibleCount)), searchMetadata: true) }
                    if !result.playlists.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 24) {
                            ForEach(Array(result.playlists.prefix(session.visibleCount)), id: \.identityKey) { collection in
                                NavigationLink { CollectionDetailScreen(collection: collection, kind: collection.source == "local" ? "collection" : collection.contentType) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        CoverArt(url: collection.cover, title: collection.name, radius: 20).aspectRatio(1, contentMode: .fit)
                                        Text(collection.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text([collection.creator, collection.source.uppercased()].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if max(result.songs.count, result.playlists.count) > session.visibleCount {
                        Button("显示更多结果") { session.showMore() }.frame(maxWidth: .infinity)
                    }
                    if session.phase == .empty {
                        NativeEmptyState(symbol: "magnifyingglass", title: "没有找到这段旋律", detail: "试试歌名、歌手，或切换音乐来源。")
                    }
                    if session.phase != .failed && !result.errors.isEmpty { Text(result.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }
                    if session.phase == .complete { Text("已显示真实返回结果 · 可继续调整关键词或来源").font(.caption).foregroundStyle(.secondary) }
                } else if session.phase == .idle {
                    NativeEmptyState(symbol: "waveform.path", title: "你想听见什么？", detail: "歌名、歌手、专辑，或一张珍藏的歌单。")
                    if !recent.isEmpty {
                        HStack { SectionHeading(title: "最近搜索"); Button("清空") { recentJSON = "[]" }.font(.caption) }
                        ForEach(recent, id: \.self) { term in
                            Button { query = term; search() } label: {
                                HStack { Image(systemName: "clock.arrow.circlepath"); Text(term); Spacer(); Image(systemName: "arrow.up.left") }.padding(.vertical, 10)
                            }.foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(22)
        }.background(MusicDesign.canvas(scheme)).navigationTitle("搜索")
            .searchable(text: $query, prompt: "歌曲、歌手、专辑与歌单")
            .submitLabel(.search)
            .onSubmit(of: [.search, .text]) { search() }
            .onChange(of: query) { _, _ in search(debounce: true) }
            .onChange(of: kind) { _, _ in search() }
            .onChange(of: client.sources) { _, _ in if !query.isEmpty { search(refresh: true) } }
            .onChange(of: client.networkAvailable) { _, available in if available && session.phase == .failed { search(refresh: true) } }
            .onChange(of: scenePhase) { _, phase in if phase == .active && session.phase == .failed { search(refresh: true) } }
            .onAppear { if !query.isEmpty && session.phase == .idle { search() } }
            .onDisappear { session.suspend() }
            .sheet(isPresented: $sourceSheet, onDismiss: { if !query.isEmpty { search() } }) {
                NavigationStack {
                    List {
                        Section {
                            Button("选择全部来源") { sourcesJSON = "" }
                            Button("取消全选") { sourcesJSON = "[]" }
                        }
                        Section {
                            ForEach(client.searchSources, id: \.id) { source in
                                let supported = eligible.contains { $0.id == source.id }
                                Button {
                                    var values = selected
                                    if values.contains(source.id) { values.remove(source.id) } else { values.insert(source.id) }
                                    sourcesJSON = String(decoding: (try? JSONEncoder().encode(values.sorted())) ?? Data("[]".utf8), as: UTF8.self)
                                } label: {
                                    HStack {
                                        Text(source.name).foregroundStyle(supported ? .primary : .secondary)
                                        Spacer()
                                        if !supported { Text("不支持此类型").font(.caption).foregroundStyle(.secondary) }
                                        else if selected.contains(source.id) { Image(systemName: "checkmark.circle.fill") }
                                    }
                                }.disabled(!supported)
                            }
                        }
                    }.navigationTitle("选择音乐来源")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sourceSheet = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
    private func search(debounce: Bool = false, refresh: Bool = false) {
        session.start(client: client, query: query, kind: kind, sources: eligible.map(\.id).filter { selected.contains($0) }, debounce: debounce, refresh: refresh) { term in
            recentJSON = String(decoding: (try? JSONEncoder().encode(Array(([term] + recent.filter { $0 != term }).prefix(8)))) ?? Data("[]".utf8), as: UTF8.self)
        }
    }
}

struct SongRows: View {
    @Environment(\.musicAccent) private var accent
    let songs: [Song]
    var collectionID: String? = nil
    var onChange: () -> Void = {}
    var onFirstVisible: () -> Void = {}
    var searchMetadata = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.key) { index, song in
                HStack(spacing: 13) {
                    Button { model.play(songs, at: index) } label: {
                        HStack(spacing: 13) {
                            CoverArt(url: song.cover, title: song.name, radius: 10).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(song.name).font(.body.weight(.medium)).foregroundStyle(audio.currentSong?.key == song.key ? accent : .primary).lineLimit(1)
                                Text([song.artist, song.sourceAvailable ? song.source.uppercased() : (song.source == "import-metadata" ? "暂不可播放 · 歌曲信息已保留" : "来源已移除 · 记录保留")].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if searchMetadata {
                                    Text([song.album, song.duration > 0 ? String(format: "%d:%02d", song.duration / 60, song.duration % 60) : "", searchPlaybackStatus(song)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!song.sourceAvailable)
                        .accessibilityIdentifier(searchMetadata ? "search-song-\(index)" : song.key)
                    SongActions(song: song, collectionID: collectionID, onChange: onChange)
                }.padding(.vertical, 11).onAppear { if index == 0 { onFirstVisible() } }
                Divider().padding(.leading, 65).opacity(0.4)
            }
        }
    }
    private func searchPlaybackStatus(_ song: Song) -> String {
        guard song.sourceAvailable else { return "来源不可用 · 可尝试换源" }
        guard audio.currentSong?.key == song.key else { return song.isVIP == true ? "可能需要会员 · 点播验证" : "点播验证可用性" }
        switch audio.playbackState {
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .error: return "播放失败 · 可尝试换源"
        case .preparing, .buffering, .recovering: return "正在连接音频…"
        case .interrupted: return "播放暂时中断"
        case .ready: return "音频已就绪"
        case .idle: return "点播验证可用性"
        }
    }

}

struct SongActions: View {
    let song: Song
    var collectionID: String? = nil
    var onChange: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var client: NativeClient
    @State private var deleteFile = false
    @State private var showAlbum = false
    @State private var showSourceSwitch = false
    var body: some View {
        Menu {
            Button("接下来播放", systemImage: "text.line.first.and.arrowtriangle.forward") { audio.append(song, playNext: true); model.notify("已加入下一首") }.disabled(!song.sourceAvailable)
            Button("加入播放队列", systemImage: "text.append") { audio.append(song); model.notify("已加入播放队列") }.disabled(!song.sourceAvailable)
            Button("加入我喜欢的音乐", systemImage: "heart") { model.perform { try await model.favorite(song) } }
            if !client.collections.isEmpty {
                Menu("添加到歌单", systemImage: "plus.rectangle.on.folder") {
                    ForEach(client.collections, id: \.id) { collection in
                        Button(collection.name) { model.perform { try await client.addToCollection(id: collection.id, song: song); model.notify("已加入歌单") } }
                    }
                }
            }
            Button("下载原音质", systemImage: "arrow.down.circle") { model.perform { try await client.enqueueDownload([song]); model.notify("已加入下载任务") } }.disabled(!song.sourceAvailable)
            Button("尝试其他音源", systemImage: "arrow.triangle.2.circlepath") { showSourceSwitch = true }
            if let albumID = song.albumID, !albumID.isEmpty { Button("查看专辑", systemImage: "square.stack") { showAlbum = true } }
            if !song.album.isEmpty { Text("专辑：\(song.album)") }
            if let collectionID {
                Button("从歌单移除", systemImage: "minus.circle", role: .destructive) {
                    model.perform { try await client.removeFromCollection(id: collectionID, song: song); onChange(); model.notify("已从歌单移除") }
                }
            }
            if ["local", "local-file"].contains(song.source) {
                Button("删除本地文件", systemImage: "trash", role: .destructive) { deleteFile = true }
            }
        } label: {
            Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("\(song.name)的更多操作").foregroundStyle(.secondary)
            .sheet(isPresented: $showSourceSwitch) { NavigationStack { SourceSwitchScreen(original: song) } }
            .sheet(isPresented: $showAlbum) { NavigationStack { SongDetailScreen(title: song.album, kind: "album", id: song.albumID ?? "", source: song.source, cover: song.cover) } }
            .confirmationDialog("删除本地文件“\(song.name)”？此操作无法撤销。", isPresented: $deleteFile, titleVisibility: .visible) {
                Button("删除音频文件", role: .destructive) { model.perform { if audio.currentSong?.key == song.key { audio.stop() }; try await client.deleteLocalSong(id: song.id); onChange(); model.notify("本地文件已删除") } }
            }
    }
}

struct SongDetailScreen: View {
    let title: String
    let kind: String
    let id: String
    let source: String
    var cover = ""
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var attempt = 0
    @State private var loadGeneration = UUID()
    @State private var enteredAt = Date()
    @State private var firstRowReported = false
    @State private var importSheet = false
    @State private var addSheet = false
    private var editable: Bool { kind == "collection" && (client.collections.first { $0.id == id }?.kind ?? "manual") != "imported" }
    private var requestKey: String { source + "\n" + kind + "\n" + id }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CoverArt(url: cover, title: title, radius: 27).frame(width: 224, height: 224).shadow(color: .black.opacity(0.12), radius: 22, y: 12).padding(.top, 18)
                VStack(spacing: 8) {
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("\(source.uppercased()) · \(songs.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
                }
                if editable {
                    VStack(spacing: 10) {
                        Button { addSheet = true } label: { Label("添加其他歌曲", systemImage: "music.note.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 7) }
                            .accessibilityIdentifier("playlist-add-songs")
                        Button { importSheet = true } label: { Label("导入其他软件的歌单", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 7) }
                            .accessibilityIdentifier("playlist-import")
                    }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
                }
                if !songs.isEmpty {
                    HStack(spacing: 14) {
                        Button { model.play(songs) } label: { Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).foregroundStyle(MusicDesign.onAccent)
                        Button { model.play(songs.shuffled()) } label: { Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.bordered)
                    }.buttonBorderShape(.roundedRectangle(radius: 16))
                }
                if loading && songs.isEmpty { ProgressView("正在读取曲目…").padding(30) }
                if let problem {
                    if songs.isEmpty { NativeEmptyState(symbol: "wifi.exclamationmark", title: "暂时无法读取", detail: problem) }
                    else { Text(problem).font(.caption).foregroundStyle(.secondary) }
                    Button("重试") { attempt += 1 }
                }
                if !loading && songs.isEmpty && problem == nil { NativeEmptyState(symbol: "music.note.list", title: "这里还没有歌曲", detail: "添加一些喜欢的声音，让它成为你的收藏。") }
                SongRows(songs: songs, collectionID: kind == "collection" ? id : nil, onChange: { attempt += 1 }, onFirstVisible: {
                    guard !firstRowReported else { return }; firstRowReported = true
                    #if DEBUG
                    print("[native-detail] first-row-rendered=\(Date().timeIntervalSince(enteredAt))s")
                    #endif
                })
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.background(MusicDesign.canvas(scheme)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { model.perform { try await client.enqueueDownload(songs); model.notify("已加入下载任务") } } label: { Image(systemName: "arrow.down.circle") }.disabled(songs.isEmpty).accessibilityLabel("下载全部") } }
            .task(id: requestKey + "\n\(attempt)") { await load() }
            .refreshable { await load(force: true) }
            .sheet(isPresented: $addSheet) {
                NavigationStack {
                    SongSelectionScreen(existing: Set(songs.map { $0.source + ":" + $0.id })) { selected in
                        let result = try await client.addSongsToCollection(id: id, songs: selected)
                        attempt += 1
                        do { try await client.loadLibrary() } catch { model.notify("歌曲已保存，歌单数量将在刷新后更新") }
                        model.notify("已添加 \(result.added) 首，跳过重复 \(result.duplicates) 首")
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { addSheet = false } } }
                }
            }
            .sheet(isPresented: $importSheet, onDismiss: { attempt += 1 }) {
                NavigationStack {
                    PlaylistImportView(collectionID: id, onChange: { attempt += 1 })
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { importSheet = false } } }
                }
            }
    }
    private func load(force: Bool = false) async {
        let token = UUID(); loadGeneration = token
        enteredAt = Date(); firstRowReported = false
        loading = true; problem = nil
        let entered = Date()
        if let cached = client.cachedDetail(kind: kind, id: id, source: source) {
            songs = cached.songs
            #if DEBUG
            print("[native-detail] cache=hit first-visible=\(Date().timeIntervalSince(entered))s count=\(songs.count)")
            #endif
        } else { songs = [] }
        defer { if token == loadGeneration { loading = false } }
        do {
            let page = try await client.detailPage(kind: kind, id: id, source: source, force: force || attempt > 0)
            guard !Task.isCancelled, token == loadGeneration else { return }
            songs = page.songs
            problem = page.partial ? page.warnings.joined(separator: "\n") : nil
            #if DEBUG
            print("[native-detail] first-visible-and-complete=\(Date().timeIntervalSince(entered))s count=\(songs.count) partial=\(page.partial)")
            #endif
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, token == loadGeneration else { return }
            problem = songs.isEmpty ? "曲目暂时无法读取，请重试。" : "刷新失败，正在显示已缓存的曲目。"
            #if DEBUG
            print("[native-detail] failed elapsed=\(Date().timeIntervalSince(entered))s error=\(error)")
            #endif
        }
    }
}

struct CollectionDetailScreen: View {
    let collection: NativeCollection
    let kind: String
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    var body: some View {
        SongDetailScreen(title: collection.name, kind: kind, id: collection.id, source: collection.source, cover: collection.cover)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                if kind != "collection" { Button { model.perform { try await client.importCollection(collection, kind: kind); model.notify("已收藏到音乐库") } } label: { Image(systemName: "plus.circle") }.accessibilityLabel("收藏到音乐库") }
            } }
    }
}

struct LibraryScreen: View {
    @Environment(\.musicAccent) private var accent
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var newCollection = false
    @State private var name = ""
    @State private var importing = false
    @State private var deleting: NativeCollection?
    @State private var renaming: NativeCollection?
    var body: some View {
        List {
            Section {
                NavigationLink { LocalMusicScreen() } label: { Label("本地音乐", systemImage: "music.note.house") }
                NavigationLink { DownloadsScreen() } label: { Label("下载管理", systemImage: "arrow.down.circle") }
                NavigationLink { UserPlaylistsScreen() } label: { Label("平台账号歌单", systemImage: "person.2.crop.square.stack") }
                Button { importing = true } label: { Label("导入音频文件", systemImage: "square.and.arrow.down") }
            }
            Section {
                if client.collections.isEmpty {
                    NativeEmptyState(symbol: "square.stack", title: "把喜欢的声音留下", detail: "收藏歌曲，或者创建你的第一张歌单。")
                        .listRowBackground(Color.clear)
                }
                ForEach(client.collections, id: \.id) { collection in
                    NavigationLink { CollectionDetailScreen(collection: collection, kind: "collection") } label: {
                        HStack(spacing: 14) {
                            CoverArt(url: collection.cover, title: collection.name, radius: 12).frame(width: 62, height: 62)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(collection.name).font(.headline)
                                Text("\(collection.trackCount) 首 · 我的歌单").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }.swipeActions {
                        Button("删除", role: .destructive) { deleting = collection }
                        Button("改名") { name = collection.name; renaming = collection }.tint(accent)
                    }
                }
            } header: { HStack { Text("我的歌单"); Spacer(); Text("\(client.collections.count)") } }
        }.scrollContentBackground(.hidden).background(MusicDesign.canvas(scheme)).navigationTitle("音乐库")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { newCollection = true } label: { Image(systemName: "plus") }.accessibilityLabel("创建歌单") } }
            .alert("新建歌单", isPresented: $newCollection) {
                TextField("歌单名称", text: $name)
                Button("创建") { model.perform { _ = try await client.createCollection(name: name); name = "" } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.perform { for url in urls { try await client.importLocalFile(url: url) }; model.notify("已导入本地音乐") } }
                else if case .failure(let error) = result { model.notify(error.localizedDescription) }
            }
            .confirmationDialog("删除歌单？歌曲文件会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let deleting { Button("删除“\(deleting.name)”", role: .destructive) { model.perform { try await client.deleteCollection(id: deleting.id); self.deleting = nil } } }
            }
            .alert("重命名歌单", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("歌单名称", text: $name)
                Button("保存") { if let renaming { model.perform { _ = try await client.request("collections.update", params: ["id": .string(renaming.id), "name": .string(name)]); try await client.loadLibrary(); self.renaming = nil } } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消", role: .cancel) { renaming = nil }
            }
            .task { model.perform { try await client.loadLibrary() } }.refreshable { try? await client.loadLibrary() }
    }
}

struct LocalMusicScreen: View {
    @EnvironmentObject private var client: NativeClient
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            if client.localSongs.isEmpty { NativeEmptyState(symbol: "music.note.house", title: "还没有本地音乐", detail: "在音乐库导入音频，或下载已获授权的歌曲。") }
            SongRows(songs: client.localSongs).padding(.horizontal, 22)
        }.background(MusicDesign.canvas(scheme)).navigationTitle("本地音乐")
            .task { try? await client.loadLocalMusic() }.refreshable { try? await client.loadLocalMusic() }
    }
}

struct DownloadsScreen: View {
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        List {
            if client.downloads.isEmpty { NativeEmptyState(symbol: "arrow.down.circle", title: "下载列表很安静", detail: "从歌曲菜单选择下载，任务会出现在这里。") }
            ForEach(client.downloads, id: \.id) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(item.name).font(.headline); Spacer(); Text(item.status).font(.caption).foregroundStyle(.secondary) }
                    Text(item.artist).font(.caption).foregroundStyle(.secondary)
                    if !item.error.isEmpty { Text(item.error).font(.caption).foregroundStyle(.red) }
                    if !item.warning.isEmpty { Text(item.warning).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("重试") { action(item.id, "retry") }
                        Button("取消任务") { action(item.id, "cancel") }
                        if !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path) { ShareLink("导出文件", item: URL(fileURLWithPath: item.path)) }
                        Spacer()
                        Button(role: .destructive) { model.perform { try await client.removeDownload(id: item.id) } } label: { Image(systemName: "trash") }
                    }.buttonStyle(.borderless).font(.caption)
                }.padding(.vertical, 8)
            }
        }.scrollContentBackground(.hidden).background(MusicDesign.canvas(scheme)).navigationTitle("下载管理")
            .task { try? await client.loadDownloads() }
            .refreshable { try? await client.loadDownloads() }
    }
    private func action(_ id: Int, _ name: String) { model.perform { try await client.downloadAction(id: id, action: name) } }
}
