# 项目持续状态

## 2026-11-09：全部来源恢复与稳定性专项（代码与 Windows 验证完成，iOS 验收待执行）
- 分支 `codex/source-recovery-stability`，干净基线 `3bf0333`；原授权分支与旧 IPA 保留。未推送、未发布、未清除用户数据；SQLite 结构不变。
- 全部原有 **13 个在线来源 + 本地音乐**恢复，按 `ee4746a` 差异合并 Provider/播放/下载/歌词/CLI/账号入口。保留 MusicKit、Spotify PKCE/Keychain、Liquid Glass、歌词优化及原播放器。
- P0 播放：显式激活成功后清除残留中断；校验失败实例/丢失缓存文件；有限 watchdog 重建并保留队列/进度；状态由 AVPlayer 真值派生；旧队列清理不能删除新队列音频；过期 URL 最多重取一次。
- P0 服务：iPhone 内嵌 Go 核心，不依赖 Windows。原生收藏/本地/下载操作改走进程内路由，保留写入守卫；可选 AI 连接只绑定 127.0.0.1。修复桥接及配置数据库 sync.Once 首次失败后无法重试的问题；前端启动合并/3 次退避/前台重检，AI 重连有界。
- P1 数据：同来源 2 个底层调用槽、8 秒调用方截止、重复请求合并、跨来源搜索最多 3 并发且逐项显示；详情缓存 15 分钟复用/24 小时失效/最多 40 条及 8 MB，失败/部分结果不提升为完整缓存。详情 UUID 隔离旧请求，空/部分/成功/失败分开呈现，分页成功后才前进。缓存与存储结构独立。
- Windows 回归：Go 六包 **353 通过 / 13 跳过 / 0 失败**；Node **6/6**、JS 语法、go vet、后端构建通过；增量 golangci-lint **0 issues**。新增失败启动重试、端口被占用仍可读写 SQLite、来源隔离、详情部分/空/超时及请求合并验证。
- 真实公开接口：七个恢复来源均返回歌曲搜索结果；网易云/QQ/酷狗/酷我/咪咕/汽水/JOOX/Bilibili 抽样歌单可读；5sing 的抽样歌单详情失败，Apple 旧目录 index.js 解析失败，Spotify 缺授权配置，均不宣称可用。未验证整曲播放/所有歌单/地区与账号权限。
- 真实热歌榜两轮交叉顺序：旧路径 526.0901 / 456.6591 ms，新路径 478.7836 / 481.3941 ms，均 200 首；没有稳定网络耗时改善证据，不宣称 iPhone 性能提升比例。缓存首屏与后台恢复必须用新包实测。
- REA 6.4.0 当前可连，但无打开目标、留存证据为 0；本轮未借用第三方播放器代码。恢复来源沿用现有 AGPLv3 music-lib，保留 LICENSE/NOTICE。
- Windows 没有 Xcode、Swift/iOS SDK 或连接的 iPhone；当前 Swift 单元/UI 测试仅为源码待验收，没有新 IPA。不能把旧 Build 12 当作本轮修复包。
- 逐文件清单、原始证据、真实限制与真机步骤见 [专项报告](docs/ios-source-recovery-stability.md)。下一步：在现有 macOS 工作流构建并执行 XCTest/UI，再签名安装完成真机矩阵。

更新：2026-11-09（北京时间）。每次开发结束或可控中断前更新本文件；以下状态只描述已验证事实。

