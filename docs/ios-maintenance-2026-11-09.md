# CHENGYIN / MusicDL 四项维护修复

日期：2026-11-09（北京时间）。本轮仅维护问题，不修改品牌、色彩、导航项目、播放器音频引擎或用户数据库结构。

## 恢复到的实际工程

- 实际 Git 仓库是 `go-music-dl`，不是外层目录；开始时仓库工作树干净。分支 `codex/ios-native-redesign`，基线 `69e94bb`，此前业务提交为 `35bfc86`、`97b36c9`。外层 `.tools/`、`outputs/` 和既有 IPA 全部保留。
- SwiftUI / NavigationStack / TabView，iOS 18 最低目标，iOS 26+ Liquid Glass；Go 1.26.1 本地工具链，Gin、SQLite/GORM、固定版本 music-lib。
- `ios/MusicDL/AudioEngine.swift` 独占 AVQueuePlayer、音频缓存、后台及系统播放状态；本轮未改此文件。
- `NativeClient.swift` 经 `MusicDLRequest` C ABI 调用 `internal/web/native_client.go`；`NativeRoot.swift` 挂载系统底部附件；`PlayerViews.swift` 展示歌词。
- 本地运行后端：`go run ./cmd/music-dl web`。iOS 打包：macOS 上执行 `bash ios/scripts/package.sh`；已有 `.github/workflows/ios-native.yml` 负责原生编译和 XCTest / UI 测试。本轮没有提交、推送、触发远端工作流或生成新 IPA。

## 四个根因与修复

### 1. 未播放时的白色胶囊

原先无条件调用 `tabViewBottomAccessory`，只在它的内容闭包中检查 `currentSong`；内容为空时系统仍可以保留附件容器。没有发现第二套底部导航，也没有用于首页的隐藏 Home Indicator 代码。

改用 `tabViewBottomAccessory(isEnabled: audio.currentSong != nil)`，控制附件本身的存在；暂停时歌曲仍存在，所以播放器保留，清空队列后隐藏。官方接口从 iOS 26.1 引入，按真实可用性设置分支；更早系统使用条件 Safe Area inset。系统导航、Home Indicator、完整播放器交互保留。

官方接口与可用性证据：<https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:)>

### 2. 首页等待所有来源

“正在连接音乐来源…”对应的是推荐及榜单内容加载，不是源目录握手。原推荐在 Go 内已并行，但聚合结果必须等待所有来源；Swift 再串行请求网易榜单。library 的通用 HTTP 客户端为两分钟超时，单个失败来源会拖延整批显示；页面局部状态丢失时会重发。

- 首页仍使用原来的网易/QQ 推荐与网易榜单，拆成三个独立请求，最多三个并行；每个返回后立即更新可用内容。
- Go 统一限制同时执行数为 3，调用方等待上限 6 秒，并按操作、来源和凭证指纹合并进行中的同一请求。没有新增伪造探测或连接成功状态。
- 原库没有 context 参数：超时后不能强行杀掉它的网络操作。保留其并发槽和合并记录直到实际结束（原库最长两分钟），防止连续重试堆积后台请求。单个慢源不占用全部槽；这项依赖限制需要后续用原库正式支持的取消接口才能消除，没有改全局下载超时。
- 缓存真实成功的来源内容和成功时间。15 分钟内复用；15 分钟至 24 小时先展示再刷新；超过 24 小时不展示过期缓存。失败不会替换成功缓存，也不会延长成功时间。凭证变动清空发现缓存，正在完成的旧账户响应不能重新写入。
- 单项失败独立重试；网络恢复以及回到前台时重连失败项。刷新失败保留仍在有效期内的内容。
- DEBUG 启动前打开 Go 网络日志：本地服务启动、来源执行、排队/调用截止、DNS、TCP、TLS、连接复用、首字节、响应体、Swift 请求总耗时以及缓存命中。日志不主动打印 Cookie 或请求正文；详细错误仅开发日志可见。

### 3. 歌词失败、EOF 与错误泄露

原生歌词路径只调用一次 `GetLyricFunc`，原库咪咕先取 `lrcUrl/lyricUrl`，再 `io.ReadAll` 下载；网络中断/EOF 直接上抛，无缓存、重试和分类。Swift 显示完整错误字符串。歌词状态与音频是独立的，但原界面没有重试入口。

