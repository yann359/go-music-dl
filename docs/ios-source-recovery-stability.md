# CHENGYIN / MusicDL 来源恢复与稳定性专项

> 本文保留 `52acc6e` 阶段的历史测试范围；后续已完成真实 iOS Release 打包，最新 Build 14、48/48 单元与 6/6 UI 结果见 [正式打包记录](ios-ipa-release-2026-11-09.md)。

日期：2026-11-09（北京时间）。基线 `3bf0333`，本地工作分支 `codex/source-recovery-stability`。这是现有项目修复，不是新项目或 UI 重做。**Windows 验证已完成；iOS 编译、模拟器与真机尚未验证，没有新 IPA。**

## 1. 上下文、保护与来源恢复

已读取 PROJECT_STATUS、Git 历史及实际 SwiftUI / Go / SQLite / 音频代码。仓库开始时干净；在独立分支修改，旧分支、历史授权提交、旧安装包和用户存储均保留。外层目录自身没有 Git 提交，实际工程在 `go-music-dl/`，本次 Git 操作只针对工程仓库。

从 `ee4746a → 3bf0333` 找到七来源移除差异，按文件和函数合并恢复适配器及播放/下载/歌词/CLI/链接识别/二维码和兼容账号入口；未整仓回滚。保留当前安全的 URL 主机识别、Apple Cookie 隔离、Spotify 官方授权，以及之前的推荐/歌词修复。恢复咪咕专用歌词请求时复用当前通用错误与解码模块，避免重复定义。

注册来源为：网易云、Apple Music、QQ、汽水、酷狗、Spotify、酷我、咪咕、5sing、Jamendo (CC)、JOOX、千千、Bilibili；本地音乐独立保留。历史列表与当前依赖中未发现额外遗漏的已注册来源。网页、CLI 与原生共用核心来源目录；未知来源旧记录仍保留并提示，不通过其他来源伪装成原曲。

## 2. 真实公开接口检查

本机 Windows、公开网络、查询 `piano`，未加载真实账号凭证。以下是一次实际抽样，不是持续可用性保证，歌曲数量可能受上游和过滤设置变化。搜索与账号授权分开；需要授权的个人歌单没有绕过验证。

| 来源 | 歌曲搜索返回 | 歌单搜索返回 | 首个歌单详情抽样 |
|---|---:|---:|---|
| 网易云 | 6 | 10 | 65 首，435.489 ms |
| QQ | 2 | 20 | 255 首，355.047 ms |
| 酷狗 | 10 | 10 | 58 首，404.530 ms |
| 酷我 | 3 | 10 | 86 首，199.373 ms |
| 咪咕 | 20 | 20 | 112 首，1153.089 ms |
| 汽水 | 20 | 19 | 39 首，1114.256 ms |
| Apple Music | 未成功 | 未成功 | 旧兼容目录报 `index.js URI not found`；MusicKit 授权代码保留 |
| Spotify | 未配置 | 未配置 | 缺少授权访问令牌；保留用户之前的待配置选择 |
| 5sing | 10 | 15 | 上游详情返回空列表/无可读信息；显示失败，可重试 |
| Jamendo (CC) | 20 | 0 | 本次未获得可抽样歌单，不代表平台没有歌单 |
| JOOX | 11 | 4 | 50 首，6260.455 ms |
| 千千 | 3 | 0 | 本次未获得可抽样歌单 |
| Bilibili | 17 | 10 | 999 首，211.610 ms |

原始结果：`../outputs/stability-public-sources.txt`。未测试所有曲目播放、受限地区、会员能力或真实账号歌单；不能将“已注册/搜索有结果”等同于“全部功能可用”。5sing 报错来自既有适配器收到空的歌单元数据；不绕过私有/失效歌单访问。Apple 兼容目录问题尚未解决，不能以 MusicKit 权限成功代替目录成功。

## 3. 本地服务故障与修复

实际调用链为 Swift → C ABI → iPhone 进程内 Go → 一部分操作再访问固定 `http://127.0.0.1:37777/music`。错误原文来自 `nativePerformJSON` 的 HTTP 传输失败分支。**这里的 127.0.0.1 是 iPhone 自身，不是 Windows 局域网地址。** 原架构无需电脑保持开机；无需开公网端口、服务器或付费 API。

源码中确定的问题：

