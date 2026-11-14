import Foundation
import Combine
import CryptoKit
import Security
import UIKit

enum AppleBrowserError: String, LocalizedError {
    case configuration, serviceConfiguration, callback, expired, cancelled, network, certificate, timeout, rateLimited, denied, missing, response, storage, browser
    var errorDescription: String? {
        switch self {
        case .configuration: return "服务配置不可用：需要 Apple Developer Program、启用 MusicKit 的 Media ID 和已部署的 HTTPS 授权服务。请先配置自己的服务地址；无需填写密码或 Token。"
        case .serviceConfiguration: return "服务配置不可用：请让维护者检查服务版本、Media ID、Team ID、Media Services 密钥和 Token 的 origin 域名。"
        case .callback: return "返回 App 的校验未通过。请取消本次授权后重新连接；不要重复打开旧的返回链接。"
        case .expired: return "连接已到期或服务已重启。请重新授权 Apple Music。"
        case .cancelled: return "已取消本次授权，可以重新连接。"
        case .network: return "无法连接授权服务或 Apple。请检查网络和 HTTPS 服务状态后重试；已保存的本地歌单不受影响。"
        case .certificate: return "HTTPS 证书或安全连接验证失败。请让服务维护者配置有效证书和 TLS；不要关闭证书校验。"
        case .timeout: return "授权服务请求超时，请检查服务器和网络后重试。"
        case .rateLimited: return "Apple 或授权服务请求过多，请稍后重试，已读取的内容会保留。"
        case .denied: return "Apple 未允许访问音乐资料。请重新授权，并检查 Apple Music 账号、音乐资料库和订阅资格；服务维护者还需核对 MusicKit 配置。"
        case .missing: return "资料不存在或当前账号无权访问，可能已删除或属于其他账号。请检查歌单链接或重新同步。"
        case .response: return "授权服务返回了无效数据。请更新服务与 App 后重新连接。"
        case .storage: return "无法安全读写本机授权，请解锁设备后重试。断开操作会先停止本 App 的访问。"
        case .browser: return "系统未能打开浏览器，请检查设备限制后重试。"
        }
    }
    static func from(_ error: Error) -> AppleBrowserError {
        if let error = error as? AppleBrowserError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if let error = error as? URLError {
            if error.code == .timedOut { return .timeout }
            if [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(error.code) { return .certificate }
        }
        return .network
    }
}

struct AppleWebPending: Codable, Equatable {
    let id: String, state: String, verifier: String, callback: String
    let expires: Date
}
struct AppleWebSession: Codable, Equatable {
    let capability: String
    let expires: Date
}
struct AppleWebRecord: Codable {
    let origin: String
    var pending: AppleWebPending?
    var session: AppleWebSession?
}
protocol AppleWebStorage {
    func read() throws -> AppleWebRecord?
    func write(_ value: AppleWebRecord?) throws
}
struct AppleWebKeychain: AppleWebStorage {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.guohuiyuan.musicdl.apple.browser", kSecAttrAccount as String: "relay-session-v1"] }
    func read() throws -> AppleWebRecord? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let record = try? JSONDecoder().decode(AppleWebRecord.self, from: data) else { throw AppleBrowserError.storage }
        return record
    }
    func write(_ value: AppleWebRecord?) throws {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppleBrowserError.storage }; return
        }
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppleBrowserError.storage }
        } else if status != errSecSuccess { throw AppleBrowserError.storage }
    }
}

private final class AppleRelayRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct AppleRelayClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: AppleRelayRedirects(), delegateQueue: nil)
    }
    func request(origin: String, route: String, method: String = "POST", body: [String: String]? = nil, capability: String? = nil) async throws -> JSONValue {
        guard AppleMusicBrowser.validOrigin(origin), route.hasPrefix("/v1/"), let url = URL(string: origin + route) else { throw AppleBrowserError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let capability { request.setValue("Bearer " + capability, forHTTPHeaderField: "Authorization") }
        let (data, raw) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = raw as? HTTPURLResponse, response.url?.host == url.host, data.count <= 8 * 1024 * 1024 else { throw AppleBrowserError.response }
        if response.statusCode == 204 { return .null }
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard response.statusCode == 200 else {
            switch value["error"].stringValue {
            case "developer_unavailable": throw AppleBrowserError.serviceConfiguration
            case "music_access_denied": throw AppleBrowserError.denied
            case "session_expired", "expired_flow", "invalid_exchange": throw AppleBrowserError.expired
            case "apple_not_found": throw AppleBrowserError.missing
            case "apple_rate_limited", "rate_limited": throw AppleBrowserError.rateLimited
            default:
                if (300..<400).contains(response.statusCode) || response.statusCode == 404 || value["error"].stringValue == "invalid_origin" { throw AppleBrowserError.serviceConfiguration }
                if response.statusCode == 400 { throw AppleBrowserError.response }
                if response.statusCode == 401 { throw AppleBrowserError.expired }
                if response.statusCode == 429 { throw AppleBrowserError.rateLimited }
                throw AppleBrowserError.network
            }
        }
        guard value != .null else { throw AppleBrowserError.response }
        return value
    }
}

