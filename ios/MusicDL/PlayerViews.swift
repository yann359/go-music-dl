import SwiftUI
import AVKit

struct MiniPlayer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    var body: some View {
        if let song = audio.currentSong {
            HStack(spacing: 12) {
                Button { model.showPlayer = true } label: { HStack(spacing: 12) {
                    CoverArt(url: song.cover, title: song.name, radius: 9).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(audio.waiting ? "正在准备音频…" : song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            audio.skip(value.translation.width < 0 ? 1 : -1)
                        }
                    })
                    .accessibilityLabel("展开播放器")
                    .accessibilityHint("\(song.name)，\(song.artist)")
                    .accessibilityIdentifier("open-player")
                Button { audio.isPlaying || audio.waiting ? audio.pause() : audio.play() } label: {
                    Image(systemName: audio.isPlaying || audio.waiting ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(audio.isPlaying || audio.waiting ? "暂停" : "播放")
                    .accessibilityValue(audio.isPlaying ? "正在播放" : audio.waiting ? "正在准备" : "已暂停")
                Button { audio.skip(1) } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 40, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("下一首")
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

struct FullPlayer: View {
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var client: NativeClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var draftPosition: Double = 0
    @State private var seeking = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricError: String?
    @State private var lyricLoading = false
    @State private var lyricAttempt = 0
    @State private var rate: Double = 1
    private var song: Song? { audio.currentSong }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MusicDesign.canvas(scheme)
                LinearGradient(colors: CoverArt.palette(song?.name ?? "澄音").map { $0.opacity(scheme == .dark ? 0.4 : 0.13) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        if page == 0 {
                            CoverArt(url: song?.cover ?? "", title: song?.name ?? "澄音", radius: 30)
                                .frame(width: min(geometry.size.width - 52, 370), height: min(geometry.size.width - 52, geometry.size.height * 0.43, 370))
                                .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.16), radius: 24, y: 16)
                                .scaleEffect(audio.isPlaying || reduceMotion ? 1 : 0.94)
                                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: audio.isPlaying)
                        } else if page == 1 {
                            LyricsPane(lines: lyrics, position: audio.position, loading: lyricLoading, error: lyricError, retry: { lyricAttempt += 1 }) { audio.seek($0) }
                                .frame(height: min(geometry.size.height * 0.43, 380))
                        } else {
                            QueuePane().frame(height: min(geometry.size.height * 0.43, 380))
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(song?.name ?? "选择一首喜欢的歌").font(.title2.bold()).lineLimit(2)
                                    Text(song?.artist ?? "让声音陪着你").font(.body).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let song {
                                    Button { model.perform { try await model.favorite(song) } } label: {
                                        Image(systemName: "heart").font(.title3).frame(width: 44, height: 44)
                                    }.buttonStyle(.plain).accessibilityLabel("收藏当前歌曲")
                                    SongActions(song: song)
                                }
                            }
                            HStack(spacing: 7) {
                                Image(systemName: "waveform.path").font(.caption)
                                Text(audio.waiting ? "正在缓存原音频" : (song?.source.uppercased() ?? "原生播放"))
                                    .font(.caption.weight(.medium)).tracking(0.8)
                                if client.isOfflinePreview { Text("· 界面样例").font(.caption) }
                            }.foregroundStyle(.secondary)
                        }
                        VStack(spacing: 4) {
                            Slider(value: $draftPosition, in: 0...max(1, audio.duration > 0 ? audio.duration : Double(song?.duration ?? 0)), onEditingChanged: { editing in
                                seeking = editing
                                if !editing { audio.seek(draftPosition) }
                            }).accessibilityLabel("播放进度")
                            HStack {
                                Text(Self.time(seeking ? draftPosition : audio.position)); Spacer()
                                Text("−" + Self.time(max(0, audio.duration - audio.position)))
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 42) {
                            Button { audio.skip(-1) } label: { Image(systemName: "backward.end.fill").font(.system(size: 26)).frame(width: 48, height: 60) }.accessibilityLabel("上一首")
                            Button { audio.isPlaying || audio.waiting ? audio.pause() : audio.play() } label: {
                                Image(systemName: audio.isPlaying || audio.waiting ? "pause.fill" : "play.fill")
                                    .font(.system(size: 36, weight: .medium)).frame(width: 78, height: 78)
                            }.accessibilityLabel(audio.isPlaying || audio.waiting ? "暂停" : "播放")
                            Button { audio.skip(1) } label: { Image(systemName: "forward.end.fill").font(.system(size: 26)).frame(width: 48, height: 60) }.accessibilityLabel("下一首")
                        }.buttonStyle(.plain).foregroundStyle(.primary)
                        controls
                        Text(audio.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 28)
                }.scrollIndicators(.hidden)
            }.ignoresSafeArea(edges: .bottom)
        }.onAppear { draftPosition = audio.position; rate = Double(audio.playbackRate) }
            .onChange(of: audio.position) { _, value in if !seeking { draftPosition = value } }
            .task(id: (song?.key ?? "") + ":\(lyricAttempt)") { await loadLyrics() }
            .accessibilityIdentifier("full-player")
    }
    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
            Spacer()
            VStack(spacing: 3) {
                Text("正在播放").font(.caption).foregroundStyle(.secondary)
                Text(song?.album.isEmpty == false ? song!.album : "澄音 · 此刻的声音").font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("播放速度", selection: $rate) { ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in Text("\(value, specifier: "%g")×").tag(value) } }
                Button(audio.orderMode == "random" ? "关闭随机播放" : "随机播放", systemImage: "shuffle") { audio.setMode(loop: "all", order: audio.orderMode == "random" ? "list" : "random") }
                Button(audio.loopMode == "one" ? "列表循环" : "单曲循环", systemImage: "repeat.1") { audio.setMode(loop: audio.loopMode == "one" ? "all" : "one", order: "list") }
            } label: { Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("播放选项")
                .onChange(of: rate) { _, value in audio.handle(PlaybackRequest(action: "rate", value: value)) }
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
    private var controls: some View {
        GlassControls {
            HStack(spacing: 26) {
                Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { page = page == 1 ? 0 : 1 } } label: {
                    Image(systemName: "quote.bubble").font(.title3).frame(width: 48, height: 46)
                }.foregroundStyle(page == 1 ? MusicDesign.coral : .primary).accessibilityLabel("歌词")
                RoutePicker().frame(width: 48, height: 46).accessibilityLabel("音频输出设备")
                Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { page = page == 2 ? 0 : 2 } } label: {
                    Image(systemName: "list.bullet").font(.title3).frame(width: 48, height: 46)
                }.foregroundStyle(page == 2 ? MusicDesign.coral : .primary).accessibilityLabel("播放队列")
            }.padding(.horizontal, 14).padding(.vertical, 4).musicGlass().buttonStyle(.plain)
        }
    }
    private func loadLyrics() async {
        lyrics = []; lyricError = nil
        guard let song else { return }
        lyricLoading = true
        defer { if !Task.isCancelled { lyricLoading = false } }
        do {
            let text = try await client.lyrics(for: song)
            if !Task.isCancelled {
                lyrics = LyricLine.parse(text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lyrics.isEmpty {
                    lyricError = "歌词内容暂时无法读取，请重试。"
                }
            }
        } catch let error as LyricLoadError {
            if !Task.isCancelled { lyricError = error.localizedDescription }
        } catch {
            if !Task.isCancelled { lyricError = "请检查网络后重试，音乐播放不受影响。" }
        }
    }
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct QueuePane: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var clear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("播放队列 · \(audio.songs.count)").font(.headline)
                Spacer()
                Button("清空", role: .destructive) { clear = true }.font(.caption)
            }.padding(.horizontal, 4)
            List {
                ForEach(Array(audio.songs.enumerated()), id: \.offset) { index, song in
                    Button { audio.playSongs(audio.songs, at: index) } label: {
                        HStack(spacing: 10) {
                            CoverArt(url: song.cover, title: song.name, radius: 8).frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 4) { Text(song.name).font(.subheadline).lineLimit(1); Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            if index == audio.index { Image(systemName: "waveform").foregroundStyle(MusicDesign.coral) }
                        }
                    }.buttonStyle(.plain).listRowBackground(Color.clear)
                }.onMove { audio.move(from: $0, to: $1) }.onDelete { audio.remove(at: $0) }
            }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.editMode, .constant(.active))
        }.confirmationDialog("清空当前播放队列？", isPresented: $clear, titleVisibility: .visible) { Button("清空队列并停止播放", role: .destructive) { audio.stop() } }
    }
}