- 本可在同一进程完成的收藏、本地文件、下载等操作，额外依赖 TCP 监听、连接复用与固定端口。
- MusicDLStart 的 sync.Once 同时记住首次等待失败；之后重试仍返回原失败。
- 配置数据库的 sync.Once 也会保留首次打开失败，且空连接的 CloseConfigDB 原先不重置这个结果。回归测试真实触发了这一层问题。
- AI SSE 原先无限固定间隔重连；前台没有显式恢复控制连接。

已实施：

- 原生数据操作直接调用已初始化的进程内 HTTP handler，复用同一业务路由、来源白名单、写入守卫和 SQLite；返回缓冲限制 16 MB。并非隐藏报错或返回假成功。
- SQLite、队列和路由的进程生命周期独立于可选 TCP 监听；可选 AI 监听只绑定 127.0.0.1，最多三次尝试，不暴露公网。
- C ABI 只对成功的沙盒路径初始化作一次保护；等待超时不会毒化服务。初始化失败清理句柄，之后可重试；配置数据库失败重置同时修复。
- Swift LocalService 统一 stopped / starting / available / disconnected / reconnecting / unavailable；启动请求合并，最多三次退避，前台重检。
- AI 控制流有限退避、前台重新建立连接，代次保护避免旧任务清空新任务；AI 连接故障不停止本地音频。
- 相同当前提示去重；详细时序诊断在 DEBUG 开启。

已在独立子进程中证明：先制造数据库路径失败，再恢复路径，同时占用回环监听端口，仍能完成真实初始化和 SQLite 收藏增读。**未取得用户那次 iPhone 故障的现场日志，不能断言当时具体是端口、系统挂起还是数据库保护触发；这里列的是已证实的代码缺陷与回归覆盖。**

## 4. 后台返回播放问题与状态管理

AudioEngine 唯一拥有 AVQueuePlayer，播放读沙盒缓存文件，并非 JS/WebView 音频。原有 `.playback` / `.longFormAudio`、后台 audio 声明与 MPRemoteCommandCenter 均保留。

确定的代码缺陷是：`play()` 即便 setActive 成功，仍被残留的 interrupted 标记拦住；恢复前台仅 publish；失败播放器/失败当前项没有在显式重试时重建。系统挂起可能产生没有对应 ended 的中断序列，不能把最后一条通知当成永久事实。另发现旧队列的异步缓存清理可能晚于新队列准备，已增加代次保护。

现在用户点击播放会激活会话，成功后清除残留中断、检查失败实例及缓存文件存在性，必要时重建；保留当前曲目、位置、队列、播放模式与速率。8 秒检查真实 timeControlStatus 和进度是否推进，最多自动重建一次，再失败给出可理解提示，点击播放即可重试。HTTP 401/403/404/410 的音频地址只重新解析一次。暂停、耳机断开与前台单纯打开 App 不会自动把暂停歌曲播放起来；中断自动恢复仍尊重用户暂停与系统建议。

新增 idle / preparing / ready / playing / paused / buffering / interrupted / recovering / error 状态；playing 始终来自 AVPlayer 真值，不为了按钮伪造。过时的换源结果不会覆盖新曲目/队列；旧队列清理不能驱逐新代次音频，且不会删除用户本地音乐文件。没有增加后台保活任务或静音循环。

