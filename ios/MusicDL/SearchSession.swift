import Foundation
import Combine
import OSLog

/// One owner for debounce, cancellation and the visible query generation.
/// Go's bounded legacy I/O may finish later; it can never publish into a newer session.
@MainActor
final class SearchSession: ObservableObject {
    enum Phase: Equatable { case idle, searching, partial, complete, empty, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: NativeSearchResult?
    @Published private(set) var problem: String?
    @Published private(set) var visibleCount = 30
    private var task: Task<Void, Never>?
    private var generation = 0
    private var activeKey = ""
    private var waitingForDebounce = false
    private let diagnostics = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicDL", category: "search")
    var loading: Bool { phase == .searching || phase == .partial }

    func start(client: NativeClient, query: String, kind: String, sources: [String], debounce: Bool = false, refresh: Bool = false, completed: @escaping (String) -> Void = { _ in }) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = term + "\n" + kind + "\n" + sources.sorted().joined(separator: ",")
        if !refresh && activeKey == key && loading && (!waitingForDebounce || debounce) { return }
        task?.cancel(); generation += 1
        let token = generation
        activeKey = key; waitingForDebounce = debounce
        result = nil; problem = nil; visibleCount = 30
        guard !term.isEmpty else { phase = .idle; return }
        guard !sources.isEmpty else { phase = .failed; problem = "请选择至少一个支持此搜索类型的音乐来源。"; return }
        phase = .searching
        diagnostics.info("event=search-start generation=\(token) type=\(kind, privacy: .public) sources=\(sources.count) debounce=\(debounce)")
        task = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            var firstResult = false
            do {
                if debounce { try await Task.sleep(nanoseconds: 450_000_000) }
                try Task.checkCancellation()
                self.waitingForDebounce = false
                try await client.searchProgressively(query: term, type: kind, sources: sources, refresh: refresh) { [weak self] value in
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.result = value
                    if !value.songs.isEmpty || !value.playlists.isEmpty {
                        self.phase = .partial
                        if !firstResult {
                            firstResult = true
                            self.diagnostics.info("event=first-result generation=\(token) songs=\(value.songs.count) collections=\(value.playlists.count)")
                            #if DEBUG
                            print("[native-search] first-result type=\(kind) sources=\(sources.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
                            #endif
                        }
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                let value = result ?? NativeSearchResult()
                result = value
                if !value.songs.isEmpty || !value.playlists.isEmpty { phase = .complete }
                else if !value.errors.isEmpty { phase = .failed; problem = "部分来源搜索失败，其余来源未找到结果。\n" + value.errors.joined(separator: "\n") }
                else { phase = .empty }
                completed(term)
                diagnostics.info("event=search-complete generation=\(token) songs=\(value.songs.count) collections=\(value.playlists.count) failures=\(value.errors.count) success=\(value.successfulSources)")
                #if DEBUG
                print("[native-search] complete type=\(kind) ms=\(Int(Date().timeIntervalSince(started) * 1000)) cached=\(value.cachedSources) failed=\(value.errors.count)")
                #endif
            } catch is CancellationError { /* A newer query owns the page. */ }
            catch {
                guard generation == token, !Task.isCancelled else { return }
                phase = .failed; problem = error.localizedDescription
                diagnostics.error("event=search-failed generation=\(token)")
            }
        }
    }

    func showMore() { visibleCount += 30 }
    func suspend() {
        guard loading else { return }
        task?.cancel(); generation += 1; activeKey = ""
        diagnostics.info("event=search-suspend generation=\(self.generation)")
        phase = .idle
    }
}
