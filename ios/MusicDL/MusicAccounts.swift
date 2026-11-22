import Foundation
import Combine
import MusicKit

enum AccountConnection: String {
    case credentialSaved = "凭证待验证", unverified = "已授权，待验证", disconnected = "未连接", authorizing = "正在授权", connected = "已连接", expired = "授权失效", unavailable = "当前环境不可用", failed = "连接失败", configurationUnavailable = "服务配置不可用"
}
struct MusicAccountSummary: Equatable {
    var connection: AccountConnection = .disconnected
    var detail: String = "连接后将验证实际可访问能力。"
    var account: String? = nil
    var avatar: URL? = nil
}

struct NativeAppleAccess {
    var status: () -> MusicAuthorization.Status = { MusicAuthorization.currentStatus }
    var authorize: () async -> MusicAuthorization.Status = { await MusicAuthorization.request() }
    var data: (URLRequest) async throws -> Data = { request in
        try await MusicDataRequest(urlRequest: request).response().data
    }
    var catalogPlayback: () async throws -> Bool = { try await MusicSubscription.current.canPlayCatalogContent }
}

@MainActor
final class MusicAccounts: ObservableObject {
    static let shared = MusicAccounts()
    @Published private(set) var summaries: [String: MusicAccountSummary] = [:]
    @Published private(set) var spotifyClientID: String
    private let nativeApple: NativeAppleAccess
    private let storage: AccountTokenStorage
    private let oauth: SpotifyOAuthClient
    private let browser: WebAuthentication
    private let authenticate: (URL) async throws -> URL
    private let defaults: UserDefaults
    private var tokens: SpotifyTokens?
    private var refreshing: Task<SpotifyTokens, Error>?
    private var generation = 0
    private var restoring = false
    private var disconnecting = false
    let appleBrowser: AppleMusicBrowser
    private var appleSubscription: AnyCancellable?
    private var appleChecking = false
    private var appleGeneration = 0
    private let installSession: (String, Date) async throws -> Void