@MainActor
final class AppleMusicBrowser: ObservableObject {
    static let shared = AppleMusicBrowser()
    static let customCallback = "com.guohuiyuan.musicdl.apple-login://callback"
    @Published private(set) var summary = MusicAccountSummary()
    @Published private(set) var origin: String
    private let storage: AppleWebStorage
    private let client: AppleRelayClient
    private let defaults: UserDefaults
    private let openBrowser: (URL) async -> Bool
    var hasPending: Bool { record?.pending != nil }
    private var record: AppleWebRecord?
    private var generation = 0
    private var checking = false
    private var disconnecting = false
    private var deadline: Task<Void, Never>?
    init(storage: AppleWebStorage = AppleWebKeychain(), client: AppleRelayClient = AppleRelayClient(), defaults: UserDefaults = .standard, openBrowser: ((URL) async -> Bool)? = nil) {
        self.storage = storage; self.client = client; self.defaults = defaults
        self.openBrowser = openBrowser ?? { await UIApplication.shared.open($0) }
        let bundled = Bundle.main.object(forInfoDictionaryKey: "AppleMusicRelayOrigin") as? String ?? ""
        origin = defaults.string(forKey: "account.apple.browser.origin") ?? (bundled.hasPrefix("$(") ? "" : bundled)
        if !Self.validOrigin(origin) { summary = MusicAccountSummary(connection: .configurationUnavailable, detail: AppleBrowserError.configuration.localizedDescription) }
    }
    nonisolated static func validOrigin(_ value: String) -> Bool {
        guard value.count <= 255, let c = URLComponents(string: value), c.scheme == "https", let host = c.host, host.contains("."),
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty, c.query == nil, c.fragment == nil,
              !host.hasSuffix(".local"), host != "localhost", !host.contains(":"),
              host.split(separator: ".").contains(where: { $0.contains(where: { $0.isLetter }) }) else { return false }
        return value == "https://" + host.lowercased()
    }
    nonisolated static func opaque(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil }
    nonisolated static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func load() throws {
        guard !defaults.bool(forKey: "account.apple.browser.disabled") else { record = nil; return }
        if record == nil { record = try storage.read() }
        guard record == nil || record?.origin == origin else { throw AppleBrowserError.configuration }
        if let session = record?.session, !Self.opaque(session.capability) { throw AppleBrowserError.storage }
        if let pending = record?.pending {
            guard Self.opaque(pending.id), Self.opaque(pending.state), Self.opaque(pending.verifier),
                  pending.callback == Self.customCallback || pending.callback == origin + "/apple-music/return" else { throw AppleBrowserError.storage }
        }
    }
    private func persist() throws { try storage.write(record) }
    private func failed(_ error: Error) {
        let failure = AppleBrowserError.from(error)
        summary = MusicAccountSummary(connection: failure == .configuration || failure == .serviceConfiguration ? .configurationUnavailable : failure == .cancelled ? .disconnected : .failed, detail: failure.localizedDescription)
    }
    func configure(_ value: String) async {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard value != origin else { return }
        guard value.isEmpty || Self.validOrigin(value) else { failed(AppleBrowserError.configuration); return }
        await disconnect()
        origin = value; defaults.set(value, forKey: "account.apple.browser.origin")
        summary = MusicAccountSummary(connection: value.isEmpty ? .configurationUnavailable : .disconnected, detail: value.isEmpty ? AppleBrowserError.configuration.localizedDescription : "服务地址已保存。连接前会检查配置，不会因保存地址而显示授权成功。")
    }
    func connect() async {
        guard !checking, !disconnecting else { return }
        do { try load() } catch { failed(error); return }
        if let pending = record?.pending, pending.expires > Date() { return }
        guard Self.validOrigin(origin) else { failed(AppleBrowserError.configuration); return }
        generation += 1; let expected = generation; checking = true
        defer { checking = false }
        summary = MusicAccountSummary(connection: .authorizing, detail: "正在检查 HTTPS 授权服务…")
        do {
            try load()
            let config = try await client.request(origin: origin, route: "/v1/config", method: "GET")
            guard generation == expected else { return }
            let callback = config["callback"].stringValue
            guard config["version"].numberValue == 1, config["ready"].boolValue,
                  callback == Self.customCallback || callback == origin + "/apple-music/return" else { throw AppleBrowserError.serviceConfiguration }
            let verifier = try SpotifyPKCE.random(), state = try SpotifyPKCE.random()
            let result = try await client.request(origin: origin, route: "/v1/flows", body: ["challenge": Self.challenge(verifier), "state": state])
            guard generation == expected else { return }
            let id = result["id"].stringValue
            guard Self.opaque(id), let url = URL(string: result["browserURL"].stringValue), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  c.scheme == "https", c.host == URL(string: origin)?.host, c.port == nil, c.user == nil, c.password == nil, c.path == "/connect", c.query == nil,
                  let fragment = c.fragment, fragment.hasPrefix(id + "."), Self.opaque(String(fragment.dropFirst(id.count + 1))) else { throw AppleBrowserError.response }
            record = AppleWebRecord(origin: origin, pending: AppleWebPending(id: id, state: state, verifier: verifier, callback: callback, expires: Date().addingTimeInterval(600)), session: record?.session)
            try persist(); defaults.set(false, forKey: "account.apple.browser.disabled")
            summary = MusicAccountSummary(connection: .authorizing, detail: "请在浏览器点击继续，由 Apple 官方页面完成登录、双重认证和音乐资料授权，然后返回此 App。")
            guard await openBrowser(url) else { throw AppleBrowserError.browser }
            guard generation == expected else { return }
            armDeadline()
        } catch {
            guard generation == expected else { return }
            let pending = record?.pending; record?.pending = nil; try? persist()
            if let pending { await cancelRemote(pending) }
            if generation == expected { failed(error) }
        }
    }
    private func armDeadline() {
        deadline?.cancel()
        guard let pending = record?.pending else { return }
        deadline = Task { [weak self] in
            let seconds = max(0, pending.expires.timeIntervalSinceNow)
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.record?.pending?.id == pending.id else { return }
            await self.cancel(); self.failed(AppleBrowserError.expired)
        }
    }
    func handleCallback(_ url: URL) async -> Bool {
        let callbackGeneration = generation
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (c.scheme == "com.guohuiyuan.musicdl.apple-login" || (c.scheme == "https" && c.host == URL(string: origin)?.host && c.path == "/apple-music/return")) else { return false }
        if checking || disconnecting { return true }
        do {
            try load()
            guard let pending = record?.pending else { return true }
            guard pending.expires > Date() else { throw AppleBrowserError.expired }
            guard let expectedURL = URLComponents(string: pending.callback) else { throw AppleBrowserError.callback }
            guard c.scheme == expectedURL.scheme, c.host == expectedURL.host, c.path == expectedURL.path,
                  c.user == nil, c.password == nil, c.port == nil, c.fragment == nil, let items = c.queryItems, items.count == 3,
                  (Set(items.map(\.name)) == Set(["id", "state", "code"]) || Set(items.map(\.name)) == Set(["id", "state", "error"])),
                  items.first(where: { $0.name == "id" })?.value == pending.id,
                  items.first(where: { $0.name == "state" })?.value == pending.state else { throw AppleBrowserError.callback }
            if let error = items.first(where: { $0.name == "error" })?.value {
                guard error == "cancelled" else { throw AppleBrowserError.callback }
                await cancel(); return true
            }
            guard let code = items.first(where: { $0.name == "code" })?.value, Self.opaque(code) else { throw AppleBrowserError.callback }
            checking = true; defer { checking = false }; let expected = generation
            let issued = try await client.request(origin: origin, route: "/v1/exchange", body: ["id":pending.id,"code":code,"verifier":pending.verifier])
            let capability = issued["session"].stringValue, expires = Date(timeIntervalSince1970: issued["expires"].numberValue)
            guard Self.opaque(capability), expires > Date(), expires < Date().addingTimeInterval(25*3600) else { throw AppleBrowserError.response }
            guard expected == generation else { _ = try? await client.request(origin: origin, route: "/v1/session", method: "DELETE", capability: capability); return true }
            let old = record?.session
            record?.pending = nil; record?.session = AppleWebSession(capability: capability, expires: expires)
            do { try persist() } catch { _ = try? await client.request(origin: origin, route: "/v1/session", method: "DELETE", capability: capability); record?.session = old; throw error }
            deadline?.cancel(); deadline = nil
            if let old { _ = try? await client.request(origin: origin, route: "/v1/session", method: "DELETE", capability: old.capability) }
            try await verify(expected: expected)
        } catch { if callbackGeneration == generation { failed(error) } }
        return true
    }
    func restore() async {
        guard !checking, !disconnecting else { return }
        guard Self.validOrigin(origin) else { failed(AppleBrowserError.configuration); return }
        let restoreGeneration = generation
        do {
            try load()
            if let pending = record?.pending {
                if pending.expires <= Date() { await cancel(); failed(AppleBrowserError.expired) }
                else { summary = MusicAccountSummary(connection: .authorizing, detail: "正在等待浏览器返回。若已关闭网页，请取消后重试。"); armDeadline() }
                return
            }
            guard record?.session != nil else { return }
            checking = true; defer { checking = false }; let expected = generation
            try await verify(expected: expected)
        } catch { if restoreGeneration == generation { failed(error) } }
    }
    private func verify(expected: Int) async throws {
        guard expected == generation else { throw CancellationError() }
        let region = try await read("/v1/me/storefront")
        guard let first = region["data"].arrayValue.first, first["type"].stringValue == "storefronts", !first["id"].stringValue.isEmpty else { throw AppleBrowserError.response }
        guard expected == generation else { throw CancellationError() }
        let library = try await read("/v1/me/library/playlists?limit=1")
        guard case .array = library["data"] else { throw AppleBrowserError.response }
        guard expected == generation else { throw CancellationError() }
        summary = MusicAccountSummary(connection: .connected, detail: "浏览器授权与音乐资料库读取已验证，地区：\(first["id"].stringValue.uppercased())。可继续同步歌单、搜索与导入，具体能力依实际接口返回结果；原生 MusicKit 授权和完整歌曲播放资格仍需独立验证。")
    }
    func read(_ path: String) async throws -> JSONValue {
        guard Self.validOrigin(origin) else { failed(AppleBrowserError.configuration); throw AppleBrowserError.configuration }
        try load()
        guard let session = record?.session, session.expires > Date(), !defaults.bool(forKey: "account.apple.browser.disabled") else { failed(AppleBrowserError.expired); throw AppleBrowserError.expired }
        let expected = generation
        do {
            let value = try await client.request(origin: origin, route: "/v1/read", body: ["path":path], capability: session.capability)
            guard generation == expected else { throw CancellationError() }; return value
        } catch {
            guard generation == expected else { throw CancellationError() }
            if let failure = error as? AppleBrowserError, failure == .expired || failure == .denied { record?.session = nil; try? persist() }
            if !(error is CancellationError) { failed(error) }
            throw error
        }
    }
    private func cancelRemote(_ pending: AppleWebPending) async { _ = try? await client.request(origin: origin, route: "/v1/cancel", body: ["id":pending.id,"verifier":pending.verifier]) }
    func cancel() async {
        generation += 1; deadline?.cancel(); deadline = nil
        let pending = record?.pending; record?.pending = nil
        do { try persist(); failed(AppleBrowserError.cancelled) } catch { defaults.set(true, forKey: "account.apple.browser.disabled"); failed(error) }
        if let pending { await cancelRemote(pending) }
    }
    func disconnect() async {
        guard !disconnecting else { return }
        disconnecting = true; defer { disconnecting = false }
        generation += 1; deadline?.cancel(); deadline = nil
        defaults.set(true, forKey: "account.apple.browser.disabled")
        var clean = true
        do { if record == nil { record = try storage.read() } } catch { clean = false }
        let previous = record; record = nil
        do { try storage.write(nil) } catch { clean = false }
        if let previous, previous.origin == origin {
            if let pending = previous.pending { await cancelRemote(pending) }
            if let session = previous.session {
                do { _ = try await client.request(origin: origin, route: "/v1/session", method: "DELETE", capability: session.capability) } catch { clean = false }
            }
        }
        summary = MusicAccountSummary(connection: clean ? .disconnected : .failed, detail: clean ? "已停止本机访问并清理授权服务连接。本地歌单保留；Apple 网站授权可在下方浏览器入口撤销。系统音乐权限需另行在系统设置撤销。" : "本 App 已停止访问，但本机或服务器清理未完成。请解锁并恢复网络后重试断开；服务端连接最长24小时后失效。Apple 网站授权需在浏览器另行撤销。")
    }
}