## 上阶段：六来源清理与官方账号授权（历史记录，六来源限制已被本轮撤销）
- 独立分支 `codex/six-sources-official-auth`，原始基线 `69e94bb`。原有 10 个已修改文件与 8 个未跟踪文件完整备份到外层 `outputs/six-sources-auth-baseline/`，并保存为本地检查点 `ee4746adfe82de631b2bded57da4c20c000e1013`。本轮改动另存本地提交，不推送、不强推、不重置用户数据。
- 唯一在线来源：网易云、Apple Music、QQ、汽水、酷狗、Spotify；本地文件作为独立能力保留。删除咪咕、酷我、5sing、Jamendo、JOOX、千千、Bilibili 的工厂、专属播放/下载/歌词分支、登录入口及独占测试；Go 编译依赖图已验证不含这七个适配器。公共 music-lib 保留给五个目标适配器使用。
- 根因与架构决策：旧来源由多个工厂、CLI 和 Web/原生目录共同注册，必须同步清理；旧 Apple/Spotify 只有手填凭证、没有原生授权生命周期。新增官方授权所有者，保留原播放器，原生模式隔离旧 Apple Cookie 和 Spotify Secret/Token 回退；绝不以保存凭证或获得系统权限代替实际服务验证。
- Apple 使用 `MusicAuthorization.request()`、真实用户 storefront 校验及订阅资格检查；Spotify 实现 PKCE/S256/state/ASWebAuthenticationSession/Keychain/到期刷新/401 有限重试，Go 仅接收内存短期 Access Token。统一账号页显示实际状态、能力与限制，Apple/Spotify 无默认 Cookie 输入框。
- 用户确认 Spotify Free 且不升级 Premium：真实 Spotify 授权保持“待配置”，未配置不会打开浏览器或阻塞其他来源。没有真实 Client ID、已登记回调或端到端登录结果。
- 网易云/QQ（含微信）/酷狗沿用已有兼容扫码，汽水保留已有凭证；都需实际验证账号歌单接口才显示已连接。未查证此应用具备官方音乐 OAuth 接入资格，不把原项目兼容接口标为官方授权。
- 数据兼容：旧来源条目、收藏、歌单、历史及凭证行保留，不改数据库结构；旧曲目标记来源已移除，播放队列跳过但不改保存条目。导入歌单保留已存快照。AudioEngine、PlayerViews、Lyrics.swift 相对检查点未修改，保留上轮空附件、连接、歌词重试与去重修复。
- Windows 验证：Go 六包 **344 通过 / 8 跳过**；最后请求头整理后再次通过 core 定向回归。Node 桥接 **6/6**、JavaScript 语法、go vet、Windows 后端构建、Info.plist 和依赖清理检查通过；增量 golangci-lint **0 issues**，新增 Go 文件无全量 lint 报告项。
- 未通过/未执行：全量 lint **77 项**（errcheck 49、staticcheck 24、unused 3、ineffassign 1）；`go mod tidy` 下载既有 Gio 字体测试依赖时 TLS 握手超时，go.mod/go.sum 未变。38 项 Swift 单元测试和 5 项 UI 测试在源码中就绪，Windows 无 Xcode，均未编译运行；8 项 Go 跳过用例需要账号、公开网络或显式诊断开关。
- 实际配置阻碍：Apple 需要与实际签名 Bundle ID 一致的 MusicKit App Service 和可用开发者配置，个人签名不能假定支持；Spotify 按用户决定继续待配置，当前开发模式 App 所有者 Premium 规则及回调限制见报告。没有新 IPA；旧 Build 12 不包含本轮代码。
- 修改文件、官方依据、回滚与测试边界见 [六来源授权报告](docs/ios-six-source-auth.md)；原始测试、逐文件清单及汇总证据在外层 `outputs/six-sources-verification.json`、`six-sources-go-tests.jsonl`、`six-sources-dependencies.txt`。
- 下一步仅为本轮验收：在 macOS 运行现有 XcodeGen/Release/XCTest/UI 工作流，通过后用实际签名验证 Apple Music 和 iPhone 的六来源搜索、播放、歌词、收藏、队列、后台/锁屏及深浅色安全区。Spotify 保持待配置，待用户以后主动决定满足条件时再做真实登录验证；不能宣称验收 A–I 全部通过。