- 仅为原生咪咕歌词补充可取消的同端点 HTTP 请求；仍用已有 Cookie、Referer 和资源解析规则。单次尝试最多 4 秒，最多 3 次，200/400 ms 指数退避；总歌词处理上限 16 秒（含备用来源）。每次重试重新取得 URL，不长期缓存签名链接。
- 丢弃流中断的部分正文；核验 Content-Length、2 MB 上限、UTF-8 / BOM UTF-16 / 声明的 GBK/GB18030 编码；拒绝 HTML、JSON 错误页和只有头标签的空歌词。
- 区分 missing、network、server、authorization、format、unavailable，仅网络和可恢复服务器错误自动重试。其他旧音源仍复用原库，通过有上限的独立歌词请求池控制等待和重复请求。
- 优先读取 source/id/歌名/歌手/专辑/时长匹配的本机缓存，最多 256 首、30 天；不会缓存部分正文或失败结果。
- 失败时只从已有网易/QQ 搜索能力中查找。要求规范化后歌名、歌手、专辑完全一致，且双方时长已知、差不超过 2 秒；不剥除 Live/翻唱等版本信息，未知或不确定时拒绝替代。该规则偏保守，宁可没有歌词，也不采用相似版本。
- 界面只显示简洁分类提示及“重试歌词”；确实无资源显示“暂无歌词”。取消的旧歌曲任务不覆盖新歌曲歌词。没有修改播放、暂停、切歌、seek 或播放缓存。

### 4. 作曲/编曲重复

比“原始文本含重复署名”更直接的问题是：music-lib 的 `ConvertVerbatimLRC` 在文字内部/末尾也输出方括号时间标记。原 Swift 解析器将一行的每个时间标记都扩展为整句副本。原文/音译/译文轨合并还可能保留相同署名；UI `ForEach` 只是显示已经重复的解析数组。原生 `nativeLyric` 本身没有把不同来源歌词拼接。

- 只有正文之前的连续时间标记才代表整句的多次出现；文字内部和末尾的标记作为逐字边界处理，不再复制整句。
- 对连续署名段规范化角色、空白和冒号，相同角色+相同人员只保留首条；不同人员、不同角色保留。遇到正文重置去重段，保护后续正常内容。
- 保留不同时间的相同歌词、多时间戳副歌、同时间和声/译文及稳定顺序；首时间、offset、最终 id 对应保持明确。
- 解析器移入只依赖 Foundation 的 `Lyrics.swift`，最终 `LyricsPane.lines` 仍直接使用该解析结果，无视觉隐藏。增加解析数据断言和最终 UI 署名数量/重复副歌数量断言。
- 用户没有提供确切歌曲 ID 和原始歌词，本轮不能证明具体歌曲上游本身是否也有重复；已定位并覆盖现有解析器确定会重复展开的格式路径。

## 修改文件

| 文件 | 用途 |
| --- | --- |
| `ios/MusicDL/NativeRoot.swift` | 按歌曲状态启停系统底部附件 |
| `ios/MusicDL/NativeAppModel.swift` | DEBUG 启动耗时；显式空队列 UI 测试模式 |
| `ios/MusicDL/NativeClient.swift` | 来源逐项加载、缓存、恢复重试及歌词错误清理 |
| `ios/MusicDL/NativeScreens.swift` | 首页接收逐项结果、单项重试 |
| `ios/MusicDL/PlayerViews.swift` | 歌词错误/重试、空歌词、取消后状态保护 |
| `ios/MusicDL/Lyrics.swift` | 逐字时间解析、元信息规范化与数据去重 |
| `core/migu_lyrics.go` | 咪咕有截止时间的请求、完整读取、解码与错误分类 |
| `internal/web/native_requests.go` | 有界请求、合并请求、开发网络耗时日志 |
| `internal/web/native_lyrics.go` | 歌词缓存、有限重试、严格备用匹配 |
| `internal/web/native_client.go` | 将原生推荐、榜单及歌词接入上述处理 |
| `core/migu_lyrics_test.go` | 流中断、URL 重取、状态、长度及编码 |
| `internal/web/native_requests_test.go` | 截止/请求合并/部分成功与受控和真实网络计时 |
| `internal/web/native_lyrics_test.go` | 重试恢复、失败降级、缓存与准确匹配 |
| `ios/Tests/LyricsTests.swift` | 解析后数据：署名、逐字时间、多时间副歌/和声 |
| `ios/Tests/NativeClientTests.swift` | 逐项显示、独立重试、持久缓存、过期/账号变化、错误提示 |
| `ios/UITests/NativeVisualTests.swift` | 空播放器/切页/播放暂停/后台返回/清空及最终歌词数量 |
| `PROJECT_STATUS.md`、本文 | 根因、验证、剩余风险和恢复位置 |