Apple 官方依据：[中断处理](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)、[系统挂起相关中断通知](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification)、[媒体服务重置](https://developer.apple.com/library/archive/qa/qa1749/_index.html)。这些说明支持恢复设计，不能替代真机观察。

## 5. 曲目加载链路与性能

原详情链路直接等待适配器，不限制调用等待、没有详情缓存或合并；上游 music-lib HTTP 超时可达两分钟。共享队列若被慢来源占满，其他来源也会等。Swift 详情任务没有页面代次校验，读到曲目也可能被后续旧任务和 loading 状态覆盖。

已实施：

- 每个注册来源独立两个调用槽；调用方 8 秒截止。底层未返回时仍持有槽及相同请求合并项，防止重试无限堆积。
- 搜索最多三来源并发，逐来源发布结果；平台推荐、榜单和分类独立并发、完成即显示。
- 专辑、歌单、榜单详情缓存：15 分钟复用，24 小时失效；至多 40 项及约 8 MB。先显示有效旧数据，再刷新过期内容。登录凭证变化清理缓存，不改变用户数据库。
- 本地可编辑收藏及 Spotify 授权详情实时读取，避免错误复用用户私有数据；部分响应可显示但不存成完整成功缓存。
- 明确空/部分/成功/失败状态；UUID 与任务取消隔离旧响应，失败保留旧缓存并提供重试。有歌曲时不再挂着大面积“正在读取曲目”。
- 账号歌单切换隔离响应；页码仅在成功后前进；详情继续使用原 LazyVStack，不重做 UI。
- DEBUG 记录操作总耗时、上游 DNS/连接/TLS/首字节/响应体/适配器耗时、详情解码、缓存命中、首次行 onAppear、完成/失败。Go 内部适配器的网络与 JSON 解析仍封装在库方法中，不能声称测得独立的每段耗时。

当前原生 UI 没有独立“歌手详情”接口；歌手匹配属于 search/exact_artist。已纳入搜索截止和隔离，但无法据此宣称复现了用户旧安装包里所有歌手页面问题。不得新增假接口或伪造首屏数据。

### 实际优化前后对比

使用真实网易云热歌榜，旧直接适配器路径与新详情路径交叉顺序运行，两者均返回 200 首：

| 次序 | 旧直接路径 | 新有界路径 |
|---|---:|---:|
| 第一轮：旧 → 新 | 526.0901 ms | 478.7836 ms |
| 第二轮：新 → 旧 | 456.6591 ms | 481.3941 ms |

原始记录：`../outputs/stability-detail-live-timing.txt`。这是 Windows/Go 的两轮观察，包含网络波动和连接复用，**没有一致的网络加速证据**，不计算提升百分比，也不把它当作 iPhone 首屏/Swift 缓存结果。六个同时读取同一详情的受控测试只调用上游一次，约 53 ms；这是去重证据，不能解释成真实网络快六倍。Swift 缓存和实际首屏收益仍待 iOS 运行。

## 6. REA 与许可证

遵循 REA 技能检查当前会话：服务版本 6.4.0 可连接，未打开目标，留存证据数量为 0。已有仓库的 readiness 文件也说明 Windows 不具备 iPhone/macOS 动态音频观察能力。没有可引用的第三方播放器实现，所以本轮没有宣称参考 Apple Music 私有源码、没有拷贝第三方 App/资源/UI；采用当前项目源码和官方生命周期说明独立实现。

工程及现有 music-lib LICENSE 均为 GNU AGPLv3；恢复现有依赖不引入新商业 API、付费服务或新的未知许可证。既有 LICENSE / ios/NOTICE.md 和源码随 IPA 提供的发布脚本保留。

## 7. 自动验证与构建

- Go 六包：**353 通过，13 跳过，0 失败**。覆盖来源工厂、单源失败、真实初始化失败后重试、TCP 不可用仍可本地读写、详情空/部分/完整/超时、重复请求与跨来源隔离、历史数据保留及官方授权原有测试。
- Node 原生桥接：**6/6**；app.js 语法检查通过。
- go vet 六包通过，Windows 后端构建通过，产物 `../outputs/musicdl-source-stability-check.exe`。
- 增量 golangci-lint：**0 issues**。没有宣称清理全仓历史 lint 问题。
- 13 个常规跳过包括需要真实账号/显式网络开关的历史测试及本轮两项网络诊断；公开来源与热歌榜两项已分别手动开启并执行，不能因此视为所有跳过通过。
- 原生单元测试 48 项、UI 测试 5 项现有源码；新增缓存过期/合并/授权代次隔离、服务三次重试、恢复来源数据兼容、渐进搜索、无 ended 的中断后显式播放及旧队列清理保护。
- **没有执行 Swift 编译、XCTest/UI、Go race 或 iPhone 真机。** Windows 无 Xcode/iOS SDK、Swift 编译器及可用 CGO race 工具链；不得把这些待验收项写成通过。

原始证据：`../outputs/stability-go-tests.jsonl`、`stability-incremental-lint.txt`、`stability-public-sources.txt`、`stability-detail-live-timing.txt`。原有 macOS 工作流 `.github/workflows/ios-native.yml` 保留，未推送或触发远程构建。

## 8. 下一步构建和 iPhone 验收

先在 macOS 使用现有流程执行 `bash ios/scripts/package.sh`、`bash ios/scripts/build-go.sh simulator`，再运行 `MusicDL` 和 `MusicDLVisual` scheme 的测试。以新提交生成且通过测试的 IPA 签名安装；旧 Build 12 不包含本轮代码。保留 Bundle ID 与应用数据，不先卸载应用。

用同一首有权限播放的歌曲，每项都核对“真实声音、进度推进、按钮状态、队列与进度保留”，失败记录时间、来源、歌曲、当前状态和网络；DEBUG 收集 native-detail/native-timing 日志，勿分享令牌或完整签名 URL。

1. 正常播放 → 暂停 → 桌面 → 立即返回 → 播放；连续重复 10 次。
2. 暂停后分别后台 2、5、15 分钟，再点击播放；再做锁屏 5、30 分钟。暂停状态不应自行播放。
3. 播放中桌面/锁屏至少 30 分钟，验证三首完整真实歌曲连续切换。
4. 暂停后 Wi-Fi 切蜂窝再恢复；另做飞行模式短断网 → 恢复网络 → 点击播放。已缓存曲目应可继续，本地歌单仍可读写。
5. AirPods/蓝牙连接、断开：拔出时暂停；明确点击播放后恢复；不意外外放。
6. 来电、Siri 或其他 App 音频中断；结束后按系统建议恢复。中断期间手动暂停，应保持暂停。
7. 快速点击播放/暂停 10 次、切歌/返回，验证仅有一个有效队列且最终状态正确。
8. 锁屏/控制中心/耳机按钮的播放、暂停、上一首、下一首与进度拖动；核对实际声音。
9. 测试系统“重置媒体服务”（具备开发者设置时），再显式点击播放，确认重建与进度；没有该设置就标未测。
10. 分别打开网易云热歌榜、专辑及实际出现问题的歌手入口，记录冷/热首次行、完整数据、缓存命中；返回重进不应无限加载。切换两个页面或来源时，不接受旧响应覆盖。
11. 逐来源搜索/公开歌单/账号歌单按声明能力验收；Apple 用实际签名 MusicKit 配置验证；Spotify 继续待配置，除非用户以后改变选择。
12. 核对原有收藏、历史、歌单、授权、歌词同步、迷你播放器和 Liquid Glass 布局（深/浅色、iPhone 安全区）均保留。

尚未解决：Apple 旧目录解析、5sing 个别无可读详情歌单；未配置的 Spotify 官方服务；非 context 上游库的后台调用仍可能运行到库自身超时，但每源最多两个槽、调用方有界。iPhone 概率故障的现场触发和缓存首屏收益仍需以上验收。没有付费部署或公网暴露需要用户承担。

## 9. 源码变更清单与回滚

- `PROJECT_STATUS.md`
- `README.md`
- `cmd/music-dl/root.go`
- `core/config_store.go`
- `core/config_store_test.go`
- `core/download.go`
- `core/download_test.go`
- `core/migu_lyrics.go`
- `core/migu_lyrics_test.go`
- `core/player.go`
- `core/player_test.go`
- `core/service.go`
- `core/service_album_test.go`
- `core/service_categories_test.go`
- `core/service_toplists_test.go`
- `core/source_registry_test.go`
- `docs/ios-source-recovery-stability.md`
- `internal/cli/ui.go`
- `internal/web/native_accounts.go`
- `internal/web/native_client.go`
- `internal/web/native_client_routes.go`
- `internal/web/native_lyrics.go`
- `internal/web/native_service.go`
- `internal/web/native_source_calls.go`
- `internal/web/native_stability_test.go`
- `internal/web/server.go`
- `internal/web/templates/static/js/app.js`
- `ios/MusicDL/AccountViews.swift`
- `ios/MusicDL/AudioEngine.swift`
- `ios/MusicDL/AudioModel.swift`
- `ios/MusicDL/DetailStore.swift`
- `ios/MusicDL/LocalService.swift`
- `ios/MusicDL/MusicAccounts.swift`
- `ios/MusicDL/NativeAppModel.swift`
- `ios/MusicDL/NativeClient.swift`
- `ios/MusicDL/NativeRoot.swift`
- `ios/MusicDL/NativeScreens.swift`
- `ios/MusicDL/SourceViews.swift`
- `ios/Tests/AudioEngineTests.swift`
- `ios/Tests/NativeBridgeIntegrationTests.swift`
- `ios/Tests/StabilityTests.swift`
- `ios/UITests/NativeVisualTests.swift`
- `ios/bridge/main.go`

所有改动在当前分支保存本地 Git 记录。回滚基线为 `3bf0333`，原 `codex/six-sources-official-auth` 分支保持原样；需回看旧代码时先保存后续工作再切换分支，不使用 hard reset、不删除数据。没有改变 SQLite 表、收藏/历史标识或授权存储格式；新增详情缓存为可丢弃的独立文件。
