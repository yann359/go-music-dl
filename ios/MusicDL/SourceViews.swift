import SwiftUI

struct SourceBrowserScreen: View {
    @EnvironmentObject private var client: NativeClient
    var body: some View {
        List(client.sources, id: \.id) { source in
            NavigationLink { PlatformScreen(source: source) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(source.name).font(.headline)
                    Text([source.recommend ? "推荐" : nil, source.toplist ? "排行榜" : nil, source.category ? "分类" : nil, source.userPlaylists ? "账号歌单" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        }.navigationTitle("音乐来源")
    }
}

struct PlatformScreen: View {
    let source: NativeSource
    @EnvironmentObject private var client: NativeClient
    @State private var playlists: [NativeCollection] = []
    @State private var charts: [NativeTopList] = []
    @State private var categories: [NativeCategory] = []
    @State private var problem: String?
    @State private var loading = false
    var body: some View {
        List {
            if loading { ProgressView("正在连接\(source.name)…") }
            if let problem { Section { Text(problem).font(.subheadline).foregroundStyle(.secondary); Button("重试") { Task { await load() } } } }
            if source.userPlaylists { NavigationLink("我的平台歌单") { UserPlaylistsScreen(initialSource: source.id) } }
            if !playlists.isEmpty { Section("推荐歌单") { ForEach(playlists, id: \.key) { item in NavigationLink(item.name) { CollectionDetailScreen(collection: item, kind: "playlist") } } } }
            if !charts.isEmpty { Section("排行榜") { ForEach(charts, id: \.key) { item in NavigationLink(item.name) { SongDetailScreen(title: item.name, kind: "toplist", id: item.id, source: source.id, cover: item.cover) } } } }
            if !categories.isEmpty { Section("歌单分类") { ForEach(categories, id: \.key) { item in NavigationLink(item.name) { CategoryPlaylistsScreen(source: source.id, category: item) } } } }
            if !loading && playlists.isEmpty && charts.isEmpty && categories.isEmpty && problem == nil { NativeEmptyState(symbol: "music.note", title: "从搜索开始", detail: "这个来源没有声明可浏览的推荐或榜单能力。你仍可在搜索页选择它。") }
        }.navigationTitle(source.name).task { await load() }
    }
    private func load() async {
        loading = true; problem = nil; defer { loading = false }
        var errors: [String] = []
        if source.recommend { do { let value = try await client.recommendations(sources: [source.id]); playlists = value.playlists; errors += value.errors } catch { errors.append(error.localizedDescription) } }
        if source.toplist { do { charts = try await client.topLists(sources: [source.id]) } catch { errors.append(error.localizedDescription) } }
        if source.category { do { categories = try await client.categories(source: source.id) } catch { errors.append(error.localizedDescription) } }
        problem = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

struct UserPlaylistsScreen: View {
    var initialSource = ""
    @EnvironmentObject private var client: NativeClient
    @State private var source = ""
    @State private var values: [NativeCollection] = []
    @State private var page = 1
    @State private var loading = false
    @State private var problem: String?
    var body: some View {
        List {
            Picker("音乐来源", selection: $source) { ForEach(client.sources.filter { $0.userPlaylists }, id: \.id) { Text($0.name).tag($0.id) } }
                .onChange(of: source) { _, _ in page = 1; Task { await load() } }
            if loading { ProgressView("正在读取账号歌单…") }
            if let problem { Text(problem).foregroundStyle(.secondary); NavigationLink("配置平台账号") { AccountsScreen() }; Button("重试") { Task { await load() } } }
            ForEach(values, id: \.key) { value in NavigationLink(value.name) { CollectionDetailScreen(collection: value, kind: "playlist") } }
            if !values.isEmpty { Button("加载更多") { page += 1; Task { await load() } }.disabled(loading) }
            if values.isEmpty && !loading && problem == nil { NativeEmptyState(symbol: "person.crop.circle", title: "还没有读取到歌单", detail: "先配置对应平台的账号，或选择其他音乐来源。") }
        }.navigationTitle("平台歌单").task { source = initialSource.isEmpty ? (client.sources.first { $0.userPlaylists }?.id ?? "") : initialSource; if !source.isEmpty { await load() } }
    }
    private func load() async {
        guard !source.isEmpty && !loading else { return }; loading = true; problem = nil
        defer { loading = false }
        do { let next = try await client.userPlaylists(source: source, page: page); if page == 1 { values = next } else { let existing = Set(values.map(\.key)); values += next.filter { !existing.contains($0.key) } } }
        catch { problem = error.localizedDescription }
    }
}

struct CategoryPlaylistsScreen: View {
    let source: String
    let category: NativeCategory
    @EnvironmentObject private var client: NativeClient
    @State private var values: [NativeCollection] = []
    @State private var page = 1
    @State private var problem: String?
    @State private var loading = false
    var body: some View {
        List {
            if loading { ProgressView("正在读取分类…") }
            if let problem { Text(problem).foregroundStyle(.secondary); Button("重试") { Task { await load() } } }
            ForEach(values, id: \.key) { value in NavigationLink(value.name) { CollectionDetailScreen(collection: value, kind: "playlist") } }
            if !values.isEmpty { Button("加载更多") { page += 1; Task { await load() } }.disabled(loading) }
        }.navigationTitle(category.name).task { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { let next = try await client.categoryPlaylists(source: source, id: category.id, page: page); if page == 1 { values = next } else { let keys = Set(values.map(\.key)); values += next.filter { !keys.contains($0.key) } }; problem = nil }
        catch { problem = error.localizedDescription }
    }
}