## 已测性能（不能当作 iPhone 性能）

| 场景 | 原顺序 | 并行路径 | 测量边界 |
| --- | --- | --- | --- |
| Windows 真实公开来源首次内容完成 | 335.561 ms | 81.125 ms | 同一进程先旧后新，DNS/TLS/连接温度不完全相同，仅单次观测 |
| Windows 真实公开来源全部完成 | 428.102 ms | 155.880 ms | 两次网易/QQ 推荐/网易榜单数量均为 30/12/65，均无错误 |
| 受控弱源首次内容完成 | 220.180 ms | 25.510 ms | 25/220/40 ms 延迟的确定性测试模型，不是真实移动弱网 |
| 受控弱源全部完成 | 260.665 ms | 220.411 ms | 比较聚合后串行榜单与独立并行交付 |
| iPhone 冷启动/热启动/真实弱网 | 未测 | 未测 | 无 iPhone/Xcode；不得用上述后端数据代替 |

可复现真实网络计时：`MUSICDL_LIVE_TIMING=1 go test -count=1 -v ./internal/web -run '^TestNativeDiscoveryLiveTiming$' -timeout 6m`。普通回归默认跳过这项外部网络测试。真实音源速度会随时间、网络和账号变化。

## 验证与剩余限制

- Windows Go 原有相关包回归：338 个测试通过、11 个按环境/显式开关跳过；六个包全部通过。原有跳过项和外部网络测试不是通过项。
- Node 原生桥接测试 6/6 通过。`go vet` 六包通过；Windows `go build ./cmd/music-dl` 通过。
- 仓库使用的 golangci-lint v2.12.2 已实际运行：增量检查（`--new-from-rev=HEAD`）0 issues；全量检查未通过，报告 84 个存量问题（errcheck 54 / staticcheck 26 / unused 3 / ineffassign 1）。本次 Go 新文件无报告；已修改 `native_client.go` 的唯一报告在未改的旧搜索代码。没有修改无关存量问题。
- Go `-race` 不能运行：当前 `CGO_ENABLED=0`，无 GCC/Clang。不是通过。
- 新增 Swift 单元回归 10 项、UI 回归 2 项已经编写，但 **未编译/执行**；本轮所有 XCTest、SwiftUI 编译、iOS Release 打包和截图人工审查均未执行。旧 Build 12 的成功结果不能替代新代码验证。
- 本地也无可运行的 WSL：已登记的 Ubuntu 虚拟磁盘路径缺失；没有修复或重装系统环境。
- 测试原始证据位于外层 `outputs/ios-maintenance-go-tests.jsonl`、`outputs/ios-maintenance-lint.json`、`outputs/ios-maintenance-lint.txt`；Windows 构建验证产物为 `outputs/musicdl-maintenance-check.exe`，不是 iOS 安装包。

## 下一步（仍属四项验收）

1. 在现有 macOS/Xcode 26.1+ SDK 工作流编译并执行 MusicDL 单元测试和 MusicDLVisual UI 测试，审查空队列深浅色截图及歌词最终数据。
2. 成功打包后生成新构建号 IPA，经 SideStore 重签安装；当前保留的 Build 12 不含本轮修复。
3. iPhone 测试冷启动/热启动/实际弱网、飞行模式恢复；记录 DEBUG 各阶段和首批内容耗时。分别检查无歌曲、首次播放、暂停、切页、后台返回、清空队列和 Home Indicator。
4. 使用用户实际出现 EOF/重复的歌曲及 ID 验证，并覆盖普通 LRC、逐字歌词、多版本曲目和无歌词歌曲；验收搜索、多源、收藏、歌单以及切歌和同步高亮。
