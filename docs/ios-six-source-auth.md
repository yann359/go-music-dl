# 六来源与原生账号授权维护说明

日期：2026-11-09（北京时间）。在现有 SwiftUI + Go 工程上实施；没有重建项目，没有更换 AudioEngine 或底部 Liquid Glass 结构。

## 范围、分支与回滚

- 当前分支：`codex/six-sources-official-auth`，原始基线 `69e94bb`。
- 上轮未提交修改（10 个修改文件、8 个新文件）已完整备份在外层 `outputs/six-sources-auth-baseline/`，并保存为本地检查点提交 `ee4746adfe82de631b2bded57da4c20c000e1013`。本轮另存提交，没有推送远端、强推或重置工作目录。
- 唯一在线平台：网易云音乐、Apple Music、QQ 音乐、汽水音乐、酷狗音乐、Spotify。
- `local`/`local-file` 仍是设备文件能力，不是第七个在线音乐平台；原生来源目录和账号页面均只返回/显示六个平台。内部 `GetAllSourceNames` 保留本地搜索兼容，在线集合由 `GetMusicPlatformNames` 明确提供。
- 用户明确使用 Spotify Free 且不升级 Premium：Spotify 真实授权保留**待配置**，不会自动打开浏览器、要求升级或阻塞其他五个来源。即使同时选择 Spotify 与其他来源，授权未配置/刷新失败也会保留其他来源结果，并解释 Spotify 未就绪。

## 删除与保留

已删除的在线来源：咪咕、酷我、5sing、Jamendo、JOOX、千千、Bilibili。

清理覆盖：

1. `core/service.go` 和 `internal/cli/ui.go` 的工厂导入、搜索/解析/专辑/歌单/推荐/榜单/分类/歌词/下载/扫码注册、默认集合、名称及链接生成。
2. `core/player.go`、`core/download.go` 的咪咕取流、加密音频解密、特殊 UA/Referer 和下载分支。
3. 上轮 `core/migu_lyrics.go` 及专属测试；共享错误分类/编码校验移到 `core/lyric_errors.go`，歌词缓存、有限重试、严格备用匹配和去重仍保留。
4. 网页账号配置提示、CLI 帮助、JS 源列表/名称和独占来源测试/表格用例；共享下载队列测试改用保留平台，保留测试原有目的。
5. 链接检测按真实 URL 主机识别六个平台；不会把 `5sing.kugou.com` 错认成酷狗，或根据已删除平台 URL 的 query 中夹带其他平台地址而选错源。

没有为剪裁音源复制或替换整套 music-lib。该模块仍是五个保留适配器及 model/utils/lyrics 的必要公共依赖，Spotify 是现有 `internal/spotify` 适配器。编译依赖清单 `outputs/six-sources-dependencies.txt` 已证实七个已删除平台的包均未进入依赖图。

废弃平台名称只可能出现在历史文档、拒绝/兼容回归断言和通用第三方图标包中，不再对应可执行适配器或页面入口。共享图标字体没有当作某个平台专属资源删除。

## 用户数据兼容

- 不改 SQLite 表结构，不清空收藏、歌单、下载记录或播放历史。
- 手动歌单内旧来源曲目保留标题、歌手、时长等原数据；界面标记“来源已移除 · 记录保留”。批量播放只将可用条目送入播放队列，不修改保存的歌单。
- 已移除来源的导入歌单保留元数据；已有保存快照仍可读取，没有快照时明确解释无法继续读取上游。不会静默把另一首歌曲当作原条目。
- 旧凭证行保持原样以便回滚，但不再进入当前账号接口。原生 Apple Music/Spotify 不读取或使用旧数据库凭证进行隐式登录，Spotify Access Token 只保留在 Go 进程内存。
- 本地文件仍通过音乐库读取。网页播放历史原有 localStorage 存储键和清空逻辑未改变，也不新增平行历史数据库。

## Apple Music

真实代码路径：账号详情 → `MusicAuthorization.request()` → 检查系统授权 → `MusicDataRequest` 访问 `/v1/me/storefront` → 校验真实用户 storefront 响应 → `MusicSubscription.current` 检查订阅能力 → 更新连接状态。

- 已添加 `NSAppleMusicUsageDescription`，显式链接 MusicKit。
- 开发者令牌和 Music User Token 交给 MusicKit 自动管理，不要求用户输入 Apple ID 密码、提取 Cookie，也不在 App 内放开发者私钥。
- 只有权限允许、真实用户接口成功且响应结构有效才显示已连接。首次拒绝显示未连接；原先验证成功后被系统撤销则显示授权失效。SDK 不能可靠区分所有系统弹窗的拒绝/取消细节，界面说明未取得授权并提供系统设置入口。
- 断开是停止本 App 的 MusicKit 访问；系统隐私权限需用户在 iOS 设置中撤销，不会声称已经撤销 Apple 账号的系统授权。
- 原生 Go Apple 适配器不再偷偷使用旧 Cookie，保留现有公共目录/preview 能力；账号的个人访问通过官方 MusicKit 验证。没有将现有 AVQueuePlayer 改成第二套 MusicKit DRM 播放器，也没有声称完整歌曲下载已实现。