struct LyricsPane: View {
    let lines: [LyricLine]
    let position: Double
    let loading: Bool
    let error: String?
    let retry: () -> Void
    let seek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Int? { lines.last(where: { ($0.time ?? .infinity) <= position })?.id }
    var body: some View {
        if loading { ProgressView("正在读取歌词…") }
        else if let error {
            VStack(spacing: 12) {
                NativeEmptyState(symbol: "text.bubble", title: "歌词暂时不可用", detail: error)
                Button("重试歌词", action: retry).buttonStyle(.bordered)
            }
        }
        else if lines.isEmpty { NativeEmptyState(symbol: "quote.bubble", title: "暂无歌词", detail: "这首歌暂时没有可用歌词。") }
        else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        if lines.first?.time == nil { Text("全文歌词 · 无同步时间信息").font(.caption).foregroundStyle(.secondary) }
                        ForEach(lines) { line in
                            Button { if let time = line.time { seek(time) } } label: {
                                Text(line.text).font(.title2.bold()).lineSpacing(6).multilineTextAlignment(.leading)
                                    .foregroundStyle(line.time == nil || line.id == active ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).disabled(line.time == nil).id(line.id)
                        }
                    }.padding(.vertical, 35)
                }.scrollIndicators(.hidden).onChange(of: active) { _, value in
                    if let value { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(value, anchor: .center) } }
                }
            }
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = UIColor(MusicDesign.coral)
        view.tintColor = .label
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
