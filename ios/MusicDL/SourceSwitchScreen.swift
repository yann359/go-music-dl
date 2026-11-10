import SwiftUI

struct NativeSwitchOption: Identifiable {
    let song: Song
    let score: Double
    let durationDifference: Int
    var id: String { song.key }
}

struct SourceSwitchScreen: View {
    let original: Song
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var options: [NativeSwitchOption] = []
    @State private var errors: [String] = []
    @State private var failures: [String: String] = [:]
    @State private var loading = true
    @State private var verifying: String?
    @State private var attempt = 0
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text(original.name).font(.headline)
                Text("比较歌名、歌手、时长与版本。选择候选后会真实检查音频地址；通过后交给现有播放器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("正在寻找相同版本…") }
            else if options.isEmpty {
                Text("暂未找到匹配的其他来源，没有切换播放。")
                Button("重试") { attempt += 1 }
            }
            ForEach(options) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        CoverArt(url: option.song.cover, title: option.song.name, radius: 10).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.song.name).foregroundStyle(.primary)
                            Text("\(option.song.artist) · \(option.song.source.uppercased())").font(.caption).foregroundStyle(.secondary)
                            Text("匹配 \(Int(option.score * 100))% · \(option.song.duration > 0 && original.duration > 0 ? "时长相差 \(option.durationDifference) 秒" : "时长待确认") · 待验证音频")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let failure = failures[option.id] { Text(failure).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        if verifying == option.id { ProgressView() }
                    }
                }.disabled(verifying != nil)
            }
            if !errors.isEmpty { Section("部分来源暂不可用") { Text(errors.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) } }
        }.navigationTitle("选择其他音源")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: attempt) {
                loading = true; errors = []
                do {
                    let value = try await client.sourceCandidates(for: original)
                    try Task.checkCancellation()
                    options = value.options; errors = value.errors
                } catch is CancellationError { return }
                catch { errors = [error.localizedDescription] }
                loading = false
            }
            .onDisappear { validationTask?.cancel() }
    }

    private func choose(_ option: NativeSwitchOption) {
        verifying = option.id
        let expected = audio.currentSong?.key
        validationTask = Task {
            defer { verifying = nil }
            do {
                let replacement = try await client.validateSource(option.song, original: original)
                try Task.checkCancellation()
                guard audio.currentSong?.key == expected else { throw NativeError.message("播放队列已变化，请重新选择。") }
                if expected == original.key { audio.replaceCurrentSource(replacement, expectedKey: original.key) }
                else { model.play([replacement]) }
                model.notify("音频已验证，正在连接 \(replacement.source)")
                dismiss()
            } catch is CancellationError { return }
            catch { failures[option.id] = error.localizedDescription }
        }
    }
}
