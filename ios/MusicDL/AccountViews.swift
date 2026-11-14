import SwiftUI

struct AccountStatusLabel: View {
    @Environment(\.musicAccent) private var accent
    let summary: MusicAccountSummary
    var pendingConfiguration = false
    var body: some View {
        Label(pendingConfiguration ? "待配置" : summary.connection.rawValue, systemImage: summary.connection == .connected ? "checkmark.circle.fill" : summary.connection == .authorizing ? "arrow.trianglehead.2.clockwise" : "circle.dashed")
            .font(.caption).foregroundStyle(summary.connection == .connected ? accent : .secondary)
    }
}

struct AccountDetailScreen: View {
    let source: NativeSource
    @EnvironmentObject private var accounts: MusicAccounts
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var clientID = ""
    @State private var appleOrigin = ""
    @State private var disconnect = false
    private var summary: MusicAccountSummary { accounts.summary(source.id) }
    private var canDisconnect: Bool {
        if source.id == "spotify" { return accounts.spotifyConfigured && summary.connection != .disconnected }
        if source.id == "apple" { return summary.connection != .disconnected }
        return !(client.cookies[source.id] ?? "").isEmpty
    }
    var body: some View {
        Form {
            Section {
                HStack { Text(source.name).font(.headline); Spacer(); AccountStatusLabel(summary: summary, pendingConfiguration: source.id == "spotify" && !accounts.spotifyConfigured) }
                if let account = summary.account { LabeledContent("账号", value: account) }
                Text(summary.detail).font(.subheadline).foregroundStyle(.secondary)
                if client.isOfflinePreview { Text("界面回归样例不会发起真实系统授权。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("已有能力") {
                Text(source.capabilityDescription).font(.subheadline).foregroundStyle(.secondary)
                if source.id == "apple" || source.id == "spotify" {
                    Text("账号授权、API 访问权限与完整歌曲播放是不同能力。本 App 不会因登录成功而声称拥有整曲播放或下载权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if source.id == "apple" { appleControls }
            else if source.id == "spotify" { spotifyControls }
            else { legacyControls }
            if canDisconnect {
                Section { Button("断开连接", role: .destructive) { disconnect = true } }
            }
        }.navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
            .task {
                clientID = accounts.spotifyClientID
                appleOrigin = accounts.appleBrowser.origin
                guard !client.isOfflinePreview else { return }
                if source.id == "apple" { await accounts.refreshApple() }
                else if source.id == "spotify", accounts.spotifyConfigured { await accounts.restore() }
                else if source.id != "spotify" { try? await client.loadCookies() }
            }
            .onChange(of: phase) { _, value in
                if value == .active && !client.isOfflinePreview {
                    if source.id == "apple" { Task { await accounts.refreshApple() } }
                    else if source.id == "spotify", accounts.spotifyConfigured { Task { await accounts.restore() } }
                }
            }
            .confirmationDialog("断开\(source.name)？本地歌单与播放记录会保留。", isPresented: $disconnect, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) {
                    if source.id == "apple" { Task { await accounts.disconnectApple() } }
                    else if source.id == "spotify" { Task { await accounts.disconnectSpotify() } }
                    else { model.perform { try await client.saveCookies([source.id: ""]) } }
                }
            }
    }

    private var appleControls: some View {
        Group {
            Section("浏览器连接 · 优先") {
                LabeledContent("授权状态", value: accounts.appleBrowser.summary.connection == .connected ? "连接成功" : accounts.appleBrowser.summary.connection.rawValue)
                    .accessibilityIdentifier("apple-browser-state")
                if !accounts.usesAppleBrowser { Text(accounts.appleBrowser.summary.detail).font(.caption).foregroundStyle(.secondary) }
                Button("通过浏览器连接 Apple Music") { Task { await accounts.connectAppleBrowser() } }
                    .disabled(client.isOfflinePreview || accounts.appleBrowser.summary.connection == .authorizing || accounts.appleBrowser.hasPending)
                    .accessibilityIdentifier("apple-browser-connect")
                if accounts.appleBrowser.hasPending {
                    Button("取消授权") { Task { await accounts.appleBrowser.cancel() } }.disabled(client.isOfflinePreview)
                } else {
                    Button("重新授权") { Task { await accounts.reauthorizeAppleBrowser() } }.disabled(client.isOfflinePreview)
                    Button("验证已有浏览器连接") { Task { await accounts.appleBrowser.restore() } }.disabled(client.isOfflinePreview)
                }
                Text("打开系统浏览器后，请在网页点击继续，由 Apple 官方页面处理账号、密码和双重认证。授权后返回 App 校验；若浏览器未自动返回，请点击网页的返回按钮。网页授权不等于原生完整歌曲播放权限。")
                    .font(.caption).foregroundStyle(.secondary)
                if AppleMusicBrowser.validOrigin(accounts.appleBrowser.origin), let url = URL(string: accounts.appleBrowser.origin + "/disconnect") {
                    Link("在浏览器撤销此网站的音乐授权", destination: url)
                }
            }
            Section("音乐资料") {
                NavigationLink("同步资料、查看歌单与搜索歌曲") { AppleMusicLibraryScreen() }
                    .disabled(client.isOfflinePreview || summary.connection != .connected)
                Text("仅在实际授权范围内读取资料。歌单导入仍在“音乐库 → 自建歌单 → 导入其他软件的歌单 → Apple Music”中确认，不会直接覆盖原有歌单。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("系统授权 · 备用") {
                LabeledContent("独立授权状态", value: accounts.appleSystemSummary.connection.rawValue)
                Text(accounts.appleSystemSummary.detail).font(.caption).foregroundStyle(.secondary)
                Button("系统授权") { Task { await accounts.connectApple() } }
                    .disabled(client.isOfflinePreview || accounts.appleSystemSummary.connection == .authorizing)
                    .accessibilityIdentifier("apple-system-authorize")
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Text("由 iOS 申请音乐权限，使用当前签名 Bundle ID 对应的 MusicKit App Service。免费个人重签不能假定具备服务资格；此项不会使用浏览器音乐令牌。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("开发者服务配置（公开地址）") {
                TextField("HTTPS 授权服务地址", text: $appleOrigin).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("apple-relay-origin")
                Button("保存服务地址") { Task { await accounts.configureAppleBrowser(appleOrigin) } }
                    .disabled(client.isOfflinePreview || summary.connection == .authorizing)
                Text("仅填写你自己部署或信任的服务域名，例如 https://music.example.com。该服务将处理音乐访问令牌；不要使用陌生地址。需要 Apple Developer Program、Media ID 和服务器端密钥；密钥、密码和 Token 均不应填在此处。未配置时会明确显示服务不可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var spotifyControls: some View {
        Group {
            Section("官方浏览器授权") {
                if summary.connection == .authorizing { Button("取消授权") { accounts.cancelSpotify() } }
                else {
                    Button(summary.connection == .connected ? "重新授权 Spotify" : "连接 Spotify") { Task { await accounts.connectSpotify() } }
                        .disabled(client.isOfflinePreview || !accounts.spotifyConfigured)
                    if accounts.spotifyConfigured { Button("恢复并验证连接") { Task { await accounts.restore() } }.disabled(client.isOfflinePreview) }
                }
                if !accounts.spotifyConfigured {
                    Text("待配置。可先使用其他音乐来源；Spotify 开发模式对应用所有者有 Premium 资格要求，暂不配置不会影响其他功能。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("在 Spotify 管理应用授权", destination: URL(string: "https://www.spotify.com/account/apps/")!)
            }
            Section("开发者配置（公开信息）") {
                TextField("Spotify Client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("spotify-client-id")
                Text("无需填写 Client Secret、Token 或密码。若尚无开发者应用，可保持未配置。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("回调地址") { Text(SpotifyConfiguration.redirect).font(.caption).textSelection(.enabled) }
                Button("保存 Client ID") { Task { await accounts.configureSpotify(clientID: clientID) } }
                    .disabled(client.isOfflinePreview || summary.connection == .authorizing)
                Link("Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                Text("在自己应用的 Dashboard 中登记此完整回调地址，并添加 Bundle ID 及获准测试用户。若后台不接受原生回调或账户不满足开发模式要求，请保持待配置；不要填写其他应用的 Client ID。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var legacyControls: some View {
        Group {
            Section("现有账号连接") {
                Button("验证连接") { Task { await accounts.validateLegacy(source: source.id, client: client) } }
                    .disabled(summary.connection == .authorizing)
                if client.qrSources.contains(source.id) {
                    NavigationLink("兼容扫码登录（原项目）") { QRLoginScreen(source: source.id, name: source.name) }
                }
                if source.id == "qq", client.qrSources.contains("qq_wx") {
                    NavigationLink("微信扫码登录（原项目）") { QRLoginScreen(source: "qq_wx", name: "QQ 音乐") }
                }
                NavigationLink("手动配置（兼容旧版）") { CookieScreen(source: source) }
            }
            Section {
                Text(source.id == "soda" ? "尚未确认可供此应用使用的汽水官方第三方授权接口；原项目的扫码暂不可用。保留既有凭证能力与音乐功能，不将抖音登录当作汽水音乐授权。" : "当前扫码沿用开源项目接口。尚未确认面向此应用、已获接入资格的官方音乐 OAuth，不把兼容扫码标为官方开放授权；无需向本 App 提供平台密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension NativeSource {
    var capabilityDescription: String {
        [search ? "搜索" : nil, album ? "专辑" : nil, playlist ? "歌单" : nil, recommend ? "推荐" : nil,
         toplist ? "排行榜" : nil, category ? "分类" : nil, userPlaylists ? "账号歌单" : nil,
         id == "apple" || id == "spotify" ? "可用时的预览音频" : "音频能力依来源与账号权限"].compactMap { $0 }.joined(separator: " · ")
    }
}
