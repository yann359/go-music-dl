# 真机媒体会话日志分析与原生播放时序修复（2026-11-11）

## 证据与结论范围

本轮实际读取用户上传的 `media-session.jsonl`：20,818字节、45条有效JSON、0坏行，记录的版本全部为Build28，系统为iOS27.3（24C5037i），运行bundle为项目原标识。记录覆盖北京时间2026-11-11 07:56:25至08:25:56，共29分31秒。原日志SHA256 `78b5c27f6abe50a720660818b0a49f6eff5cf517f3b8a61fc1fee79ccc07582e`。未把用户原始日志、进程编号或引擎UUID提交到仓库。

全段仅1个引擎、1条session-created、1条ownership-changed，session_players一直为1；没有ownership-accepted、ownership-declined或会话重建。会话在启动时自动成为App内活动会话，早于第一次play请求8秒，之后一直active。**删除主动提升调用的Build29不是这份日志中现象的已证实修复**：Build28的该调用本来就没有发生。

`isActive`仍只表示App内活动会话，不是系统全局媒体归属证明；bundle日志也不是签后entitlements校验。不能由此宣布签名完全正确，也不能反过来认定SideStore故障。日志没有屏幕像素、岛的可见性、Home手势进度或激活入口，不能证明动画本身或点击来源。

## 实际时间线

| 北京时间 / 原始行 | 真机记录 | 能支持的结论 |
|---|---|---|
| 07:56:25 / 1–3 | session创建；idle、队列0、元数据更新0；自动active；App active | 初始active发生在播放之前，不等于歌曲已上岛 |
| 07:56:33 / 4 | 前台audio-activated，队列13，rate0，元数据0 | 用户已发起播放意图，音频会话进入非混音playback类别 |
| 07:56:35 / 5–7 | background→active；preparing、rate1、元数据1 | 系统歌曲信息已经发布，UI发布状态仍是准备中 |
| 07:56:37–38 / 8–9 | 继续preparing、rate1；元数据2 | 准备阶段仍有歌曲/封面发布，非等到实际媒体项就绪的路径 |
| 07:56:41–07:58:24 / 10–18 | playing；多次前后台；元数据始终5，直到远程命令→暂停→6 | 此时没有每秒闪写、活动重建或反复激活；远程暂停进入了App |
| 08:06:07–30 / 35–39 | 换队列114；preparing、元数据14；后续远程命令触发audio-activated | 另一段准备/恢复窗口；原日志没有实际item状态，不能将rate1等同于发声 |
| 08:07:13–14 / 40–42 | playing；恢复现有播放器后返回后台；元数据18 | 前后台恢复存在，不能识别来自图标还是灵动岛 |
| 08:25:26–56 / 43–45 | 暂停，然后interrupted；元数据27 | 有中断/暂停尾段；原日志缺少中断类型和原生时间控制字段 |

17条scene-active、12条scene-background不能解释为17次完整后台返回：inactive（例如控制中心或系统交互）也能转active，原版没有记录inactive。两个同秒事件也不能代表零耗时。

## 能由源码确认的缺陷

Build28的play在没有currentItem时直接调用playImmediately(atRate:)，因此AVPlayer.rate可以为1但没有可播放的项；publish又仅凭songs[index]发布曲目和封面，并按currentSong启用远程命令。源码的preparing分支为`currentItem == nil && preparing`，与上述日志窗口相容；但旧日志state是上次publish的缓存，因此本轮补了实际item/timeControl字段，而不把缓存状态当成独立的AVPlayer状态快照。

这是一处可复现的**准备队列过早成为系统媒体信息来源**的时序缺陷。它解释了为何加载期间就能发布歌曲信息；**它尚不能独立证明前台小岛可见性及Home视觉过渡的全部根因**。同机Apple Music对照由用户确认，仍作为最终真机验收标准。

## 原生机制与实现

