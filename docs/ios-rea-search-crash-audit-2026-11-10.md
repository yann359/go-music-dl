# 澄音 MusicDL：REA 搜索与换源故障审计

本轮从干净的 `8eac5d4` 建立 `codex/rea-search-crash-audit`，没有覆盖未提交改动。重新 fetch 的上游为 `c445dddb66eec1b34c04fb16a72577f1115285c7`。此前 Build20 的验收仅作线索，本报告区分本轮复现、真实接口、模拟器和真机。

## 已确认根因与修复

| 问题 | 具体位置和触发路径 | 实际证据 | 修复 |
|---|---|---|---|
| 自动换源的子协程 panic 会终止进程 | `NativePlaybackAsset(fallback:true)` / `NativeClientRequest(switch_source)` → `findBestSwitchSong` → `searchSwitchSourceCandidates.callSearch`；`validateSwitchCandidates` 的验证 worker 同样缺保护 | `outputs/rea-panic-before.log`：搜索及验证分别触发受控 panic，子进程均 exit status 2，栈指向旧 `music.go:1896` / `1990`；外层 recover 无法跨协程捕获 | 搜索、快速验证和并行验证均复用每来源有界调用池，在执行适配器的同一协程恢复并记录异常；保留其他候选，超时后不提前释放仍在工作的槽 |
| 原生解析边界未保护同步 panic | Swift `GoBridge.resolve` → C `MusicDLResolve` → `NativePlaybackAsset` → `core.PreparePlaybackSource` | 新回归注入真实 panic，验证返回明确错误且不返回伪造音频，也不泄漏 panic 中的敏感文本 | 增加解析边界 recover；Release 也记录阶段与无参数符号调用栈，返回可见错误 |
| 本地空结果掩盖在线失败 | `SearchSession.start` → `searchProgressively`：本地成功返回0首，在线请求报错，`successfulSources>0` 导致旧代码进入 `.empty` | 原条件直接可达；新增 XCTest 专项验证 `.failed` 和超时明细 | 无结果且有失败时明确显示“部分来源搜索失败，其余来源未找到结果”；完整空成功才进入空状态 |
| Apple 搜索落后于原仓库依赖 | 本分支 `go.mod` 使用旧 `music-lib@7cc4467`，其 `apple.fetchAppleToken` 只匹配 `index-legacy`；上游用 `af5e6d8`，支持新版 app bundle | 同机旧原生矩阵 Apple 五词均失败；独立上游工作树三词返回90首；更新依赖后原生五词共120首、无歌曲搜索错误 | 精确对齐上游库版本，沿用其业务代码及模型，不重造接口、不更换平台 |

`outputs/rea-panic-after.log` 与 Go 完整测试验证两个子进程不再退出、健康验证候选仍可返回。**受控 panic 证明代码存在进程崩溃路径，不证明它就是用户每一次 iPhone 闪退的唯一原因。** 当前没有用户手机的 `.ips`、Jetsam 或原生异常报告。

新增诊断不会用空 catch 掩盖故障：panic 返回错误并异步记录脱敏符号栈；搜索记录开始、首批结果、完成计数、失败和退出页面。日志不记录关键词、Cookie、Token、音频签名URL或 panic 原文。普通网络追踪仍显式开启，保留上轮 EOF 修复。

## REA 的实际参与与边界

真实调用的服务为 `rea-agents 6.4.0`，MCP连接成功。不是仅阅读技能，也不是假称模型分析为 REA 输出。

| REA操作 | 结果和证据 |
|---|---|
| `binary_session` | Windows；无原生目标；macOS/iOS运行时工具 `unsupported_host`；Ghidra `not_configured` |
| `analyze_javascript_application(ios/MusicDL)` | 解析1个JS文件，1033个AST节点，0条发现，0解析失败；保留160个语义未知。父证据 `ev_2b0d2eef9b1d751bd69eebd7202942c4bf166a5da5902faf86ffd5019068ce1b` |
| `open_binary(Build20.ipa)` + `inspect_artifact` | IPA身份 SHA256 `65d4fe0afb8fb025439dbce9f042eb73c9b26bfc6c8c40c4f084f3279247adee`；归档静态清单证据 `ev_904e69fe4d5321a714791f0cecec376eca5d7ebe7de8391e71847d8a030436e4`；检查后关闭目标 |
| 上游 `app.js` 静态分析与模块视图 | 从精确上游commit导出真实文件：341775字节、47468个AST节点、25条静态发现、无解析失败；语义图到100000节点上限，因此 partial/truncated，9829个未知。父证据 `ev_d4124aa8fd6d962cd2c7cf1509a24ac10b31b3059a0fccf0c9a0cf251c8b1d51`；模块视图 `ev_1d1b21e5bd05d6cd5d71d047c47452daeec69ed7b7d40097f802fb461c925631` |