    init(storage: AccountTokenStorage = KeychainAccountStorage(), oauth: SpotifyOAuthClient = SpotifyOAuthClient(), defaults: UserDefaults = .standard,
         nativeApple: NativeAppleAccess = NativeAppleAccess(), authenticate: ((URL) async throws -> URL)? = nil, appleBrowser: AppleMusicBrowser? = nil,
         installSession: @escaping (String, Date) async throws -> Void = GoBridge.installSpotifySession) {
        let browser = WebAuthentication()
        self.nativeApple = nativeApple
        self.browser = browser
        self.authenticate = authenticate ?? { url in try await browser.open(url) }
        self.storage = storage; self.oauth = oauth; self.defaults = defaults; self.installSession = installSession
        self.appleBrowser = appleBrowser ?? .shared
        spotifyClientID = defaults.string(forKey: "account.spotify.clientID") ?? (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "")
        appleSubscription = self.appleBrowser.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if !SpotifyConfiguration(clientID: spotifyClientID).isValid {
            summaries["spotify"] = MusicAccountSummary(connection: .unavailable, detail: "待配置：需要自己的公开 Client ID。Spotify 开发模式对应用所有者有 Premium 要求；未配置不会影响其他音乐来源。")
        }
    }
    var usesAppleBrowser: Bool { defaults.string(forKey: "account.apple.mode") == "browser" }
    var appleSystemSummary: MusicAccountSummary { summaries["apple-system"] ?? MusicAccountSummary() }
    func summary(_ source: String) -> MusicAccountSummary {
        if source == "apple" { return usesAppleBrowser ? appleBrowser.summary : appleSystemSummary }
        return summaries[source] ?? MusicAccountSummary()
    }
    func connectAppleBrowser() async {
        guard appleSystemSummary.connection != .authorizing, !appleChecking else { return }
        defaults.set("browser", forKey: "account.apple.mode"); objectWillChange.send()
        await appleBrowser.connect()
    }
    func reauthorizeAppleBrowser() async {
        guard appleSystemSummary.connection != .authorizing, !appleChecking else { return }
        defaults.set("browser", forKey: "account.apple.mode"); objectWillChange.send()
        await appleBrowser.cancel()
        await appleBrowser.connect()
    }
    func configureAppleBrowser(_ origin: String) async { await appleBrowser.configure(origin); objectWillChange.send() }
    func handleAppleCallback(_ url: URL) async { _ = await appleBrowser.handleCallback(url) }
    func readApple(_ path: String) async throws -> JSONValue {
        if usesAppleBrowser { return try await appleBrowser.read(path) }
        return try await readNativeApple(path)
    }
    private func readNativeApple(_ path: String) async throws -> JSONValue {
        guard defaults.bool(forKey: "account.apple.enabled"), nativeApple.status() == .authorized else {
            throw NativeError.message("请先连接 Apple Music，或选择系统授权并验证 MusicKit 服务。")
        }
        guard path.hasPrefix("/v1/"), !path.contains("://"), !path.contains(".."), let url = URL(string: "https://api.music.apple.com" + path) else { throw AppleBrowserError.response }
        let data = try await nativeApple.data(URLRequest(url: url, timeoutInterval: 20))
        guard data.count <= 8 * 1024 * 1024 else { throw AppleBrowserError.response }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    var spotifyConfigured: Bool { SpotifyConfiguration(clientID: spotifyClientID).isValid }

    func restore() async {
        await refreshApple()
        await restoreSpotify()
    }

    func restoreSpotify() async {
        guard !restoring, !disconnecting else { return }; restoring = true
        defer { restoring = false }
        guard summary("spotify").connection != .authorizing else { return }
        let expected = generation
        do {
            guard let stored = try storage.read() else { return }
            guard stored.clientID == spotifyClientID, !stored.refresh.isEmpty else { throw MusicAccountError.expired }
            tokens = stored
            try await prepareSpotifySession()
            guard let current = tokens else { return }
            let profile = try await oauth.profile(tokens: current)
            guard generation == expected else { return }
            summaries["spotify"] = connectedSpotify(profile, tokens: current)
        } catch {
            guard generation == expected else { return }
            await spotifyFailure(error)
        }
    }

    func configureSpotify(clientID: String) async {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != spotifyClientID else { return }
        guard await disconnectSpotify() else { return }
        spotifyClientID = value; defaults.set(value, forKey: "account.spotify.clientID")
        summaries["spotify"] = MusicAccountSummary(connection: SpotifyConfiguration(clientID: value).isValid ? .disconnected : .unavailable,
            detail: SpotifyConfiguration(clientID: value).isValid ? "请确认已在 Spotify 后台登记本页回调地址，然后连接。" : MusicAccountError.configuration.localizedDescription)
    }

    func connectSpotify() async {
        guard spotifyConfigured else { summaries["spotify"] = MusicAccountSummary(connection: .unavailable, detail: MusicAccountError.configuration.localizedDescription); return }
        guard summary("spotify").connection != .authorizing else { return }
        let prior = summary("spotify"); let previousTokens = tokens
        generation += 1; let expected = generation
        summaries["spotify"] = MusicAccountSummary(connection: .authorizing, detail: "请在 Spotify 官方页面完成登录并确认授权。页面提供的 Google 等登录方式由 Spotify 自行处理。")
        do {
            let config = SpotifyConfiguration(clientID: spotifyClientID)
            let pkce = try SpotifyPKCE()
            let callback = try await authenticate(pkce.authorizationURL(config: config))
            let code = try pkce.code(from: callback)
            let issued = try await oauth.exchange(code: code, pkce: pkce, config: config)
            let profile = try await oauth.profile(tokens: issued)
            guard generation == expected, !Task.isCancelled else { return }
            try storage.write(issued)
            defaults.set(false, forKey: "account.spotify.requiresReauth")
            tokens = issued
            try await installSession(issued.access, issued.expires)
            guard generation == expected else { return }
            summaries["spotify"] = connectedSpotify(profile, tokens: issued)
        } catch {
            guard generation == expected else { return }
            if prior.connection == .connected, tokens == previousTokens {
                summaries["spotify"] = MusicAccountSummary(connection: .connected, detail: "本次重新授权未完成，仍使用上次验证的账号。", account: prior.account)
            } else { await spotifyFailure(error) }
        }
    }
    func cancelSpotify() { browser.cancel() }

    func prepareSpotifySession(force: Bool = false) async throws {
        guard !disconnecting else { throw CancellationError() }
        guard spotifyConfigured else { throw MusicAccountError.configuration }
        guard !defaults.bool(forKey: "account.spotify.requiresReauth") else { throw MusicAccountError.expired }
        if tokens == nil { tokens = try storage.read() }
        guard let current = tokens, current.clientID == spotifyClientID else { throw MusicAccountError.expired }
        let expected = generation
        do {
            var valid = current
            if force || current.needsRefresh {
                if let refreshing { valid = try await refreshing.value }
                else {
                    let task = Task { try await oauth.refresh(current) }
                    refreshing = task
                    defer { refreshing = nil }
                    valid = try await task.value
                }
                guard generation == expected else { throw CancellationError() }
                try storage.write(valid); tokens = valid
            }
            guard generation == expected else { throw CancellationError() }
            try await installSession(valid.access, valid.expires)
        } catch {
            guard generation == expected else { throw CancellationError() }
            if summary("spotify").connection != .authorizing { await spotifyFailure(error) }
            throw error
        }
    }

    @discardableResult func disconnectSpotify() async -> Bool {
        guard !disconnecting else { return false }
        disconnecting = true
        defer { disconnecting = false }
        generation += 1; browser.cancel(); refreshing?.cancel(); refreshing = nil; tokens = nil
        defaults.set(true, forKey: "account.spotify.requiresReauth")
        summaries["spotify"] = MusicAccountSummary(connection: .authorizing, detail: "正在清理本机授权…")
        var cleared = true
        do { try storage.remove() } catch { cleared = false }
        do { try await installSession("", Date(timeIntervalSince1970: 0)) } catch { cleared = false }
        if cleared {
            defaults.set(false, forKey: "account.spotify.requiresReauth")
            summaries["spotify"] = MusicAccountSummary(detail: "已从本机断开。若要撤销 Spotify 服务器上的授权，请前往 Spotify 账号的应用管理。")
            return true
        } else {
            summaries["spotify"] = MusicAccountSummary(connection: .unavailable, detail: "本机授权清理未完成，请解锁设备后重试断开。")
            return false
        }
    }
    private func connectedSpotify(_ profile: SpotifyProfile, tokens: SpotifyTokens) -> MusicAccountSummary {
        let privatePlaylists = tokens.scopes.split(separator: " ").contains("playlist-read-private")
        return MusicAccountSummary(connection: .connected,
            detail: "官方账号接口已验证。" + (privatePlaylists ? "已获得私有歌单读取授权。" : "未获得私有歌单读取授权。") + "实际 API 能力仍受应用模式及账号资格限制；授权不提供整曲下载权限。",
            account: profile.displayName?.isEmpty == false ? profile.displayName : profile.id,
            avatar: profile.images?.first?.url.flatMap { $0.scheme == "https" ? $0 : nil })
    }
    private func spotifyFailure(_ error: Error) async {
        let failure = error as? MusicAccountError ?? (error is CancellationError ? .cancelled : .service)
        if failure == .expired {
            defaults.set(true, forKey: "account.spotify.requiresReauth")
            tokens = nil; try? await installSession("", Date(timeIntervalSince1970: 0))
        }
        summaries["spotify"] = MusicAccountSummary(connection: failure == .expired ? .expired : failure == .cancelled || failure == .denied ? .disconnected : .unavailable, detail: failure.localizedDescription)
    }

    /// The native path relies on MusicKit token management for the signed App ID.
    func connectApple() async {
        guard !appleChecking, appleSystemSummary.connection != .authorizing else { return }
        if appleBrowser.summary.connection == .authorizing { await appleBrowser.cancel() }
        defaults.set("system", forKey: "account.apple.mode"); objectWillChange.send()
        defaults.set(true, forKey: "account.apple.enabled")
        appleGeneration += 1; let expected = appleGeneration
        summaries["apple-system"] = MusicAccountSummary(connection: .authorizing, detail: "请在系统弹窗中允许访问 Apple Music。此项与浏览器授权分别验证。")
        _ = await nativeApple.authorize()
        guard expected == appleGeneration else { return }
        await refreshAppleSystem()
    }
    func refreshApple() async {
        if usesAppleBrowser { await appleBrowser.restore() }
        else if appleSystemSummary.connection != .authorizing { await refreshAppleSystem() }
    }
    func refreshAppleSystem() async {
        guard defaults.bool(forKey: "account.apple.enabled"), !appleChecking else { return }
        appleChecking = true; let expected = appleGeneration
        defer { appleChecking = false }
        guard nativeApple.status() == .authorized else {
            summaries["apple-system"] = MusicAccountSummary(connection: .failed,
                detail: nativeApple.status() == .denied ? "系统音乐访问已拒绝。请打开系统设置，允许 MusicDL 访问媒体与 Apple Music，然后重新验证。" : "系统音乐权限尚未允许或受到设备限制。请重新申请；受限设备需由设备管理者解除限制。")
            return
        }
        summaries["apple-system"] = MusicAccountSummary(connection: .unverified, detail: "已获得系统权限，正在验证个人音乐资料库…")
        do {
            let value = try await readNativeApple("/v1/me/storefront")
            guard let storefront = value["data"].arrayValue.first, storefront["type"].stringValue == "storefronts", !storefront["id"].stringValue.isEmpty else { throw AppleBrowserError.response }
            guard expected == appleGeneration else { return }
            let library = try await readNativeApple("/v1/me/library/playlists?limit=1")
            guard case .array = library["data"] else { throw AppleBrowserError.response }
            let subscription = try? await nativeApple.catalogPlayback()
            guard expected == appleGeneration else { return }
            defaults.set(true, forKey: "account.apple.verified")
            summaries["apple-system"] = MusicAccountSummary(connection: .connected,
                detail: "原生 MusicKit 用户服务已独立验证，地区：\(storefront["id"].stringValue.uppercased())。" + "个人歌单接口已验证。" + (subscription.map { $0 ? "可播放订阅目录。" : "当前无完整目录播放资格。" } ?? "订阅状态暂时无法确认。") + "现有播放器与 DRM 访问方式保持原样；浏览器连接不授予原生完整播放权限。")
        } catch {
            guard expected == appleGeneration else { return }
            let ns = error as NSError
            if let tokenError = error as? MusicTokenRequestError {
                switch tokenError {
                case .developerTokenRequestFailed:
                    summaries["apple-system"] = MusicAccountSummary(connection: .configurationUnavailable, detail: "未取得开发者令牌。检查网络，并由签名团队为实际 App ID 开启 MusicKit 后重新签名。")
                case .userNotSignedIn, .privacyAcknowledgementRequired:
                    summaries["apple-system"] = MusicAccountSummary(connection: .disconnected, detail: "请在系统音乐 App 登录并确认媒体服务条款，再验证连接。")
                case .permissionDenied, .userTokenRevoked:
                    summaries["apple-system"] = MusicAccountSummary(connection: .expired, detail: "音乐访问权限已拒绝或撤销，请在系统设置中检查后重新授权。")
                default:
                    summaries["apple-system"] = MusicAccountSummary(connection: .failed, detail: "暂时无法获取用户音乐授权，请检查网络和系统音乐账号后重试。")
                }
            } else if let error = error as? URLError {
                summaries["apple-system"] = MusicAccountSummary(connection: .failed, detail: error.code == .timedOut ? "原生 MusicKit 服务验证超时，请检查网络后重试。" : "原生 MusicKit 网络请求失败，请恢复网络后重试。")
            } else {
                summaries["apple-system"] = MusicAccountSummary(connection: .failed,
                    detail: "系统权限已允许，但原生 MusicKit 服务未通过验证（错误码 \(ns.code)）。请核对此签名 Bundle ID 在 Apple Developer 中的 MusicKit App Service、账号与网络。免费个人重签不能假定拥有该服务。")
            }
        }
    }
    func disconnectApple() async {
        appleGeneration += 1; defaults.set(false, forKey: "account.apple.enabled")
        summaries["apple-system"] = MusicAccountSummary(detail: "已停止本 App 的原生 MusicKit 访问。系统权限需在设置中撤销，不会退出设备 Apple 账号。")
        await appleBrowser.disconnect(); objectWillChange.send()
    }

    func expireSpotify() async { await spotifyFailure(MusicAccountError.expired) }

    private var legacyCredentials: [String: String] = [:]
    func updateLegacyCredentials(_ values: [String: String]) {
        for source in ["netease", "qq", "soda", "kugou", "kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili"] {
            let value = values[source] ?? ""
            if legacyCredentials[source] != value {
                legacyCredentials[source] = value
                summaries[source] = MusicAccountSummary(connection: value.isEmpty ? .disconnected : .credentialSaved,
                    detail: value.isEmpty ? "未连接账号，公开搜索等能力仍可独立使用。" : "凭证已保存但尚未验证，请验证连接；保存凭证不等于登录成功。")
            }
        }
    }
    func validateLegacy(source: String, client: NativeClient) async {
        guard ["netease", "qq", "soda", "kugou", "kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili"].contains(source), summary(source).connection != .authorizing else { return }
        let credential = legacyCredentials[source] ?? ""
        guard !credential.isEmpty else { summaries[source] = MusicAccountSummary(detail: "请先使用兼容入口连接账号。"); return }
        summaries[source] = MusicAccountSummary(connection: .authorizing, detail: "正在验证已有凭证的账号歌单读取能力…")
        do {
            let result = try await client.request("accounts.legacy.validate", params: ["source": .string(source)])
            guard legacyCredentials[source] == credential else { return }
            switch result["status"].stringValue {
            case "playlists_readable": summaries[source] = MusicAccountSummary(connection: .credentialSaved, detail: "歌单接口已返回资料。平台未提供独立账号身份验证，可继续查看歌单。")
            case "unverified": summaries[source] = MusicAccountSummary(connection: .credentialSaved, detail: "接口未返回歌单，凭证和账号身份尚未验证。")
            case "unsupported": summaries[source] = MusicAccountSummary(connection: .unavailable, detail: "当前平台没有可用的账号验证或个人歌单接口。")
            case "expired": summaries[source] = MusicAccountSummary(connection: .expired, detail: "已有凭证未通过验证，请重新连接。")
            case "disconnected": summaries[source] = MusicAccountSummary(detail: "尚未保存可用凭证。")
            default: summaries[source] = MusicAccountSummary(connection: .unavailable, detail: "当前无法验证，可能是网络或平台限制；请稍后重试。")
            }
        } catch {
            guard legacyCredentials[source] == credential else { return }
            summaries[source] = MusicAccountSummary(connection: .unavailable, detail: "当前无法验证连接，请检查网络后重试。")
        }
    }
}
