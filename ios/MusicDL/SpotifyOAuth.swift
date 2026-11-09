import Foundation
import CryptoKit
import Security

enum MusicAccountError: LocalizedError, Equatable {
    case configuration, cancelled, timeout, callback, denied, invalidToken, expired, network, service, storage
    var errorDescription: String? {
        switch self {
        case .configuration: return "请先配置自己的 Spotify Client ID，并在官方后台登记页面显示的回调地址。"
        case .cancelled: return "已取消授权，可以随时重试。"
        case .timeout: return "授权等待超时，请重试。"
        case .callback: return "授权回调校验失败，请重新连接。"
        case .denied: return "你没有同意授权，可以稍后重新连接。"
        case .invalidToken: return "授权服务返回的数据不完整，请重新连接。"
        case .expired: return "授权已失效，请重新连接 Spotify。"
        case .network: return "网络暂时不可用，请恢复网络后重试。"
        case .service: return "Spotify 暂时无法提供所需访问权限，请检查应用配置、测试用户资格或稍后重试。"
        case .storage: return "无法安全保存账号授权，请解锁设备后重试。"
        }
    }
}

struct SpotifyConfiguration: Equatable {
    static let redirect = "com.guohuiyuan.musicdl.spotify-login://oauth/callback"
    static let scopes = ["user-read-private", "playlist-read-private", "playlist-read-collaborative"]
    let clientID: String
    var isValid: Bool { clientID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil }
}

struct SpotifyPKCE {
    let verifier: String
    let state: String
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MusicAccountError.service }
        return base64URL(Data(bytes))
    }
    init() throws { verifier = try Self.random(); state = try Self.random() }
    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    private static func base64URL(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    func authorizationURL(config: SpotifyConfiguration) throws -> URL {
        guard config.isValid else { throw MusicAccountError.configuration }
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfiguration.redirect), URLQueryItem(name: "scope", value: SpotifyConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return url.url!
    }
    func code(from callback: URL) throws -> String {
        guard let value = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: SpotifyConfiguration.redirect),
              value.scheme == expected.scheme, value.host == expected.host, value.path == expected.path,
              value.port == expected.port, value.user == nil, value.password == nil, value.fragment == nil else { throw MusicAccountError.callback }
        let items = value.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw MusicAccountError.callback }
        if items.contains(where: { $0.name == "error" }) { throw MusicAccountError.denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw MusicAccountError.callback }
        return code
    }
}

struct SpotifyTokens: Codable, Equatable {
    let clientID: String
    let access: String
    let refresh: String
    let expires: Date
    let scopes: String
    var needsRefresh: Bool { expires.timeIntervalSinceNow < 60 }
}

struct SpotifyProfile: Decodable, Equatable {
    let id: String
    let displayName: String?
    private enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
}

struct SpotifyOAuthClient {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: SpotifyOAuthRedirectPolicy(), delegateQueue: nil)
    }()

    func exchange(code: String, pkce: SpotifyPKCE, config: SpotifyConfiguration) async throws -> SpotifyTokens {
        guard config.isValid else { throw MusicAccountError.configuration }
        return try await token(form: ["grant_type": "authorization_code", "code": code, "redirect_uri": SpotifyConfiguration.redirect,
                                      "client_id": config.clientID, "code_verifier": pkce.verifier], clientID: config.clientID, previous: nil)
    }
    func refresh(_ old: SpotifyTokens) async throws -> SpotifyTokens {
        try await token(form: ["grant_type": "refresh_token", "refresh_token": old.refresh, "client_id": old.clientID], clientID: old.clientID, previous: old)
    }
    private func token(form: [String: String], clientID: String, previous: SpotifyTokens?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var encoded = URLComponents()
        encoded.queryItems = form.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data = try await response(request, tokenEndpoint: true)
        struct Reply: Decodable { let access_token: String; let token_type: String; let expires_in: Int; let refresh_token: String?; let scope: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.access_token.isEmpty,
              reply.token_type.lowercased() == "bearer", reply.expires_in > 0,
              let refresh = reply.refresh_token ?? previous?.refresh, !refresh.isEmpty else { throw MusicAccountError.invalidToken }
        return SpotifyTokens(clientID: clientID, access: reply.access_token, refresh: refresh,
                             expires: Date().addingTimeInterval(Double(reply.expires_in)), scopes: reply.scope ?? previous?.scopes ?? "")
    }
    func profile(tokens: SpotifyTokens) async throws -> SpotifyProfile {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer " + tokens.access, forHTTPHeaderField: "Authorization")
        let data = try await response(request)
        guard let profile = try? JSONDecoder().decode(SpotifyProfile.self, from: data), !profile.id.isEmpty else { throw MusicAccountError.invalidToken }
        return profile
    }
    private func response(_ request: URLRequest, tokenEndpoint: Bool = false) async throws -> Data {
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw MusicAccountError.timeout }
            throw MusicAccountError.network
        }
        guard let http = response as? HTTPURLResponse else { throw MusicAccountError.service }
        guard (200..<300).contains(http.statusCode) else {
            #if DEBUG
            print("[music-account] Spotify endpoint=\(tokenEndpoint ? "token" : "profile") status=\(http.statusCode)")
            #endif
            if http.statusCode == 401 { throw MusicAccountError.expired }
            if tokenEndpoint, let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], error["error"] as? String == "invalid_grant" { throw MusicAccountError.expired }
            throw MusicAccountError.service
        }
        return data
    }
}

private final class SpotifyOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // These fixed HTTPS endpoints need no redirects. Never forward a token
        // POST body or Authorization header to a redirect destination.
        completionHandler(nil)
    }
}