25条静态发现不等于25个Bug。0条发现也不等于JS已被证明无Bug。REA只执行了语法/归档静态分析，没有执行JavaScript、反编译Swift/Go或观察iPhone。Swift/Go根因和修复由Codex源码追踪及真实受控执行测试确认，不冒充REA的反编译结论。当前原生搜索页本身不使用WebView，搜索和播放均经进程内C ABI；兼容JS桥接另由Node测试验证。

可移植的工具输出：[REA证据摘要](verification/rea-audit-2026-11-10.json)。完整原始bundle保存在工作区外层 `outputs/rea-regression-audit-2026-11-10.json`（4条记录）及 `rea-upstream-evidence-2026-11-10.json`，没有为追求完整语义图反复重跑。

## 全链路审查

| 环节 | 结果 |
|---|---|
| 输入与事件 | `NativeScreens.SearchScreen` 的 searchable、键盘提交、450ms防抖仍绑定 `SearchSession`；切换类型/来源重新搜索，离页取消，重入恢复 |
| 参数与源映射 | 沿用上游 `q/type/sources`，原生只加有限命名JSON封装；源ID通过核心注册表，13在线平台与本地均在，非固定单平台 |
| 请求与服务 | Swift `NativeClient.goTransport` 在后台队列调用 `MusicDLRequest`；`MusicDLStart` 初始化iPhone应用沙盒内Go/SQLite；不依赖Windows IP/端口或Node服务。可选AI仅用127.0.0.1 |
| 生命周期与状态 | @MainActor发布UI状态；代次和取消阻止旧请求污染新页面；Go旧库I/O无context，采用有界槽和合并请求，调用方截止不等于底层请求立即停止 |
| 响应与渲染 | Go转换歌曲/集合并保留ID、source、extra、封面；Swift解码后由原生SongRows展示，无CSS隐藏链路；错误不会转成成功空结果 |
| 故障分类 | URLError类型不再在传输层被通用文字包裹；可区分断网、超时、应用内服务不可用、响应解析、来源内部异常；未授权状态继续明确显示 |
| 播放与换源 | 保留现有AVQueuePlayer、严格版本/歌手/时长匹配与验证后换源；修复旧自动路径的进程崩溃风险，未更改队列/后台播放器实现 |
| ATS/证书/DNS | 真实Go请求已到达外部平台，模拟器原生网络另由CI验证；未关闭TLS验证、未全局放开ATS，也未据此宣称所有地区/真机DNS无问题 |

未发现本轮应修改的Objective-C实现。实际边界为Swift、C ABI、Go和保留的JavaScript兼容桥。

## 原仓库实测对照

独立工作树 `outputs/rea-upstream-worktree` 固定上游commit，增加仅用于审计的临时测试，直接执行原始 `GetSearchFunc`：中文歌曲/歌手和英文三词、13来源、39次真实请求。测试库独立、未加载个人凭证。首次调查测试因Windows SQLite未关闭导致TempDir清理失败，修复调查测试清理后再跑通过；首次失败日志保留，未把它写成接口失败。

当前原生后端跑五词、歌曲/专辑/歌单共205组检查（包括本地、不支持和未授权），另跑三类聚合、首个集合详情和换源音频片段。两边为先后真实样本，返回数量波动不能当作确定性差异或性能提升。