## 上阶段：四项问题修复（代码已实现，iOS 验收待执行）
- 日期：2026-11-09；恢复基线 `69e94bb`，仓库初始干净，保留外层未跟踪目录、用户数据、所有旧 IPA。继续使用 `codex/ios-native-redesign`，本轮未提交/推送。
- 已定位并修改：空内容仍挂载底部附件；推荐聚合等待慢源且再串行请求榜单；歌词一次失败直接上抛；逐字方括号时间被当成整句的重复起点。
- 首页按当前歌曲启停 iOS 26.1+ 附件；来源最多 3 并行、6 秒调用截止、同源请求合并、逐项显示、成功结果 15 分钟复用/24 小时过期、单项及网络恢复重试。
- 歌词增加咪咕可取消请求、完整响应体校验和解码、最多 3 次退避重试、同曲缓存、严格歌名/歌手/专辑/已知时长匹配的已有来源降级；只对连续署名去重，保留正常重复正文。
- 修改集中在原生 Root/Client/Discover/Player、独立 Foundation 歌词解析和 Go 原生来源/歌词请求层；未改 AudioEngine、SQLite 数据结构、音源列表或视觉设计规范。完整逐文件清单、根因与恢复位置见 [四项维护报告](docs/ios-maintenance-2026-11-09.md)。
- Windows 回归：Go 六包 338 通过/11 跳过，Node 6/6，go vet、Windows 后端构建通过；增量 golangci-lint 0 issues。全量 lint 84 个存量问题未通过，不扩大范围清理；Go race 因无 CGO 编译器未执行。
- 实测 Windows 公开来源一次旧顺序/新并行：首内容 335.561/81.125 ms，全部 428.102/155.880 ms，结果数量一致；先旧后新有 DNS/连接复用偏差，不能宣称 iPhone 冷启动提升比例。受控弱源首内容 220.180/25.510 ms，仅为模型测试。
- 新 Swift 单元回归 10 项和 UI 回归 2 项已补，尚未编译运行。当前 Windows 无 Xcode/iPhone；冷/热启动、移动弱网、布局/深浅色截图、后台返回及真实歌词高亮仍待 macOS/真机验收，不能视为 A–E 全部通过。
- 依赖风险：旧 music-lib 无 context，调用方 6 秒返回后底层可能继续到两分钟；并发槽保持占用、重复请求合并，避免无限堆积。歌词备用匹配刻意保守；缺少确切歌曲 ID，未验证用户那一首上游原文。
- 下一步仅为本轮验收：运行现有 macOS 原生编译/XCTest/UI 工作流，成功后打包新 IPA 并完成上述 iPhone 检查。本轮没有新 IPA；下面历史 Build 12 不包含这些修复。