需要的实际配置：

1. 在 Apple Developer 的 Identifiers 中为实际签名的 Explicit Bundle ID 开启 **MusicKit App Service**。当前默认 Bundle ID 是 `com.guohuiyuan.musicdl.nativedesign`；若 SideStore 重签后使用不同 ID，必须以实际 ID 为准。
2. 使用与该 App ID/服务匹配的签名配置，在真机授权并验证。MusicKit App Service、系统权限与 Apple Music 订阅是三件独立的事；没有虚构 entitlement、Team ID 或开发者令牌。
3. 当前 Windows 无 Xcode/iPhone，也没有可核实的 Apple 开发者 App Service/签名配置。个人签名是否可用不能凭权限弹窗推断；服务未开通或运行失败会显示当前环境不可用及下一步。

官方依据：[系统音乐权限](https://developer.apple.com/documentation/musickit/musicauthorization/request())、[自动开发者令牌/App Service](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)、[用户 Token 自动管理](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)、[用户 Storefront 验证端点](https://developer.apple.com/documentation/applemusicapi/get-a-user%27s-storefront)。

## Spotify

已实现代码：

- `ASWebAuthenticationSession` 打开固定 Spotify 官方授权域，Spotify 页面自行决定提供哪些登录方式；没有自制 Google 登录或会话抓取。
- `SecRandomCopyBytes` 生成 verifier/state；SHA256 + Base64URL 实现 S256；验证回调 scheme/host/path/state 及重复参数；只接受 Authorization Code。
- 固定 HTTPS Token 端点交换 code，提交 verifier 和公开 Client ID，不提交 Client Secret；Token/Profile 请求拒绝重定向，防止凭证被转发。
- Token 响应类型/有效期/Refresh Token 校验，调用官方 `/v1/me` 确认账户后才显示已连接。
- Keychain 保存 Token（AfterFirstUnlockThisDeviceOnly）；UserDefaults 仅存公开 Client ID 和非敏感状态。恢复时检查到期，刷新可合并，保留未轮换的 Refresh Token；invalid_grant 标记必须重新授权。
- Go 通过现有 C ABI 只接收短期 Access Token 和到期时间，不把 Token 写入 SQLite。原生模式不回退使用旧服务器 Client Secret/Token 配置。
- API 401 最多强制刷新一次，覆盖直接错误和多来源部分错误；其他来源已成功的数据继续保留。播放解析同样有限重试，不无限刷新。
- 断开清理 Keychain、内存及 Go 会话；即使桥接不可用，也会尝试清除本机存储。服务器端撤销由用户在 Spotify 官方应用管理中完成，界面有入口。

本 App 原生回调：`com.guohuiyuan.musicdl.spotify-login://oauth/callback`。Info.plist 已注册对应 scheme，但**尚未在用户自己的 Dashboard 登记或完成真实往返验证**。

当前无需用户配置或升级。将来具备开发者资格并决定验证时，最少步骤是：创建自己的开发者 App，登记上述完整回调/实际 Bundle ID 和获准测试用户，把公开 Client ID 填入账号页（也支持 `SPOTIFY_CLIENT_ID` 构建变量）。不要提供 Client Secret。此回调采用官方 iOS 文档的原生 scheme 形式；若实际后台不接受，则需用户自有 HTTPS 域名、Associated Domains/AASA 配置后另行接入，不能拿示例网址假装已登记。

按当前官方规则，开发模式对 App 所有者有 Premium 资格要求；用户选择 Free 且暂不升级，所以真实登录明确待配置。开发模式也限制推荐、分类及公开榜单内容：保留原有服务端/扩展模式适配代码，但原生目录不将这些旧端点标为可用功能。个人/协作歌单、目录搜索及有返回时的预览仍依真实 API 授权与模式决定；没有整曲或歌词下载承诺。

官方依据：[PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)、[iOS 回调配置](https://developer.spotify.com/documentation/ios/getting-started)、[Redirect URI 规则](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)、[2026 开发模式迁移](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)。

## 其他四个平台

| 平台 | 保留的账号方式 | 真实边界 |
| --- | --- | --- |
| 网易云 | 原项目兼容扫码、手动已有凭证 | 未查证适用于此 App 且有接入资格的官方音乐 OAuth；不要求平台密码 |
| QQ 音乐 | 原项目 QQ/微信兼容扫码、已有凭证 | QQ 身份登录不能当作 QQ 音乐开放 API 资格；不伪装官方 OAuth |
| 酷狗 | 原项目兼容扫码、已有凭证 | 兼容接口可用性取决于平台；没有虚构开放授权协议 |
| 汽水 | 原项目已有凭证 | 现有扫码不在可用列表；不把抖音 OAuth 假装成汽水音乐授权 |

四个平台都先验证实际账号歌单接口，保存凭证本身不等于已连接。验证有截止时间；失败区分授权失效与当前无法访问，界面不展示 URL、Token 或堆栈。只验证用户进入的账号，不在首页串行探测全部账号。

研究过官方平台入口及已固定的 music-lib 登录实现；没有足够官方证据确认这些兼容接口属于允许个人 App 接入的公开 OAuth，因此明确保留限制，没有新增抓取 Cookie 或伪造登录页。

## 文件归属与回归

主要文件：

- 注册/清理：`core/service.go`、`core/player.go`、`core/download.go`、`internal/cli/ui.go`、`cmd/music-dl/root.go`。
- 数据兼容与账号桥接：`core/native_accounts.go`、`internal/web/native_accounts.go`、`internal/web/native_client.go`、`native_playback.go`、`collection.go`、`server.go`、`ios/bridge/main.go`。
- 安全 Token 接入：`internal/spotify/native_session.go`、`internal/spotify/spotify.go`（含当前 items/旧 tracks 字段兼容）、`ios/MusicDL/AudioModel.swift`。
- 原生授权：`SpotifyOAuth.swift`、`WebAuthentication.swift`、`SecureAccountStorage.swift`、`MusicAccounts.swift`、`AccountViews.swift`；SDK/配置在 `ios/project.yml` 和 `Info.plist`。
- 原生入口/状态：`NativeRoot.swift`、`NativeAppModel.swift`、`NativeClient.swift`、`SourceViews.swift`、`ProfileViews.swift`、`NativeScreens.swift`。
- 共享歌词：`core/lyric_errors.go` 与 `internal/web/native_lyrics.go`，保留上阶段 Foundation `Lyrics.swift` 和播放器歌词展示。AudioEngine、PlayerViews、Lyrics.swift 相对检查点未修改。
- 网页：`templates/partials/modals.html`、`templates/static/js/app.js`；Apple/Spotify 不再提供默认粘贴框，网页明确引导原生官方授权，不冒充网页已实现 OAuth。
- 测试：新的 `source_registry_test.go`、`native_accounts_test.go`、`native_session_test.go`、`SpotifyAuthorizationTests.swift`；调整原来源表格、下载队列 fixture、NativeClient、真实 Go 桥接的六平台断言和 UI 回归。

最终可运行验证、跳过原因和逐文件 Git 状态记录在外层 `outputs/six-sources-verification.json`；Go 原始结果 `six-sources-go-tests.jsonl`，编译依赖 `six-sources-dependencies.txt`，lint 结果单独留存。

本轮实际结果：

| 检查 | 结果与边界 |
| --- | --- |
| Go 六包测试 | 344 通过、8 跳过、0 失败；涵盖 core/web/spotify/cli/appshell/cmd |
| 最后请求头整理后的定向回归 | core 的原生 Apple 旧凭证隔离/请求头回归通过 |
| Node 桥接 / JavaScript 语法 | 6/6 通过 / 通过 |
| go vet / Windows 后端构建 | 通过 / 通过；不等于 iOS C ABI/Swift 构建通过 |
| 增量 golangci-lint | 0 issues；新增 Go 文件也没有全量报告项 |
| 全量 golangci-lint | 未通过，77 项：errcheck 49、staticcheck 24、unused 3、ineffassign 1；不扩大范围清理既有问题 |
| 依赖 / Info.plist | 七个退役适配器不在编译图；音乐用途声明和回调 scheme 检查通过 |
| go mod tidy | 未完成：下载既有 Gio 字体测试依赖时 TLS handshake timeout；go.mod/go.sum 均未更改 |

8 项跳过用例是已有的网易云 FLAC/耗时诊断、升级后歌曲/歌单网络集成、汽水短链接歌曲/歌单和真实来源连接耗时诊断；需要对应账号、网络或显式开关。没有把跳过计为通过，也没有新增真实授权或 iPhone 性能数据。

目前不能宣称的项目：iOS Swift 类型检查/Release 编译、38 项原生单元测试、5 项 UI 测试、真实系统授权/回调/Keychain、六平台真机音频/歌词/锁屏/后台及实际签名均未在 Windows 执行。没有生成新 IPA，旧 Build 12 不包含本轮修改。

下一步只针对本轮验收：在 macOS 执行现有 XcodeGen/package 与 XCTest/UI 工作流，审查深浅色/空播放器截图；成功后用实际签名验证 MusicKit 和 iPhone 播放回归。Spotify 按用户选择继续待配置，等用户以后主动决定具备条件时再做真实登录验收。
