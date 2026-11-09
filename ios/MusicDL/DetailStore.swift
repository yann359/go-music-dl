import Foundation

struct NativeDetailPage {
    let songs: [Song]
    let warnings: [String]
    var partial: Bool { !warnings.isEmpty }
}

/// Disposable, bounded metadata cache; never stores local collection contents
/// or credentials and never changes SQLite/library records.
@MainActor
final class DetailStore {
    private struct Entry: Codable { let saved: Date; let value: JSONValue }
    private var entries: [String: Entry] = [:]
    private var costs: [String: Int] = [:]
    private var requests: [String: Task<JSONValue, Error>] = [:]
    private var generation = 0
    private let url: URL?
    private let now: () -> Date
    init(url: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.url = url; self.now = now
        if let url, let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024,
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored.filter { now().timeIntervalSince($0.value.saved) >= 0 && now().timeIntervalSince($0.value.saved) < 86400 }
            for (key, entry) in entries { costs[key] = (try? JSONEncoder().encode(entry).count) ?? 0 }
            trim()
        }
    }
    private func trim() {
        while entries.count > 40 || costs.values.reduce(0, +) > 8 * 1024 * 1024 {
            guard let oldest = entries.min(by: { $0.value.saved < $1.value.saved })?.key else { break }
            entries[oldest] = nil; costs[oldest] = nil
        }
    }
    func cached(_ key: String) -> JSONValue? {
        guard let entry = entries[key], now().timeIntervalSince(entry.saved) < 86400 else { return nil }
        return entry.value
    }
    func load(_ key: String, force: Bool = false, loader: @escaping () async throws -> JSONValue) async throws -> JSONValue {
        if !force, let entry = entries[key], now().timeIntervalSince(entry.saved) < 900 {
            #if DEBUG
            print("[native-detail] cache=fresh")
            #endif
            return entry.value
        }
        if let request = requests[key] {
            let expected = generation
            let value = try await request.value
            guard expected == generation else { throw CancellationError() }
            return value
        }
        let expected = generation
        let task = Task { try await loader() }
        requests[key] = task
        defer { if expected == generation { requests[key] = nil } }
        let result = try await task.value
        guard expected == generation else { throw CancellationError() }
        // Failures and partial results do not become a fresh complete cache.
        if result["errors"].arrayValue.isEmpty {
            entries[key] = Entry(saved: now(), value: result)
            costs[key] = (try? JSONEncoder().encode(result).count) ?? 0
            trim()
            if let url, let data = try? JSONEncoder().encode(entries), data.count <= 8 * 1024 * 1024 {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
        return result
    }
    func invalidate() {
        generation += 1
        requests.values.forEach { $0.cancel() }; requests = [:]; entries = [:]; costs = [:]
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