依据Apple [WWDC22 自动发布说明](https://developer.apple.com/videos/play/wwdc2022/110338/?time=434)、[automaticallyPublishesNowPlayingInfo](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/automaticallypublishesnowplayinginfo)、[AVPlayerItem.nowPlayingInfo](https://developer.apple.com/documentation/avfoundation/avplayeritem/nowplayinginfo)：

- 唯一MPNowPlayingSession开启自动发布；曲目静态信息写入真实AVPlayerItem（包括预加载项），系统从实际player观察时长、进度、速率、暂停和切歌。取消手工从“请求中的歌曲队列”拼装时间状态并写系统中心的路径。
- 按Apple [AVAudioSession激活指引](https://developer.apple.com/documentation/avfaudio/avaudiosession)，将setActive也从点击按钮移到实际媒体项ready、即将启动播放之时，避免准备阶段过早打断其他音频。play只保存播放意图；currentItem尚未ready时不对空/未就绪player设置正速率。就绪后按已有播放意图自动启动；准备中暂停则不自动抢播。未增加固定延时，也没有读取前后台状态来隐藏或延后媒体信息。
- 加入Apple [有限后台任务](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))，从用户播放意图开始覆盖资源准备，防止“准备中马上回桌面”依靠空player/提前占用音频来保活；播放、暂停、中断或失败时释放，系统到期则取消本次准备并提示返回重试。不播放静音、不无限保活，长资源准备仍受iOS后台预算限制。
- stop/退休会话才关闭自动发布、清信息和命令；正常Home/active不创建会话、不清信息、不改自动发布模式。媒体服务重置仍遵守原有会话观察者生命周期，不逐个removePlayer。
- 保留App每秒本地状态刷新，静态item元数据按内容去重；系统时间推演不再依赖App每秒回调。前台/后台采用同一路径，没有Live Activity、自制岛、私有API或动画调整。
- 诊断schema2新增毫秒/单调时钟/事件序号、会话UUID、真实item存在/status、timeControlStatus、播放意图、item元数据、启用命令数及具体命令、中断与inactive事件。仍有界保存，不记录歌曲、URL、账号或凭证。旧metadata_updates是手工中心写入数；新item_metadata_updates是静态item写入数，二者不可直接比较。
- MiniPlayer仅增加供VoiceOver读取的“正在播放/正在准备/已暂停”值；UI探测先等待真实playing值，再分别截图App内和Home状态。Home截图移到系统目标探测后，避免旧版立刻截到退场中间帧。没有改变界面布局或用户操作流程。

## 修改与验证

基线36d6a43、分支codex/real-device-media-timing。修改AudioEngine.swift、MediaSessionDiagnostics.swift、NativeRoot.swift（仅inactive日志）、PlayerViews.swift（仅无障碍状态值）、MediaSessionTests.swift、NativeVisualTests.swift、本文及PROJECT_STATUS.md。搜索、下载、来源、数据库与签名配置不变。本轮不使用REA。

新增受控资源准备门闩的两项回归：准备期间没有currentItem/正速率/歌曲元数据/远程命令；资源就绪后正确启动；准备中暂停不在就绪后自动播放。既有播放/暂停/原生seek、同曲循环、预加载切歌、前后台返回、stop后重新使用会话及媒体服务重置回归全部保留，并改为验证原生自动发布的输出。

本地Node6/6、diff检查通过。准备中的Build30–33被本轮修订取代，取消而未交付；Build34在设备编译阶段因新增诊断字典类型推断超时失败，没有执行原生测试或交付IPA。补明确的[String: String]类型后重新构建，最终代码91983c00fd6096e4ed5ba111bb897696d62628ed的[Build35](https://github.com/yann359/go-music-dl/actions/runs/42945824242)全部成功。

| 验证 | Build35实际结果 |
|---|---|
| Go / Node | 四包通过 / 6项通过 |
| iPhoneOS Release / 模拟器编译 | 通过；Xcode26.6、SDK26.5 |
| Swift XCTest | 67/67，包括66项单元/受控测试及1项真实C ABI网络集成；媒体会话8项全通过 |
| 原生UI | 7通过、2跳过、0失败；两项真实启动/搜索/后台流程及5项fixture回归通过 |
| 灵动岛轻点 / 长按 | 模拟器不暴露可识别曲目媒体岛，明确跳过，未算通过 |
| 用户iPhone / iOS27.3 | 尚未安装新包；显隐、Home过渡、锁屏/控制中心及重签身份待真机验收 |

媒体回归实际验证系统自动生成时长/正速率/暂停零速率/暂停seek、同曲循环归零、预加载切歌、stop后重用同一会话和重置退休旧会话。新增受控准备回归还验证：未就绪时音频激活计数为0；就绪后按1.5倍速启动且只激活一次；准备中暂停则不抢播并释放有限后台任务。后台任务系统到期路径未在用户设备端到端触发，不声称后台准备可无限持续。

本轮模拟器为iPhone17 Pro Max/iOS26.5，并非用户iOS27.3真机。已从完整测试报告提取并查看`foreground.png`和`home.png`：前者为实际播放后的App内画面，后者为目标探测等待后的稳定桌面；两图均未见媒体岛。不能从缺少目标的模拟器推断真机前台显隐正常，或用这两张静态图证明动画流畅。[原始测试报告](https://github.com/yann359/go-music-dl/actions/runs/42945824242/artifacts/13824235276)共106,722,152字节，下载SHA256与服务器digest一致：`bf5a2ee157e258308f6ab8ba0732652b3d2148a4a3a0d8b462cd06b30275aa3c`。构建日志保留在外层`outputs/island-real-build35.log`。

## 新IPA与追溯

后续根据用户“可直接在iPhone下载”的要求，将同一受测IPA发布为公开验证版：[手机直接下载MusicDL-Build35.ipa](https://github.com/yann359/go-music-dl/releases/download/ios-build35/MusicDL-Build35.ipa)，[下载页及匹配源码/许可](https://github.com/yann359/go-music-dl/releases/tag/ios-build35)。无须登录或解压Actions ZIP。仅重命名，包内容与下面SHA256相同；下载后从SideStore选择该文件重签覆盖安装，不是Safari免签安装。此下载页不使用Actions artifact的30天保留期。[公开下载核验记录](verification/build35-public-download.json)。

[Build35 IPA、匹配源码、许可证及核验文件](https://github.com/yann359/go-music-dl/actions/runs/42945824242/artifacts/13823144437)。本地文件`../outputs/ios-release-build/build35/music-dl-ios-native-unsigned.ipa`，14,354,553字节，SHA256 `41de973b2ca4c08ea2eef0c45fade4d067df82cb27fa58011591d75717f0ec8d`。原Bundle ID `com.guohuiyuan.musicdl.nativedesign`、MusicDL、1.0.0/Build35、arm64 iPhoneOS/iOS18+、后台audio、未签名/未加密。交由SideStore沿用原签名身份覆盖安装；没有操作手机安装、重签或卸载，旧Build29与Build28保留。

IPA附带hash、内外ZIP CRC、服务器artifact digest、六份修改Swift对应源码、CI与本地verify-ipa输出均一致。IPA artifact外层ZIP SHA256为`63f3ec59298753025fd4bbe27f015527ff52b4da8a44c15593ebd8e7894de8f8`，云端有效期至北京时间2026-12-11 10:44，本地副本保留。脱敏核验见[结构化交付记录](verification/real-device-media-build35-delivery.json)。

若需撤销本轮代码，按新到旧执行`git revert 91983c0 a87917a 551728f f47b0a8 7b82837 7b87921`；这不影响外层旧包或用户手机。最终文档提交另行记录，未修改被测试的Swift代码。

## 真机验收与系统边界

最终仍需新包在原iPhone上验证：加载中→真实播放中→上滑Home→重新进入App，及锁屏/控制中心/轻点/长按/切歌/暂停。不得用模拟器的不可定位skip或静态截图代替真机过渡验收。

App负责真实媒体状态和稳定的单一会话，iOS负责媒体岛的呈现、Home过渡、轻点激活及长按系统面板。公开媒体API没有可强制隐藏前台媒体岛或控制Home手势中岛动画的开关。本轮没有利用清空信息、延迟发布或私有API强求动画；这也不意味着原Build28相对同机Apple Music的异常已被证明为系统统一行为。现阶段能交付的是有真机日志依据、通过原生回归的时序修复及Build35验证包，核心视觉目标继续以用户同机对照为准。
