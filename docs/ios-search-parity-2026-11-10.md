# CHENGYIN / MUSICDL 搜索恢复验收记录

更新：2026-11-10。分支 `codex/search-parity`；原始可回滚起点 `4ce3d96`。开始时工作树干净。所有统计都是本轮执行记录；不把此前 Build 14 当作本轮交付。

## 1. 原仓库能力与当前差距

核对的上游固定提交为 `c445dddb66eec1b34c04fb16a72577f1115285c7`（1.1.5）。依据：[上游搜索与换源实现](https://github.com/guohuiyuan/go-music-dl/blob/c445dddb66eec1b34c04fb16a72577f1115285c7/internal/web/music.go)、[来源工厂](https://github.com/guohuiyuan/go-music-dl/blob/c445dddb66eec1b34c04fb16a72577f1115285c7/core/service.go)。未合并上游其他功能，也没有重建项目或更改账号方案。

原库有歌曲、专辑、公开歌单搜索；歌曲/歌单/专辑链接识别；按平台并行搜索；本地歌曲/歌单；已有显示过滤设置；按歌名、歌手、时长排名并探测可播放性的自动换源。13 个在线来源中，5sing 和 Bilibili 没有专辑搜索工厂。本地没有专辑搜索。

当前固定的 music-lib 版本为 `v1.1.1-0.20261018010056-7cc4467b4e30`。通用搜索方法只接收关键词，网易等适配器内部使用固定 offset=0；不能声称有通用的上游连续分页接口。

本轮之前 iOS 已有三类搜索后端和逐来源返回基础，并非全部缺失。主要缺口如下：

| 项目 | 修复前 | 本轮实现 |
|---|---|---|
| 搜索触发/生命周期 | 只有 Search 提交；无拥有者任务、无输入防抖 | 键盘 Search/Text 立即提交；450ms 防抖；单一会话拥有任务 |
| 空/旧状态 | 只在再次执行 search 时增加代次，改词/清空不能立即失效旧请求 | 改词与清空立即取消并增加代次，旧请求不能更新新页面 |
| 未初始化默认列表 | defaults 为空时任务组可能不执行任何回调，页面回到初始提示 | 依据真实能力目录选来源；初始化补齐；每种完成/空/失败有明确状态 |
| 音源筛选 | 默认子集；无持久化；目录无本地；完成不重搜 | 全部注册来源+本地；独立保存筛选；显式全不选有提示；完成后重搜 |
| 专辑/歌单链接 | 卡片进入详情可能使用当前分段而非解析后的真实类型 | Go 返回实际 kind，Swift 保留 contentType，本地歌单走收藏详情 |
| 性能/列表 | 未缓存搜索；全部返回条目直接展示 | 成功非空结果缓存120秒；逐批30条；逐来源最多3并发、部分先到先显示 |
| 去重/质量 | 原显示过滤；换源相似度可接受不同版本 | 精确来源+ID+Extra去重；相关性稳定排序；换源严格版本、歌手和时长过滤 |
| 手动换源 | 自动选择一个后直接修改队列 | 展示候选，用户选择后真实探测音频；失败不改队列 |

“周杰伦后仍停留初始页”存在可确认的空 defaults 不发请求路径，也存在旧请求与关键词生命周期缺口。本轮分别加入回归测试；在新包真机验收前，不把这些代码问题称为该 iPhone 现象的唯一已证实原因。

### 界面验收进一步发现：HTTP追踪吞掉EOF

Build17/18的真实界面请求出现单源乃至全源超时，而同台模拟器直接C ABI请求正常。对比发现DEBUG正常启动额外启用了HTTP追踪；`nativeDiagnosticBody.Read`为把EOF记成正常日志，将返回给调用方的`io.EOF`也改成nil，导致`io.ReadAll`在完整响应后无限读取，来源调用占住槽直到调用方8秒超时。这是可复现的代码缺陷，不能归为全部平台同时故障。

已保留原始EOF及读取错误，仅将日志副本分类；HTTP回调日志改为单个有界异步队列，日志管道阻塞时丢弃诊断消息而不阻塞请求。测试先复现失败，修复后EOF及阻塞日志两项回归通过。深层HTTP追踪改为DEBUG显式`--native-network-trace`开启，保留常规请求计时；真实C ABI单测和键盘UI验收都显式开启追踪，确保修复原失败路径。日志只记录主机/阶段/耗时及错误类别，不输出上游错误中可能携带的签名URL或凭证。

这一缺陷直接解释本轮DEBUG界面与未开启追踪的单测差异。旧Release包默认没有该追踪开关，原iPhone初始页现象仍须结合状态/初始化修复及新包真机结果确认，不把DEBUG缺陷说成旧Release问题的唯一原因。

## 2. 已实施的行为与边界

- 搜索区分尚未搜索、正在搜索、部分结果、完成、无结果和全部失败；后续平台失败不会覆盖已经收到的列表。
- 筛选独立使用 `music.search.sources`，保留 `music.search.recent`，不改原有账号、收藏、播放历史和数据库结构。
- Swift 最多3个来源并发；Go 搜索和候选收集也限3个。沿用每来源2个实际 I/O 槽、8秒调用方截止和相同请求合并。旧库没有 context API，取消会立刻阻止界面更新，但底层已经发出的 I/O 可能继续到其自身超时，并持续占用有限槽，不能谎称真正中止了所有远程请求。
- 搜索缓存仅在内存中，最多48条、单条编码不超过128KiB、120秒失效；失败/空结果不缓存，Spotify和本地每次读取。账号与设置变化清理缓存，并用代次阻止旧凭证结果重新写回。
- 全半角、简繁体及不可见字符归一只作用于查询和匹配。歌曲ID、Extra、链接、显示名、授权与音质元数据保留。相同标题的不同来源、版本、音质不粗暴合并。
- 列表“显示更多结果”只分批展示适配器本次真实返回的条目，不会伪造上游第二页；目前仍缺少真正逐平台翻页的扩展协议。
- 换源显示歌手、来源、匹配分和时长差。识别 Live/现场/演唱会、翻唱、伴奏、Remix、Demo、Acoustic、Remaster等标记；自动换源也复用严格匹配守卫。未知时长会明确显示待确认。
- 候选被选中后，保留完整 Extra 解析音频地址，执行有限时 Range GET并检查音频头；HTTP200登录页/HTML不能当作音频成功。验证只说明当时可取得音频，不代表已完成整曲解码或发声。
- 搜索界面、Apple Music风格、Liquid Glass导航及现有播放器结构保留。`NativeAppModel.swift`仅调整DEBUG深层追踪为显式开启。未修改 `AudioEngine.swift`、`PlayerViews.swift`、`NativeRoot.swift` 或授权实现。新增候选页沿用现有原生组件。
- iOS仍使用进程内 Go/C ABI，不依赖 Windows 本地Go/Node服务。汽水会员解密等既有环境限制没有被本轮搜索可用性结果掩盖。

## 3. 真实API结果

在独立测试数据库、没有加载个人账号凭证的测试进程中，执行5个关键词：`周杰伦`、`周杰伦 晴天`、`Mine Mine`、`陈奕迅`、`zzMusicDLNoMatch9f473a21`。每个词覆盖13在线源和本地歌曲/歌单、13在线源专辑（含明确不支持的平台错误），合计205组真实后端检查（含本地、不支持及未授权状态）。以下为五词返回条数之和，不代表全部都精确命中或可播放：

| 来源 | 歌曲 | 专辑 | 歌单 |
|---|---:|---:|---:|
| netease | 8 | 45 | 50 |
| qq | 8 | 40 | 55 |
| kugou | 40 | 40 | 40 |
| kuwo | 23 | 40 | 40 |
| migu | 100 | 61 | 80 |
| soda | 100 | 89 | 98 |
| fivesing | 40 | 0 | 60 |
| jamendo | 21 | 20 | 0 |
| joox | 87 | 12 | 17 |
| qianqian | 8 | 14 | 0 |
| bilibili | 95 | 0 | 54 |
| apple | 0 | 0 | 0 |
| spotify | 0 | 0 | 0 |
| local | 0 | 0 | 0 |

- 另做3种类型的全来源聚合真实调用：歌曲105首（3797ms、2个来源错误）、专辑84张（2640ms、3个来源错误）、歌单121张（2726ms、2个来源错误）。有失败来源时其他来源结果仍保留。
- 本轮11个在线来源至少对一个指定词返回歌曲；Apple旧目录适配器 `index.js URI not found` 失败，Spotify没有授权配置。
- 网易云、QQ可能对某个词返回空列表，后续词又有结果。QQ等部分集合请求有错误，均保留其他来源结果。
- 5sing/Bilibili专辑属于不支持，不是网络连接成功。筛选面板按能力禁用。
- 千千和Jamendo的公开歌单本轮均返回空；不能宣称歌单搜索结果可用。本地独立空测试库返回0，不接触用户本地音乐。
- 对“周杰伦”首个专辑/歌单做真实详情抽查：网易、QQ、酷狗、酷我、汽水、JOOX专辑和歌单有曲目，千千专辑有曲目，咪咕和Bilibili歌单有曲目；咪咕专辑、5sing歌单抽样详情失败。其余没有返回卡片则未探测。
- 真实换源：从酷狗“晴天 / 周杰伦”找到3个同版本候选；酷我160ms、咪咕730ms通过音频Range探测；JOOX244ms未通过。这里没有把网络音频探测当作iPhone整曲播放验收。
- 随机关键词在部分平台仍获得推荐或宽松匹配歌曲（咪咕、汽水、Bilibili）。保留真实响应并稳定排序，不强行伪造空结果，也未添加会误删跨语言歌手/不同版本的硬过滤。精确度仍受各平台搜索规则影响。

可移植的脱敏逐请求证据：[search-api-2026-11-10.json](verification/search-api-2026-11-10.json)。只包含查询、来源、计数、耗时及错误数量，不包含Cookie、Token或签名音频URL。完整本地日志位于外层 `outputs/search-live-matrix-2026-11-10.log`，额外抽查样本为 `outputs/search-quality-samples-2026-11-10.json`。

## 4. 性能实测

Windows同样3并发、同一个“周杰伦”、14来源：修改前首次非空结果402ms、全部3151ms；修改后同条件首次276ms、全部2873ms，分别105/106首。两轮数据量与网络响应不同，这只是一次前后测量，不能归因于代码或宣称稳定提升比例。全矩阵含详情抽查的搜索部分46.545秒，首批391ms。

Build16真实iOS26.5模拟器的Swift→C ABI→Go测量：酷狗/酷我/咪咕共34首，首批964ms，冷请求全部1272ms；三源全部命中同进程内存缓存后耗时低于1ms（整毫秒日志为0），条目集合相同。这是同次运行缓存收益，不代表跨重启或网络性能提高。受控传输的状态单测只验证取消、部分成功、缓存命中和错误分离，不作为真实网络性能证据。

## 5. 最终验证结果

最终为 **Build20 / 源码 `65dbda79373ab13c6b947e4dabf8684cd148cfee`**：[完整构建记录](https://github.com/yann359/go-music-dl/actions/runs/42756768725)。macOS26、Xcode26.6、iPhoneOS SDK26.5、Go1.26.1；模拟器为iPhone17 Pro Max / iOS26.5。

- Windows Go六包：**360通过、15条件跳过、0失败**；Node桥接6/6；go vet、后端构建通过；增量lint无新增问题。默认跳过的真实API审计已另行显式执行。
- **Swift单元56/56通过，UI 7/7通过。** 包括未配置Spotify原曲换源不要求原平台授权的新增回归。需要实际访问Spotify候选时仍检查其自身授权，且阻止预授权回退递归。
- 真实键盘用例显式开启原先失败的HTTP追踪，41.970秒完成：正常Go启动→全来源聚合→输入周杰伦并提交→显示真实结果→点击进入现有播放器→后台返回保留列表→清空回初始状态。未使用 `--ui-testing` 样例。成功截图也显示了播放器真值“正在播放”；这不代表已经完成真机整曲验证。
- 最新真实C ABI三源34首：首批**562ms**、全部**1058ms**、三个来源全部命中同进程内存缓存后**低于1ms**（整毫秒日志0）。Build19同路径首批388ms、全部1133ms；外网样本会波动，不宣称固定比例提速。
- 真实后端矩阵205组，包含本地、明确不支持和未授权状态；另3组全来源真实聚合及详情/换源抽查已执行。接口成功、空结果、不支持、错误与可读音频分别记录，不说“205个外部接口全部成功”。
- EOF修复后，Windows开启追踪的14源复测返回94首，首批630ms、全部4892ms；只有Apple及未配置Spotify报错。受控EOF/阻塞日志测试属于机制回归，不冒充音乐API验收。
- Build15编译作用域错误、Build16旧测试初始化前提错误、Build17/18诊断EOF缺陷导致的真实UI超时均保留记录；EOF修复后的Build19和含授权边界修复的Build20已完整通过。

| 用户要求的场景 | 证据与结论 |
|---|---|
| 全来源、单来源、三种类型 | 205组真实后端检查+3组全来源聚合；真实可用性与空/失败分别记录 |
| 部分音乐源失败 | 真实聚合中的Apple/Spotify失败不丢其他结果；受控状态回归通过 |
| 快速修改关键词 | Swift代次/取消状态回归通过；不把控制传输当作真实平台响应 |
| 清空关键词 | Swift回归和真实键盘UI均通过 |
| 搜索结果点击播放 | 真实UI点击接入现有播放器，截图显示正在播放；真机整曲仍待验证 |
| 歌曲换源 | 真实3候选、2音频探测通过、1失败；版本/歌手/时长/HTML伪音频回归通过；真机候选触控与完整播放待验收 |
| 断网后恢复 | 受控失败/重试回归通过，已接NWPath恢复；真实iPhone断网切换待验收 |
| 后台返回 | 真实键盘UI通过；真机锁屏/中断/切歌仍需验证 |

原始日志在外层 `outputs/search-go-tests.jsonl`、`search-live-matrix-2026-11-10.log`、`search-traced-after-eof-2026-11-10.log`；完整Build20日志与本地包核验结果见外层 `outputs/search-build20.log`、`outputs/ios-release-build/build20/local-verification.json`。GitHub另保留对应XCTest结果和截图产物。

## 6. 修改文件

- `core/text_normalize.go`：查询/比较归一，保留原始ID与展示数据。
- `internal/web/native_client.go`：类型元数据、并发限制、稳定排序和精确去重；增加候选及验证动作。
- `internal/web/native_requests.go`、`native_diagnostics_test.go`：保留EOF、有限异步诊断、不记录敏感错误URL及两项阻塞/流结束回归。
- `ios/MusicDL/NativeAppModel.swift`：深层网络追踪显式开启，普通启动保持Release网络路径。
- `internal/web/native_search_quality.go`：仅排序的相关性计算。
- `internal/web/native_search_switch.go`：候选匹配、版本守卫、有限并发和真实音频探测。
- `internal/web/music.go`：自动换源复用严格匹配。
- `internal/web/local_music_index.go`：本地歌名+歌手跨字段组合查询及转义通配符。
- `ios/MusicDL/NativeClient.swift`：全部能力目录、本地、短缓存、逐来源汇总和换源接口。
- `ios/MusicDL/SearchSession.swift`：搜索任务/状态/取消/防抖与显示批次。
- `ios/MusicDL/NativeScreens.swift`：接入会话，保留搜索布局、增加搜索行元数据与偏好，歌曲菜单打开候选页，搜索行按播放器真值显示正在播放/暂停/连接/失败；未验证歌曲明确标为待点播验证。
- `ios/MusicDL/SourceSwitchScreen.swift`：候选选择与验证反馈。
- `internal/web/native_search_parity_test.go`、`native_search_live_test.go`；`ios/Tests/SearchSessionTests.swift`、`NativeBridgeIntegrationTests.swift`、`StabilityTests.swift`；`ios/UITests/NativeVisualTests.swift`：回归、真实API、C ABI性能与真实键盘用例。
- `PROJECT_STATUS.md`、本报告及脱敏JSON：构建/验收与限制。

## 7. 回滚与剩余工作

`NativeClientTests.swift`另增加未配置Spotify原曲换源不需原平台授权的回归。

代码检查点：`bc813f6`、`dbd68ea`、`1a6fa8a`、`a9939be`、`6962314`、`65dbda7`。可创建旧基线分支 `git switch -c codex/search-before 4ce3d96` 查看原状态；继续使用本轮分支即可保留当前代码。需要撤回时按后到先顺序revert具体功能提交，不执行hard reset，也不删除数据库/缓存目录。

剩余问题：Apple适配器和Spotify配置；5sing歌单及咪咕部分专辑详情；各平台随机词宽松匹配；真正的上游搜索分页；底层无context取消；Xcode验收已通过，尚待iPhone实机验收。最终新IPA已真实构建并核验，见第8节；尚未进行iPhone重签名安装。


## 8. 最终IPA交付

- 最终产物：[Build20下载](https://github.com/yann359/go-music-dl/actions/runs/42756768725/artifacts/13736807222)。
- 本地：`C:/Users/Administrator/Documents/ChatGPT/apple music/outputs/ios-release-build/build20/music-dl-ios-native-unsigned.ipa`。
- 大小：14,325,073字节；SHA256：`65d4fe0afb8fb025439dbce9f042eb73c9b26bfc6c8c40c4f084f3279247adee`。
- 来源：`65dbda79373ab13c6b947e4dabf8684cd148cfee`；Bundle ID `com.guohuiyuan.musicdl.nativedesign`；版本1.0.0 / Build20；arm64、iOS18+、未加密、未签名；保留后台audio。
- 已核验：ZIP完整性、真实iOS Mach-O、平台/架构、执行文件权限、动态库引用、Assets.car及许可资源；无第三方嵌入框架遗漏。GitHub产物digest、IPA校验值、源码SHA及CI/本地包验证均一致。
- 这是可交SideStore/AltStore重新签名的真实IPA；安装需要用户个人签名流程，不能直接把未签名包视为已经安装成功。没有把Apple ID密码、私钥或Token写入源码或公开日志。
- 保持相同签名身份及Bundle ID进行覆盖更新以保留现有数据；不要为更新主动卸载旧App。签名工具若改变身份/ID需先核对旧安装；本轮未操作用户iPhone数据。
- 尚需真机：实际输入法、三种搜索结果交互和本地曲库、整曲播放、换源、真实断网恢复、后台/锁屏/中断、Liquid Glass显示与地区/账号权限。Apple旧目录适配器、Spotify配置、5sing部分歌单及咪咕部分专辑、真正上游搜索翻页等限制仍如实保留。

文档/审计工具的后续提交不改变已构建代码来源：最终IPA严格对应上述`65dbda7`。