## 上阶段完成：SideStore App ID 名称修复
- 用户报告 `SideSign.DeveloperPortalError 10`，参数 `appIdName` 为 `澄音 MusicDL`；旧 Build 11 的实际包元数据含该显示名。
- 仅将 Info.plist 的 `CFBundleDisplayName`、`CFBundleName` 与应用构建 `PRODUCT_NAME` 统一为纯英文 `MusicDL`；Bundle Identifier 继续为 `com.guohuiyuan.musicdl.nativedesign`。
- 打包脚本检查构建产物及 IPA 内的实际名称、Bundle ID，防止仅改源配置却未生效。
- 不修改业务代码、播放行为或 App 内界面文案；旧 IPA 保留，Build 11 的 SHA256 再次核对未变。
- 名称修复提交：`35bfc86ae5673754d9f1e138c32c759bb3f5bbc4`；[构建 42588799339](https://github.com/yann359/go-music-dl/actions/runs/42588799339) **成功**。原有回归：17 项原生测试、2 项 UI 测试通过；未为文档结果更新重复构建。
- 新 IPA：**Build 12**，本机 `../outputs/ios-sidestore-name-fix/music-dl-ios-native-unsigned.ipa`；[云端安装包/对应源码/许可证](https://github.com/yann359/go-music-dl/actions/runs/42588799339/artifacts/13661057643)。下载 artifact ZIP，解压后将新 IPA 导入 SideStore 重签。
- 实际 IPA 内核验：`CFBundleDisplayName=MusicDL`、`CFBundleName=MusicDL`、`CFBundleExecutable=MusicDL`、`CFBundleIdentifier=com.guohuiyuan.musicdl.nativedesign`、`CFBundleVersion=12`。无 `InfoPlist.strings` 名称覆盖，arm64，后台 `audio` 声明保留，无 `_CodeSignature` 目录。
- IPA SHA256：`b71ce9fdbb548100d049b5df432bbb96bc4e94c9318048fb6b826222da60f098`；与构建附带校验文件一致，源码提交核对一致。下载 artifact ZIP 自身 SHA256 也与 Actions digest 一致。详细本地结果：`../outputs/ios-sidestore-name-fix/verification.json`。
- 本阶段源码变更仅 `ios/MusicDL/Info.plist`、`ios/project.yml`、`ios/scripts/package.sh` 与本进度文件。已完成打包和元数据修复；未在实际 SideStore/Apple 账号执行签名，错误是否消除须用户安装 Build 12 确认，不虚报安装成功。保存后停止。

## 目标与核心需求
- 将 Go Music DL 改为高品质原生 iOS 音乐客户端“澄音 / MusicDL”，面向 iPhone 17 Pro Max / iOS 27。
- 原生 SwiftUI TabView、NavigationStack、Sheet 与 iOS 26+ Liquid Glass；主要界面不使用 WebView。
- 当前恢复全部 13 个原有在线来源，另保留本地文件、WebDAV、AI API、设置；能力和可用性以专项报告的实际测试与限制为准。最新全来源指令替代历史六来源限制。
- 原生后台音频、锁屏/控制中心/耳机控制；真机测试与模拟器测试分开报告，禁止虚报。

## 当前架构
- Go 音乐核心与 SQLite 保持原有结构；新 `MusicDLRequest` C ABI 提供原生 JSON 功能接口。
- 前台管理功能可复用固定 loopback JSON 路由；音频解析经 C ABI，音频由原生文件缓存与 AVQueuePlayer 播放，不依赖网页 JavaScript 或本机 HTTP 音频流。
- Swift `NativeClient` 负责结构化数据与错误；`AudioEngine` 是唯一播放状态所有者；`AppModel` 连接原生 UI 与 AI SSE 控制。
- 原生设计使用独立品牌、系统字体、深浅色与安全区域。REA Windows 仅用于可用的静态包检查；没有观察 iPhone Apple Music 内部源码/动态界面。

## 分支与已保留版本
- 当前开发分支：`codex/source-recovery-stability`；原授权分支 `codex/six-sources-official-auth` 保留；原 `codex/ios-native-redesign` 保持原提交，前阶段版本基于 `9b18983`。
- 上阶段通过的 Build 5：源提交 `a7c784c8ffd378418bdde33f65da746e71b58ee2`。
- IPA：`../outputs/ios-build5/music-dl-ios-native-unsigned.ipa`。
- SHA256：`72f1dc69ef597258df90f3a526961c01b6c6e7a1d64ea8046ef6069a8f8781c7`。
- 上阶段工作流：https://github.com/yann359/go-music-dl/actions/runs/42483202980 。

## 已完成与代理成果
- 上阶段原生缓存播放、音频会话、系统远程控制、中断/路由处理与后台声明。
- REA doctor/capabilities 已运行，结果摘要 `docs/rea-ios-readiness.json`；原 Build 5 IPA 已通过 REA 静态包检查。
- `docs/ios-native-design.md`：公开参考、证据边界、字体间距/交互/动效/状态规范。
- `docs/ios-native-feature-matrix.md`：历史迁移清单；当前全部来源范围以 `docs/ios-source-recovery-stability.md` 为准。
- 后端代理：`internal/web/native_client*.go`、`ios/bridge/main.go`、`Bridge.h`。
- 客户端代理：`NativeClient.swift`、`NativeClientTests.swift`，包含显式 UI 测试样例模式。
- 主代理：`DesignSystem.swift`、`NativeAppModel.swift`、`NativeRoot.swift`、`NativeScreens.swift`，以及 AudioEngine 可观察状态/队列操作。

## 上次中断点（历史恢复记录，最终结果见下节）
- 已补齐全屏/迷你播放器、LRC 跟随与点击跳转、队列排序/移除/清空、系统输出选择器。
- 已补齐我的、Cookie/二维码、完整设置/WebDAV、音源浏览/分类/榜单和用户平台歌单。
- 原管理界面 WebView 已从 iOS UI 目标中移除；不改动原网页/Android 页面。
- CI 已改为 macos-26，并校验 SDK >=26；加入原生页面深浅色截图和无 WebView 断言。
- 第二轮云端运行 `42537993412`：Go 检查、原生 release 编译、模拟器单元测试通过；UI 自动化及测试报告上传失败，最终日志归档未结束，具体原因待查。不能记为 UI 验收通过。
- 补充专辑/原始链接/VIP元数据保留、失败与空结果区分、当前换源保留队列/进度、本地及锁屏封面；等待最终 macOS 重验。
- 已将 UI 检查设备限制为 iOS 26+，优先 iPhone 17 Pro Max；使用模拟器 ad-hoc 签名；播放器断言改为可见的收起按钮，避免依赖 SwiftUI 容器的可访问性类型。
- 已取得第二轮日志：Xcode 26.6；13 项原生单元测试通过；两项 UI 测试均找不到迷你播放器的可访问性标识；报告上传为 ArtifactService/CreateArtifact 请求超时（不是已证实的存储配额问题）。将展开区域改为有明确标签的原生 Button，并移除外层重复标识，等待重验。

## 后台音频阶段测试与已知限制（保留记录）
- 该阶段成功运行：[42540853672](https://github.com/yann359/go-music-dl/actions/runs/42540853672)，代码 `97b36c9c39562dfb9376b2497e98d09763ab3744`。最新名称修复构建见上节。
- 环境：macOS / Xcode 26.6，iPhone 17 Pro Max / iOS 26.5 模拟器；不是用户的 iOS 27 真机。
- 原生测试 **17/17 通过**：AudioEngine 6、歌词解析 3、NativeClient 7、真实 Go 桥接集成 1（含 SQLite 收藏增删、原生 SSE 与音量往返）。
- Go 回归与 Node 桥接 **6/6** 通过。Windows 上 `go test ./internal/web ./internal/appshell ./core ./internal/spotify ./internal/cli ./cmd/music-dl` 同样通过。
- 收窄任务前已启动的同一次构建另有原生深浅色 UI 自动化 **2/2 通过**；此后未开展新 UI 工作，也未做人工截图验收。
- 历史失败：`42537618882` 的 SQLite 异步写/关闭竞争已修复并通过后续 macOS 回归；`42539762359` 的换源进度变零已修复，同一进度断言在最新运行通过；旧 UI 标识与上传超时也已在最新运行通过。
- 模拟器音频测试使用短合成 WAV：三段推进不等于三首真实歌曲完整播放；中断/路由用例是通知注入，不等于真实来电/AirPods。
- Windows 无 Xcode/SwiftUI 编译器；iOS 编译、模拟器与截图必须在 macOS Actions 执行。
- 无 iPhone 连接；桌面/锁屏 30 分钟、三首完整真实歌曲、系统锁屏/控制中心实际按钮、真实来电及 AirPods 测试均未执行。不能据自动测试宣称全部真机中断已修复。
- 音源可达性、账号权限、格式解码、首曲缓存延迟仍需实测；不绕过版权或付费授权。

## 后台音频阶段修改与留存安装包
- 代码阶段提交：`97b36c9`，修改 `ios/MusicDL/AudioEngine.swift`、`NativeAppModel.swift`、`ios/Tests/AudioEngineTests.swift`、`NativeBridgeIntegrationTests.swift`，修复就绪/跳转竞争和状态上报顺序；既有 UI 页面未修改。
- 详细改动、证据边界及真机步骤：`docs/ios-background-audio-stage.md`。
- 新 IPA：`../outputs/ios-audio-stage/music-dl-ios-native-unsigned.ipa`，Build **11**，arm64，包内声明后台 audio、无 `_CodeSignature` 目录，适合 SideStore 重签。
- IPA SHA256：`c2fbcaf6f09d34484dc6f889635e5cb975e816a9ce768c4faddbeda6fefd9303`；已核对构建附带校验值、对应源码提交和 Bundle ID。
- [云端安装包/源码/许可](https://github.com/yann359/go-music-dl/actions/runs/42540853672/artifacts/13641678130)，有效期至 2026-12-09。解压 artifact ZIP 后导入其中的 IPA。
- 已再次核对旧 Build 5 SHA256 未变化；未覆盖旧 IPA。

## 上一后台音频阶段与停止条件（保留记录）
- 本轮仅主智能体，聚焦后台音频与相关回归；不再开始 UI 或其他功能阶段，不重复全仓扫描/架构分析。
- 恢复时工作树干净；已有修改均保存在独立分支。保留前两阶段代码、既有 UI 与旧 IPA。
- 当前代码提交 `97b36c9`：修复原生换源/恢复的就绪与进度竞争，以及播放状态上报顺序；不改 UI 页面。
- 已确认现有后台实现：`AudioEngine.swift` 使用 `.playback` / `.longFormAudio`，`Info.plist` 声明 `UIBackgroundModes(audio)`，AVQueuePlayer 读缓存文件，MPRemoteCommandCenter 绑定系统控制。没有退后台即暂停的 SwiftUI 生命周期处理。
- macOS 验证和包核验已完成，结果如上；使用收窄指令前已启动的构建，没有为文档更新重新构建。
- 本阶段结果与恢复点保存后停止；不自动开始 UI、附加功能迁移或下一轮构建。后续先按记录执行真机验收，由实际结果决定是否需要修复。
- 必须保留的外部验收：iPhone 桌面/锁屏 30 分钟、三首完整真实歌曲、控制中心/锁屏按钮、AirPods、真实来电。Windows/macOS 模拟器测试不能替代这些结果。