| 音源ID | 上游歌曲条数（3词合计） | 当前歌曲条数（同3词） | 本轮结果与差异 |
|---|---:|---:|---|
| apple | 90 | 90 | 依赖对齐后恢复目录搜索；不等于会员整曲播放 |
| bilibili | 56 | 56 | 歌曲可搜；不支持专辑 |
| fivesing | 30 | 30 | 歌曲可搜；抽查歌单详情仍失败，不支持专辑 |
| jamendo | 20 | 20 | 真实接口有结果；保留原适配器 |
| joox | 71 | 71 | 真实接口有结果；保留原适配器 |
| kugou | 20 | 20 | 真实接口有结果；保留原适配器 |
| kuwo | 19 | 19 | 真实接口有结果；保留原适配器 |
| migu | 60 | 60 | 歌曲可搜；部分专辑详情失败 |
| netease | 2 | 3 | 真实接口有结果；保留原适配器 |
| qianqian | 4 | 4 | 真实接口有结果；保留原适配器 |
| qq | 8 | 8 | 真实接口有结果；保留原适配器 |
| soda | 60 | 60 | 真实接口有结果；保留原适配器 |
| spotify | 90 | 0 | 上游匿名Web Player可搜；当前保留官方OAuth，未配置时明确报错 |


本地使用独立空测试库：0首属于真实空状态，不读写用户文件。上游和当前均保留专辑/歌单搜索能力映射；5sing、Bilibili没有专辑搜索。Jamendo/千千有些集合查询返回空；咪咕专辑、5sing歌单抽查失败仍记录为失败，不删除来源或伪造数据。

Spotify差异如实保留：新上游可经匿名Web Player搜索，其实现包含Web Player TOTP流程；当前App已有官方OAuth/Keychain授权生命周期，本轮未把匿名流程混入用户授权边界。入口和已有功能保留，无配置时显示明确错误；没有Client ID/用户授权时不能声称Spotify与上游搜索等价。私人歌单、完整音频和订阅权限没有因目录可搜索而绕过。

| 功能 | 原仓库 | 当前iOS修复后 | 本轮验证边界 |
|---|---|---|---|
| 歌曲搜索 | 39组真实适配器调用 | 205组矩阵中的歌曲调用，含12个返回歌曲的在线平台 | Apple已恢复；Spotify限制见上 |
| 多源搜索 | 原 `/search` 多来源并发 | 全源歌曲125首，专辑104张，歌单119张；分别有1/2/1个错误 | 真实聚合与失败来源分离，不代表所有接口成功 |
| 音源切换 | 复用原搜索/解析适配器 | 修复自动worker崩溃，保留手动候选 | 3真实候选；酷我/咪咕音频Range探测成功，JOOX失败；不等于整曲播放 |
| 搜索结果展示 | 服务器HTML渲染 | 原生列表、部分先显示、错误/空状态区分 | Go结果、Swift状态及真实键盘UI回归通过；真机待验 |
| 点歌/解析 | 原下载URL解析 | 原C ABI和播放器保留，解析panic返回错误 | 模拟器真实搜索点击进入播放器通过；真机整曲发声未验 |
| 歌单和本地 | SQLite/文件功能 | 数据模型、收藏、路径校验和原生路由未改 | Go既有回归保留；真机旧数据与权限待验 |

真实脱敏逐项结果：[当前/上游对比JSON](verification/rea-live-comparison-2026-11-10.json)。本轮没有宣称“所有音源全部修复”。

## 测试与构建结果

- Windows：依赖对齐后Go六包364通过、15条件跳过、0失败；Node桥接6/6；go vet、后端构建通过。条件跳过的联网审计已另外显式执行，不能把skip计为pass。
- 受控故障：两个真实panic子进程修复前失败、修复后通过；原生解析panic返回明确错误；已有EOF、来源初始化、并发/超时与服务启动回归仍通过。
- Swift新增：本地空掩盖在线失败、搜索中切源及离页/返回旧状态隔离、网络/服务/解析/来源异常分类。本轮最终macOS XCTest 59/59通过，其中58项为单元/受控回归，1项为真实C ABI集成；不将模拟传输视为真实音乐API。
- 真实网络：上游39组、当前205组加3组聚合已执行。启用旧故障相关的HTTP追踪仍完成，不使用Mock冒充真实音源。
- 真机：**未执行**。无Xcode本机、无已连接iPhone、无真机ips/崩溃栈/内存诊断。模拟器与构建结果另行列出。

