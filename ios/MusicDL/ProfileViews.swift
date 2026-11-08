import SwiftUI
import CoreImage.CIFilterBuiltins

struct ProfileScreen: View {
    @EnvironmentObject private var client: NativeClient
    @Environment(\.colorScheme) private var scheme
    @AppStorage("music.appearance") private var appearance = "system"
    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    Image(systemName: "waveform.path").font(.system(size: 31, weight: .light)).foregroundStyle(MusicDesign.coral)
                        .frame(width: 66, height: 66).background(MusicDesign.coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("听见自己的节奏").font(.title3.weight(.semibold))
                        Text("你的音乐，由你掌握").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 12).listRowBackground(Color.clear)
            }
            Section("音乐与账号") {
                NavigationLink { AccountsScreen() } label: { Label("音源账号", systemImage: "person.crop.circle.badge.checkmark") }
                NavigationLink { UserPlaylistsScreen() } label: { Label("平台歌单", systemImage: "rectangle.stack.badge.person.crop") }
                NavigationLink { SourceBrowserScreen() } label: { Label("全部音乐来源", systemImage: "globe.asia.australia") }
            }
            Section("偏好设置") {
                Picker(selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") } label: { Label("外观", systemImage: "circle.lefthalf.filled") }
                NavigationLink { SettingsScreen(group: "playback", title: "播放与搜索") } label: { Label("播放与搜索", systemImage: "slider.horizontal.3") }
                NavigationLink { SettingsScreen(group: "download", title: "下载与音质") } label: { Label("下载与音质", systemImage: "waveform.badge.magnifyingglass") }
                NavigationLink { SettingsScreen(group: "webdav", title: "WebDAV") } label: { Label("WebDAV", systemImage: "externaldrive.connected.to.line.below") }
                NavigationLink { SettingsScreen(group: "all", title: "完整设置") } label: { Label("完整设置", systemImage: "gearshape") }
            }
            Section("关于澄音") {
                NavigationLink { AIInfoScreen() } label: { Label("AI API", systemImage: "sparkles") }
                NavigationLink { AboutScreen() } label: { Label("版本与开源许可", systemImage: "info.circle") }
            }
        }.scrollContentBackground(.hidden).background(MusicDesign.canvas(scheme)).navigationTitle("我的")
    }
}

