import Foundation
import Combine

/// Startup is single-flight; retries are finite. Connectivity to an online
/// provider is deliberately independent of this in-process service state.
@MainActor
final class LocalService: ObservableObject {
    enum State: String { case stopped, starting, available, disconnected, reconnecting, unavailable }
    @Published private(set) var state: State = .stopped
    private var pending: Task<URL, Error>?
    private let start: (String) async throws -> URL
    init(start: @escaping (String) async throws -> URL = GoBridge.start) { self.start = start }

    func connect(root: String) async throws -> URL {
        if let pending { return try await pending.value }
        let task = Task<URL, Error> {
            var failure: Error = NativeError.message("本地服务未启动")
            for attempt in 0..<3 {
                try Task.checkCancellation()
                state = attempt == 0 ? .starting : .reconnecting
                do {
                    let url = try await start(root)
                    state = .available
                    return url
                } catch is CancellationError { state = .disconnected; throw CancellationError() }
                catch {
                    failure = error; state = .disconnected
                    #if DEBUG
                    print("[native-service] attempt=\(attempt + 1) error=\(error)")
                    #endif
                    if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 300_000_000) }
                }
            }
            state = .unavailable
            throw failure
        }
        pending = task
        defer { pending = nil }
        return try await task.value
    }
}
