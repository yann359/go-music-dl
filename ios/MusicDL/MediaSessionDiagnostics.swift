import Foundation
import OSLog

/// Only lifecycle/ownership changes, never song data, credentials or URLs.
/// A bounded file in the existing Files-sharing container survives a failed
/// system-to-app activation so a later icon launch can collect the evidence.
enum MediaSessionDiagnostics {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicDL", category: "media-session")
    private static let writer = DispatchQueue(label: "musicdl.media-diagnostics", qos: .utility)
    private static let sequenceLock = NSLock()
    private static var sequence: UInt64 = 0

    static func record(_ event: String, fields: [String: String] = [:]) {
        var entry = fields
        sequenceLock.lock()
        sequence += 1
        entry["sequence"] = String(sequence)
        sequenceLock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["schema"] = "2"
        entry["event"] = event
        entry["at"] = formatter.string(from: Date())
        entry["uptime_ms"] = String(Int(ProcessInfo.processInfo.systemUptime * 1000))
        entry["bundle"] = Bundle.main.bundleIdentifier ?? "unknown"
        entry["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        entry["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        guard let encoded = try? JSONEncoder().encode(entry) else {
            logger.error("media diagnostic encoding failed")
            return
        }
        logger.notice("\(String(decoding: encoded, as: UTF8.self), privacy: .public)")
        writer.async {
            do {
                let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("Diagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let url = root.appendingPathComponent("media-session.jsonl")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 128 * 1024 {
                    let old = try Data(contentsOf: url)
                    let tail = old.suffix(64 * 1024)
                    let retained = tail.firstIndex(of: 10).map { Data(tail[tail.index(after: $0)...]) } ?? Data()
                    try retained.write(to: url, options: .atomic)
                }
                if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: encoded + Data([10]))
            } catch {
                logger.error("media diagnostic persistence failed code=\((error as NSError).code)")
            }
        }
    }
}
