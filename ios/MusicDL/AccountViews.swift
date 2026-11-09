import SwiftUI

struct AccountStatusLabel: View {
    let summary: MusicAccountSummary
    var pendingConfiguration = false
    var body: some View {
        Label(pendingConfiguration ? "待配置" : summary.connection.rawValue, systemImage: summary.connection == .connected ? "checkmark.circle.fill" : summary.connection == .authorizing ? "arrow.trianglehead.2.clockwise" : "circle.dashed")
            .font(.caption).foregroundStyle(summary.connection == .connected ? MusicDesign.coral : .secondary)
    }
}

struct AccountDetailScreen: View {
    let source: NativeSource
    @EnvironmentObject private var accounts: MusicAccounts
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var clientID = ""
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
                    if source.id == "apple" { accounts.disconnectApple() }
                    else if source.id == "spotify" { Task { await accounts.disconnectSpotify() } }
                    else { model.perform { try await client.saveCookies([source.id: ""]) } }
                }
            }
    }

    private var appleControls: some View {
        Section("官方 MusicKit") {
            Button(summary.connection == .connected ? "重新验证 Apple Music" : "连接 Apple Music") { Task { await accounts.connectApple() } }
                .disabled(client.isOfflinePreview || summary.connection == .authorizing)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Text("由系统申请音乐访问权限，无需 Apple ID 密码或 Cookie。签名使用的 Bundle ID 还须在 Apple Developer 中开通 MusicKit App Service；仅允许系统权限不代表服务已开通。")
                .font(.caption).foregroundStyle(.secondary)
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