首个CI运行：[Build21](https://github.com/yann359/go-music-dl/actions/runs/42788448454)，源码 `5c34f8f`。它不含后续依赖对齐，不能交付为最终包。使用仓库既有 `ios-native.yml` 的macos-26/Xcode、设备arm64 Release及XCTest/UI流程，最终运行和IPA完成后补充到此。

### 云端真实失败与调整

Build21被更新版本运行按同分支并发规则取消。包含依赖对齐的 [Build22](https://github.com/yann359/go-music-dl/actions/runs/42789761149) 已完成Go/JS和设备/模拟器编译，但原生测试步骤在10分钟时超时，UI及IPA上传跳过；不能记为XCTest通过，也不能交付这个运行的IPA。

下载的真实诊断 `scheduling.log` 显示09:27:41接收worker、09:37:18才完成bootstrap。运行日志09:37:03已报告步骤超时；Session日志到09:37:18才发出开始执行测试指令，没有本轮断言失败或完整套件结果。原始证据为 `outputs/rea-build22.log`、`rea-build22-test-report.zip`。因此先将模拟器boot/bootstatus与服务可用性检查拆成独立步骤并保存日志，不删除测试，不放宽断言或原有单用例时限。

最终构建源码为 `c1f965733aaf973ff6ffb1797e454cdb12a1c98b`，[Build23](https://github.com/yann359/go-music-dl/actions/runs/42792576244) 全部成功。独立启动步骤最多15分钟，原生测试仍10分钟、UI仍12分钟，断言与单用例时限保留；启动日志实际显示长时间等待Data Migration，提前准备后本次完整执行成功。macOS26/Xcode26.6/iPhoneOS SDK26.5/Go1.26.1，iPhone17 Pro Max/iOS26.5模拟器。本轮Windows没有CGO编译器，未执行Go race；模拟器XCTest也不能替代真机或全局线程安全证明。

原生59项在14.234秒内完成，0失败；UI7项在287.800秒内完成，0失败。UI包括2项无preview的真实启动/键盘搜索，另5项使用明确的界面fixture（含合成音频），不把后者当作音源成功。真实键盘搜索/清空/Home返回/点歌进入队列用例56.433秒通过。原始日志 `outputs/rea-build23.log`、测试结果/截图在 [测试产物](https://github.com/yann359/go-music-dl/actions/runs/42792576244/artifacts/13754280382)。

### 用户要求的12项场景及证据类型

| 场景 | 已具备的覆盖 | 不能据此声称的内容 |
|---|---|---|
| 1.进入搜索不退出 | 原生真实启动UI用例、页面导航回归；Build23通过 | 尚无iPhone操作结果 |
| 2.正常歌曲返回结果 | 原生Go真实矩阵、聚合；键盘搜索真实UI用例 | API有数据不等于所有真机UI均正常 |
| 3.中文/英文/歌手 | 当前五词205组、上游三词39组真实接口 | 未实测用户iPhone中文输入法 |
| 4.快速重复提交 | `testSubmitFlushesDebounceAndCachesSuccessfulSourceOnly`、快速改词代次回归 | 未执行真机连续快速触屏 |
| 5.搜索中切源 | `testChangingSourceAndLeavingPageCannotPublishStaleResponse`，受控旧响应不能覆盖新来源 | 不冒充真实弱网触屏验收 |
| 6.所有已注册来源 | 13来源逐项真实检查，Spotify未配置等状态明确保留 | 不是13来源每个能力都成功 |
| 7.真正空结果 | `testEmptyFailureAndNoSelectionAreDifferentFromIdle`、独立空本地库 | 随机词在某些平台会返回推荐，不能强称为空 |
| 8.超时/断网 | 有界请求池截止回归、Swift URLError分类与恢复回归 | 未执行iPhone飞行模式/蜂窝切换 |
| 9.后端故障不退出 | 真实初始化失败重试/端口占用回归、两个panic子进程及解析边界测试 | 不涵盖OOM、fatal error或未知第三方子协程panic |
| 10.搜索后点歌 | 真实UI用例进入现有队列；真实换源音频片段探测 | 不等于iPhone整曲发声/解码完成 |
| 11.反复退出与返回 | Swift离页取消、返回重搜/旧状态隔离回归 | 尚未进行真机长时间循环操作 |
| 12.桌面返回 | 真实键盘UI用例包含Home/activate；Build23通过 | 未验真实锁屏、来电、蓝牙和后台长期播放 |

## 最终IPA交付与完整性

- [Build23实际运行](https://github.com/yann359/go-music-dl/actions/runs/42792576244)；[下载IPA、源码与许可](https://github.com/yann359/go-music-dl/actions/runs/42792576244/artifacts/13754860083)，有效期至2026-12-10。本地副本为 `../outputs/ios-release-build/build23/music-dl-ios-native-unsigned.ipa`。
- 实际IPA为14,337,073字节，SHA256 `7e8efc21c734c6083ea305f9407372d9fd358e2dc2a69f09fe85b10a89b8a169`。GitHub artifact ZIP的SHA256 `d72f261d1123ebbfb28c2773c5999797589397c8f9797e34bca5f3af1011ab98` 与GitHub digest一致；附带源码标识精确为 `c1f965733aaf973ff6ffb1797e454cdb12a1c98b`。
- 本地重新执行 `ios/scripts/verify-ipa.py`，结果与CI JSON完全一致：Payload结构及CRC、arm64/iPhoneOS Mach-O、未加密、signature_bytes=0、系统动态库依赖、执行文件、Assets及许可资源均核验；无旧签名目录或embedded.mobileprovision。保留后台audio，不依赖Windows服务。
- Bundle ID `com.guohuiyuan.musicdl.nativedesign`；版本1.0.0/Build23；iOS18+。实际 `CFBundleName` 与 `CFBundleDisplayName` 均为纯英文 `MusicDL`，避免此前SideStore App ID名称中文注册错误。没有操作Apple开发者后台或用户手机，不能声称SideStore注册/签名已实测。
- **这是未签名IPA**：下载GitHub artifact ZIP后先解压，再把其中IPA导入SideStore重签。沿用同一签名身份和Bundle ID覆盖原App以保留数据，不主动卸载旧版。不将artifact ZIP直接改后缀为IPA。
- [交付核验JSON](verification/rea-build23-delivery.json)记录包元数据、哈希、签名状态、源码、有效期及本地/CI一致性。后续文档记录提交不改变上述已构建业务代码，无需为文档重复打包。旧Build20及其他旧IPA完整保留。

## 风险与iPhone验收

本轮没有修改视觉规范、Liquid Glass、底部Tab、深浅色主题、动画、播放器UI、数据库结构或用户数据。依赖升级与上游精确一致；Spotify使用本项目已有独立适配器，未接入匿名调用链。旧库底层网络仍可能继续到自身超时，有界请求池限制资源增长；它不能捕获其他协程的任意panic、Go fatal error、Swift运行时trap、OOM或系统杀进程。

安装最终包后需验证：正常中文/英文/歌手搜索、快速重复提交、搜索中切音源、三种搜索类型、真实断网/恢复、反复进出页面、后台返回、点击播放和手动/自动换源、旧曲库/收藏/后台锁屏。没有这些真机结果，不能宣布用户手机上的闪退已全部消失。

若仍退出，请保留时间、所选来源、关键词和包Build号，并从“设置 → 隐私与安全性 → 分析与改进 → 分析数据”导出同时间的 `MusicDL-*.ips`；若有 `JetsamEvent-*.ips` 也保留。`.ips` 中Exception Type、Termination Reason、Triggered by Thread、完整栈与Binary Images能区分原生trap、Go abort、内存压力和系统终止。无需提供Apple密码、签名私钥或完整账号Cookie。

日志含义：`search-start`而无provider记录用于定位发起/桥接；Go source/operation+outcome定位请求或超时；`native-failure class=panic`带阶段和符号帧；`first-result`与`search-complete songs/collections`有数据而UI无行需结合截图/可访问性树；WebView进程退出仅适用于兼容网页模式，原生搜索页无WebView。原生系统崩溃或OOM仍以ips为准。
