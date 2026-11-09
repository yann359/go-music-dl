import SwiftUI
import UniformTypeIdentifiers

struct DiscoverScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var client: NativeClient
    @Environment(\.colorScheme) private var scheme
    @State private var playlists: [NativeCollection] = []
    @State private var charts: [NativeTopList] = []
    @State private var songs: [Song] = []
    @State private var loading = false
    @State private var problem: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text("CHENGYIN / MUSICDL").font(.caption2.weight(.semibold)).tracking(2.4).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "waveform.path").foregroundStyle(MusicDesign.coral)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("给此刻，\n一点好声音。").font(.system(size: 39, weight: .semibold, design: .rounded))
                        .tracking(-1.8).fixedSize(horizontal: false, vertical: true)
                    Text("从熟悉的旋律，到下一次心动。\n连接你的音乐来源，慢慢发现。").font(.subheadline).lineSpacing(5).foregroundStyle(.secondary)
                    Button { model.selectedTab = 1 } label: {
                        Label("寻找一首歌", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 13)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
                    .background(MusicDesign.panel(scheme), in: RoundedRectangle(cornerRadius: 30))
                if loading { HStack { ProgressView(); Text("正在连接音乐来源…").font(.subheadline).foregroundStyle(.secondary) } }
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
                if let problem {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("部分来源暂时无法连接", systemImage: "antenna.radiowaves.left.and.right.slash").font(.subheadline.weight(.medium))
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load() } }.font(.subheadline)
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
            .refreshable { await load() }.task { if playlists.isEmpty { await load() } }
    }
    private func sourceName(_ source: String) -> String { client.sources.first { $0.id == source }?.name ?? source }
    private func load() async {
        guard !loading else { return }; loading = true; problem = nil
        defer { loading = false }
        do {
            let result = try await client.recommendations(sources: ["netease", "qq"])
            playlists = result.playlists; songs = result.songs
            if !result.errors.isEmpty { problem = result.errors.joined(separator: "\n") }
        } catch { problem = error.localizedDescription }
        do { charts = try await client.topLists(sources: ["netease"]) }
        catch { if problem == nil { problem = error.localizedDescription } }
    }
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var kind = "song"
    @State private var selected = Set<String>()
    @State private var result: NativeSearchResult?
    @State private var loading = false
    @State private var problem: String?
    @State private var sourceSheet = false
    @State private var revision = 0
    @AppStorage("music.search.recent") private var recentJSON = "[]"
    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: Data(recentJSON.utf8))) ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("搜索类型", selection: $kind) {
                    Text("歌曲").tag("song"); Text("专辑").tag("album"); Text("歌单").tag("playlist")
                }.pickerStyle(.segmented).onChange(of: kind) { _, _ in if !query.isEmpty { Task { await search() } } }
                HStack {
                    Text(selected.isEmpty ? "全部默认来源" : "已选 \(selected.count) 个来源").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { sourceSheet = true } label: { Label("音源", systemImage: "line.3.horizontal.decrease") }.font(.subheadline)
                }
                if loading { ProgressView("正在搜索…").frame(maxWidth: .infinity).padding(.vertical, 32) }
                if let problem { NativeEmptyState(symbol: "wifi.exclamationmark", title: "搜索遇到了一点问题", detail: problem); Button("重试") { Task { await search() } } }
                if let result {
                    if !result.songs.isEmpty { SongRows(songs: result.songs) }
                    if !result.playlists.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 24) {
                            ForEach(result.playlists, id: \.identityKey) { collection in
                                NavigationLink { CollectionDetailScreen(collection: collection, kind: kind) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        CoverArt(url: collection.cover, title: collection.name, radius: 20).aspectRatio(1, contentMode: .fit)
                                        Text(collection.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(collection.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if result.songs.isEmpty && result.playlists.isEmpty && !loading {
                        NativeEmptyState(symbol: "magnifyingglass", title: "没有找到这段旋律", detail: "试试歌名、歌手，或切换音乐来源。")
                    }
                    if !result.errors.isEmpty { Text(result.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }
                } else if !loading && problem == nil {
                    NativeEmptyState(symbol: "waveform.path", title: "你想听见什么？", detail: "歌名、歌手、专辑，或一张珍藏的歌单。")
                    if !recent.isEmpty {
                        HStack { SectionHeading(title: "最近搜索"); Button("清空") { recentJSON = "[]" }.font(.caption) }
                        ForEach(recent, id: \.self) { term in
                            Button { query = term; Task { await search() } } label: {
                                HStack { Image(systemName: "clock.arrow.circlepath"); Text(term); Spacer(); Image(systemName: "arrow.up.left") }.padding(.vertical, 10)
                            }.foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(22)
        }.background(MusicDesign.canvas(scheme)).navigationTitle("搜索")
            .searchable(text: $query, prompt: "歌曲、歌手、专辑与歌单")
            .onSubmit(of: .search) { Task { await search() } }
            .sheet(isPresented: $sourceSheet) {
                NavigationStack {
                    List(client.sources.filter { $0.search }, id: \.id) { source in
                        Button {
                            if selected.contains(source.id) { selected.remove(source.id) } else { selected.insert(source.id) }
                        } label: {
                            HStack { Text(source.name).foregroundStyle(.primary); Spacer(); if selected.contains(source.id) { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }.navigationTitle("选择音乐来源")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sourceSheet = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { result = nil; return }
        revision += 1; let token = revision; loading = true; problem = nil
        do {
            let value = try await client.search(query: term, type: kind, sources: selected.sorted())
            guard revision == token else { return }; result = value
            recentJSON = String(decoding: (try? JSONEncoder().encode(Array(([term] + recent.filter { $0 != term }).prefix(8)))) ?? Data("[]".utf8), as: UTF8.self)
        } catch { if revision == token { problem = error.localizedDescription } }
        if revision == token { loading = false }
    }
}

struct SongRows: View {
    let songs: [Song]
    var collectionID: String? = nil
    var onChange: () -> Void = {}
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
                                Text(song.name).font(.body.weight(.medium)).foregroundStyle(audio.currentSong?.key == song.key ? MusicDesign.coral : .primary).lineLimit(1)
                                Text([song.artist, song.source.uppercased()].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    SongActions(song: song, collectionID: collectionID, onChange: onChange)
                }.padding(.vertical, 11)
                Divider().padding(.leading, 65).opacity(0.4)
            }
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
    var body: some View {
        Menu {
            Button("接下来播放", systemImage: "text.line.first.and.arrowtriangle.forward") { audio.append(song, playNext: true); model.notify("已加入下一首") }
            Button("加入播放队列", systemImage: "text.append") { audio.append(song); model.notify("已加入播放队列") }
            Button("加入我喜欢的音乐", systemImage: "heart") { model.perform { try await model.favorite(song) } }
            if !client.collections.isEmpty {
                Menu("添加到歌单", systemImage: "plus.rectangle.on.folder") {
                    ForEach(client.collections, id: \.id) { collection in
                        Button(collection.name) { model.perform { try await client.addToCollection(id: collection.id, song: song); model.notify("已加入歌单") } }
                    }
                }
            }
            Button("下载原音质", systemImage: "arrow.down.circle") { model.perform { try await client.enqueueDownload([song]); model.notify("已加入下载任务") } }
            Button("尝试其他音源", systemImage: "arrow.triangle.2.circlepath") {
                model.perform { let replacement = try await client.switchSource(song); audio.replaceCurrentSource(replacement, expectedKey: song.key); model.notify("已切换至 \(replacement.source)") }
            }
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
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CoverArt(url: cover, title: title, radius: 27).frame(width: 224, height: 224).shadow(color: .black.opacity(0.12), radius: 22, y: 12).padding(.top, 18)
                VStack(spacing: 8) {
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("\(source.uppercased()) · \(songs.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
                }
                if !songs.isEmpty {
                    HStack(spacing: 14) {
                        Button { model.play(songs) } label: { Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent)
                        Button { model.play(songs.shuffled()) } label: { Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.bordered)
                    }.buttonBorderShape(.roundedRectangle(radius: 16))
                }
                if loading { ProgressView("正在读取曲目…").padding(30) }
                if let problem { NativeEmptyState(symbol: "wifi.exclamationmark", title: "暂时无法读取", detail: problem); Button("重试") { Task { await load() } } }
                if !loading && songs.isEmpty && problem == nil { NativeEmptyState(symbol: "music.note.list", title: "这里还没有歌曲", detail: "添加一些喜欢的声音，让它成为你的收藏。") }
                SongRows(songs: songs, collectionID: kind == "collection" ? id : nil, onChange: { Task { await load() } })
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.background(MusicDesign.canvas(scheme)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { model.perform { try await client.enqueueDownload(songs); model.notify("已加入下载任务") } } label: { Image(systemName: "arrow.down.circle") }.disabled(songs.isEmpty).accessibilityLabel("下载全部") } }
            .task { await load() }
    }
    private func load() async { loading = true; problem = nil; defer { loading = false }; do { songs = try await client.detail(kind: kind, id: id, source: source) } catch { problem = error.localizedDescription } }
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
                        Button("改名") { name = collection.name; renaming = collection }.tint(MusicDesign.coral)
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