struct AccountsScreen: View {
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section { Text("账号凭证只在本机音乐服务中使用。使用你有权访问的账号与音源。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(client.sources.filter { $0.id != "local" }, id: \.id) { source in
                NavigationLink { CookieScreen(source: source) } label: {
                    HStack {
                        Text(source.name); Spacer()
                        Text((client.cookies[source.id] ?? "").isEmpty ? "未配置" : "已配置").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if client.qrSources.contains("qq_wx") { NavigationLink("QQ 微信扫码登录") { QRLoginScreen(source: "qq_wx", name: "QQ 微信登录") } }
        }.navigationTitle("音源账号").task { model.perform { try await client.loadCookies() } }
    }
}

struct CookieScreen: View {
    let source: NativeSource
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @State private var value = ""
    @State private var reveal = false
    @State private var clearing = false
    @State private var saving = false
    var body: some View {
        Form {
            if client.qrSources.contains(source.id) { Section { NavigationLink { QRLoginScreen(source: source.id, name: source.name) } label: { Label("扫码登录", systemImage: "qrcode") } } }
            Section("Cookie 或平台凭证") {
                if reveal { TextEditor(text: $value).frame(minHeight: 160).font(.system(.caption, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled() }
                else { SecureField("粘贴已授权凭证", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Toggle("显示凭证内容", isOn: $reveal)
                Text(source.id == "spotify" ? "Spotify 使用官方 API 凭证配置。完整歌曲与歌词并非官方 Web API 的下载能力。" : "凭证格式沿用原项目。不要分享给其他人；授权到期时请重新登录。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(saving ? "正在保存…" : "保存凭证") { save(value) }.disabled(saving)
                Button("清除这个音源的凭证", role: .destructive) { clearing = true }
            }
        }.navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
            .task { try? await client.loadCookies(); value = client.cookies[source.id] ?? "" }
            .confirmationDialog("清除\(source.name)凭证？", isPresented: $clearing, titleVisibility: .visible) { Button("清除", role: .destructive) { save("") } }
    }
    private func save(_ text: String) {
        saving = true
        Task {
            defer { saving = false }
            do { var values = client.cookies; values[source.id] = text; try await client.saveCookies(values); value = text; model.notify("已保存账号配置") }
            catch { model.notify(error.localizedDescription) }
        }
    }
}

struct QRLoginScreen: View {
    let source: String
    let name: String
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @State private var session: NativeQRSession?
    @State private var message = "正在创建登录二维码…"
    @State private var retry = 0
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let session, let image = Self.qrImage(session.url) {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 240, height: 240).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24))
                Text("使用\(name)官方客户端扫码").font(.headline)
                if let url = URL(string: session.url), ["https", "http"].contains(url.scheme ?? "") { Link("打开官方登录链接", destination: url).font(.subheadline) }
            } else { Image(systemName: "qrcode").font(.system(size: 80, weight: .ultraLight)).foregroundStyle(.secondary) }
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("重新获取二维码") { session = nil; retry += 1 }.buttonStyle(.bordered)
            Spacer()
        }.frame(maxWidth: .infinity).navigationTitle("扫码登录").navigationBarTitleDisplayMode(.inline)
            .task(id: retry) {
                do {
                    let created = try await client.createQR(source: source)
                    guard !Task.isCancelled else { return }; session = created; message = "等待扫码并在官方客户端确认"
                    for _ in 0..<90 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        let result = try await client.checkQR(source: source, key: created.key)
                        guard !Task.isCancelled else { return }
                        message = result.message ?? result.status
                        if ["authorized", "success", "confirmed"].contains(result.status) { try await client.loadCookies(); model.notify("登录状态已更新"); return }
                        if ["expired", "failed", "error", "cancelled"].contains(result.status) { return }
                    }
                    message = "二维码已过期，请重新获取"
                } catch is CancellationError { } catch { message = error.localizedDescription }
            }
    }
    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct SettingsScreen: View {
    let group: String
    let title: String
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @State private var draft: [String: JSONValue] = [:]
    @State private var saving = false
    @State private var problem: String?
    private var keys: [String] {
        draft.keys.filter { key in
            switch group {
            case "webdav": return key.lowercased().hasPrefix("webdav")
            case "download": return key.lowercased().contains("download") || key == "embedDownload" || key == "autoCacheOnPlay"
            case "playback": return ["autoSwitchInvalidSources", "filterVersionKeywords", "versionFilterKeywords", "filterShortTracks", "normalizeChineseVariants", "lyricFontFamily", "lyricFontSize"].contains(key)
            default: return true
            }
        }.sorted()
    }
    var body: some View {
        Form {
            if group == "download" { Section { Text("下载保留来源返回的音频字节。无损可用性取决于音源授权与设备解码能力，不能把普通音质自动变为无损。").font(.caption).foregroundStyle(.secondary) } }
            if let problem { Section { Text(problem).foregroundStyle(.red); Button("重试") { Task { await load() } } } }
            Section {
                ForEach(keys, id: \.self) { key in setting(key) }
            } footer: { Text(group == "all" ? "这里保留原项目所有配置。网页与命令行专用的选项仍可保存，但不会强行改变原生控件的系统行为。" : "修改后点击保存。未修改的设置与凭证会保留。") }
            if draft.isEmpty && problem == nil { ProgressView("正在读取设置…") }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { save() }.disabled(saving || draft.isEmpty) } }
            .task { await load() }
    }
    @ViewBuilder private func setting(_ key: String) -> some View {
        let binding = Binding<JSONValue>(get: { draft[key] ?? .null }, set: { draft[key] = $0 })
        switch draft[key] ?? .null {
        case .bool: Toggle(Self.label(key), isOn: Binding(get: { binding.wrappedValue.boolValue }, set: { binding.wrappedValue = .bool($0) }))
        case .number:
            HStack { Text(Self.label(key)); Spacer(); TextField("数值", text: Binding(get: { binding.wrappedValue.stringValue }, set: { if let value = Double($0) { binding.wrappedValue = .number(value) } })).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 110) }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.label(key)).font(.subheadline)
                if key.lowercased().contains("password") || key.lowercased().contains("token") {
                    SecureField("未填写", text: Binding(get: { binding.wrappedValue.stringValue }, set: { binding.wrappedValue = .string($0) }))
                } else {
                    TextField("未填写", text: Binding(get: { binding.wrappedValue.stringValue }, set: { binding.wrappedValue = .string($0) }), axis: .vertical).lineLimit(1...4)
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
    private func load() async { do { try await client.loadSettings(); draft = client.settings; problem = nil } catch { problem = error.localizedDescription } }
    private func save() { saving = true; Task { defer { saving = false }; do { try await client.saveSettings(draft); model.notify("设置已保存") } catch { model.notify(error.localizedDescription) } } }
    static func label(_ key: String) -> String {
        ["embedDownload":"写入歌曲标签与封面", "downloadToLocal":"下载到本机", "downloadLyricsToLocal":"同时下载歌词", "downloadDir":"下载目录", "downloadFilenameTemplate":"文件命名规则", "downloadTipDuration":"下载提示时长", "downloadConcurrency":"同时下载任务数", "webdavEnabled":"启用 WebDAV", "webdavUrl":"服务器地址", "webdavUsername":"用户名", "webdavPassword":"密码", "webdavDir":"远程目录", "autoSwitchInvalidSources":"播放失败自动换源", "autoCacheOnPlay":"播放时自动缓存", "filterVersionKeywords":"过滤指定版本", "versionFilterKeywords":"版本过滤关键词", "filterShortTracks":"过滤过短曲目", "normalizeChineseVariants":"兼容简繁体搜索", "lyricFontFamily":"歌词字体", "lyricFontSize":"歌词字号", "autoCheckUpdate":"自动检查更新", "disableFloatingLyrics":"关闭网页浮动歌词", "webPageSize":"网页每页数量", "cliPageSize":"命令行每页数量", "updateRepoUrl":"更新仓库", "githubProxyEnabled":"启用 GitHub 代理", "githubProxyUrl":"GitHub 代理地址", "sodaSignerUrl":"汽水签名服务地址", "sodaSignerToken":"汽水签名令牌", "sodaClientDir":"汽水客户端目录", "vgChangeCover":"视频工具：更换封面", "vgChangeAudio":"视频工具：更换音频", "vgChangeLyric":"视频工具：更换歌词", "vgExportVideo":"视频工具：导出视频", "shortcutPlayPause":"网页快捷键：播放暂停", "shortcutPrevious":"网页快捷键：上一首", "shortcutNext":"网页快捷键：下一首", "shortcutSeekBack":"网页快捷键：快退", "shortcutSeekForward":"网页快捷键：快进"][key] ?? key
    }
}

struct AIInfoScreen: View {
    @EnvironmentObject private var client: NativeClient
    @EnvironmentObject private var model: AppModel
    @State private var information = "正在读取接口说明…"
    var body: some View {
        List {
            Section("原生播放器连接") {
                Text("AI 指令通过原生连接交给同一个音频引擎。界面关闭或被系统挂起后，控制可达性仍受 iOS 生命周期约束。")
                Text("本机接口：127.0.0.1:37777/music/api/ai").font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("能力说明") { Text(information).font(.caption.monospaced()).textSelection(.enabled) }
        }.navigationTitle("AI API").task {
            do { let value = try await client.aiIndex(); let data = try JSONEncoder().encode(value); information = String(decoding: data, as: UTF8.self) }
            catch { information = error.localizedDescription }
        }
    }
}

struct AboutScreen: View {
    var body: some View {
        List {
            Section {
                Text("澄音 · MusicDL").font(.title2.bold())
                Text("原生 iOS 客户端 · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                Text("基于 Go Music DL，使用原生系统组件与独立视觉设计。")
            }
            Section("源码与许可") {
                Link("原项目", destination: URL(string: "https://github.com/guohuiyuan/go-music-dl")!)
                Link("本版本源码与构建", destination: URL(string: "https://github.com/yann359/go-music-dl/tree/codex/ios-native-redesign")!)
                NavigationLink("GNU AGPL v3") { LicenseText(name: "LICENSE", ext: nil) }
                NavigationLink("第三方许可证") { LicenseText(name: "ThirdPartyNotices", ext: "txt") }
            }
            Section { Text("仅使用已获授权的账号与音乐资源。真机后台、来电和耳机行为需在实际设备上验收。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("关于澄音")
    }
}

struct LicenseText: View {
    let name: String
    let ext: String?
    var body: some View {
        ScrollView { Text(Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "许可文件尚未随本次构建打包，请查看对应源码仓库。")
            .font(.caption.monospaced()).textSelection(.enabled).padding(20) }.navigationTitle("开源许可")
    }
}
