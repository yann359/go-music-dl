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

这是一处可复现的**准备队列过早成为系统媒体信息来源**的时序缺陷。它解释了为何加载期间就能发布歌曲信息；**它尚不能独立证明用户描述的“真正播放后前台始终有小岛”及Home视觉过渡的全部根因**。同机Apple Music对照由用户确认，仍作为最终真机验收标准。

## 原生机制与实现

依据Apple [WWDC22 自动发布说明](https://developer.apple.com/videos/play/wwdc2022/110338/?time=434)、[automaticallyPublishesNowPlayingInfo](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/automaticallypublishesnowplayinginfo)、[AVPlayerItem.nowPlayingInfo](https://developer.apple.com/documentation/avfoundation/avplayeritem/nowplayinginfo)：

- 唯一MPNowPlayingSession开启自动发布；曲目静态信息写入真实AVPlayerItem（包括预加载项），系统从实际player观察时长、进度、速率、暂停和切歌。取消手工从“请求中的歌曲队列”拼装时间状态并写系统中心的路径。
- 按Apple [AVAudioSession激活指引](https://developer.apple.com/documentation/avfaudio/avaudiosession)，将setActive也从点击按钮移到实际媒体项ready、即将启动播放之时，避免准备阶段过早打断其他音频。play只保存播放意图；currentItem尚未ready时不对空/未就绪player设置正速率。就绪后按已有播放意图自动启动；准备中暂停则不自动抢播。未增加固定延时，也没有读取前后台状态来隐藏或延后媒体信息。
- stop/退休会话才关闭自动发布、清信息和命令；正常Home/active不创建会话、不清信息、不改自动发布模式。媒体服务重置仍遵守原有会话观察者生命周期，不逐个removePlayer。
- 保留App每秒本地状态刷新，静态item元数据按内容去重；系统时间推演不再依赖App每秒回调。前台/后台采用同一路径，没有Live Activity、自制岛、私有API或动画调整。
- 诊断schema2新增毫秒/单调时钟/事件序号、会话UUID、真实item存在/status、timeControlStatus、播放意图、item元数据、启用命令数及具体命令、中断与inactive事件。仍有界保存，不记录歌曲、URL、账号或凭证。旧metadata_updates是手工中心写入数；新item_metadata_updates是静态item写入数，二者不可直接比较。
- MiniPlayer仅增加供VoiceOver读取的“正在播放/正在准备/已暂停”值；UI探测先等待真实playing值，再分别截图App内和Home状态。Home截图移到系统目标探测后，避免旧版立刻截到退场中间帧。没有改变界面布局或用户操作流程。

## 修改与验证

基线36d6a43、分支codex/real-device-media-timing。修改AudioEngine.swift、MediaSessionDiagnostics.swift、NativeRoot.swift（仅inactive日志）、PlayerViews.swift（仅无障碍状态值）、MediaSessionTests.swift、NativeVisualTests.swift、本文及PROJECT_STATUS.md。搜索、下载、来源、数据库与签名配置不变。本轮不使用REA。

新增受控资源准备门闩的两项回归：准备期间没有currentItem/正速率/歌曲元数据/远程命令；资源就绪后正确启动；准备中暂停不在就绪后自动播放。既有播放/暂停/原生seek、同曲循环、预加载切歌、前后台返回、stop后重新使用会话及媒体服务重置回归全部保留，并改为验证原生自动发布的输出。

本地Node6/6、diff检查通过。首轮Build30在准备模拟器期间被补齐音频会话激活时机的修订取代，取消而未交付。Windows没有iOS SDK，设备/模拟器编译和原生XCTest将使用现有macOS流程，结果待补。旧Build29与Build28保留；没有操作手机安装、重签或卸载。

最终仍需新包在原iPhone上验证：加载中→真实播放中→上滑Home→重新进入App，及锁屏/控制中心/轻点/长按/切歌/暂停。不得用模拟器的不可定位skip或静态截图代替真机过渡验收。
