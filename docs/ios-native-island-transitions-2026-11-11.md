# 原生灵动岛与媒体会话交互复查（2026-11-11）

## 范围与证据

从干净提交 `3afcf14`、原分支 `codex/now-playing-island` 开始，阅读 PROJECT_STATUS.md、最近十次提交及上一轮媒体会话变更。本轮分支 `codex/island-native-transitions`。未使用 REA；仅修改原生媒体信息发布、返回播放器的动画事务和相应测试，没有修改搜索、下载、来源、身份或页面设计。

## Apple 官方资料

已在线读取用户指定的四份官方资料：

- [Now Playing](https://developer.apple.com/documentation/nowplaying)：当前新框架从 iOS 27 开始提供，描述媒体内容与命令，由框架更新系统。本项目仍支持 iOS 18，继续使用既有 MediaPlayer 会话，避免同时引入两套发布机制。
- [Becoming a now playable app](https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app)：提供系统媒体信息、注册远程命令的示例；没有提供“仅后台上岛”的开关。
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)：ActivityKit 管理独立的 Live Activity，WidgetKit 描述其 UI；系统选择呈现。此路径不应重复承接本项目已有的系统媒体播放。
- [Live Activities HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities)：紧凑/最小/展开呈现及点击进入相关内容、长按展开的设计语义。其自定义 Live Activity 动画指导不能直接解释为本地媒体岛可配置的动画参数。

补充核实：

- [Apple Live Activities 团队问答](https://developer.apple.com/news/?id=qpqf1gru)：Now Playing 也能提供灵动岛系统 UI，只有自定义 UI 才需要 Live Activities。
- [MPNowPlayingSession](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession)：一个 AVPlayer 只关联一个 Now Playing 会话，播放器、信息中心与命令中心保持一致。
- [ElapsedPlaybackTime](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime)：系统根据已提供的进度与速率计算进度，无需频繁更新。
- [WWDC19 媒体时间同步](https://developer.apple.com/videos/play/wwdc2019/501/)：在速率改变或进度跳转等显著变化时更新，无需每秒重发。
- [WWDC22 媒体发布](https://developer.apple.com/videos/play/wwdc2022/110338/)：媒体会话的资格、元数据与远程控制整合。

以上是公开 API 和系统交互约定，不是 Apple Music 私有源码或逐帧动画实现。未接入 iPhone、未实际操作 Apple Music，不能宣称完成真实同机对比。

## 排查结果与修复

1. **前台立即上岛并非已证实的代码故障。** 未发现 ActivityKit 导入、Live Activity/Widget 扩展、NSSupportsLiveActivities、自定义岛或竞争的生产播放引擎。现有播放会话为单个 AVQueuePlayer + MPNowPlayingSession，手动发布且自动发布关闭；命令使用同会话中心。前台和后台持续提供真实媒体信息是正常原生路径。公开接口不承诺前台隐藏媒体岛，也不允许选择系统收缩、扩张和 Home 过渡的时刻。本轮没有根据前后台隐藏/清空信息、推迟注册或模拟系统动画。
2. **已证实每秒重写整个系统播放字典。** ticker、播放器 KVO、前台通知及连接状态查询都进入 publish。改为比较除 elapsed time 外的元数据以及 AVPlayerItem 身份，仅在内容、封面、时长、队列、实际速率变化或 seek 完成时写系统中心；UI/控制连接每秒状态刷新保留。重复播放同曲的新 item 也重新锚定时间。去重缓存只在 stop/会话退出时清除，不在前后台切换时清除。没有用去重隐瞒任何状态变化。
3. **已证实异步 KVO 之间存在混用曲目的窗口。** currentItemChanged 跳到 MainActor 后才更新 index，但 ticker/速率回调可能先读取新 item 的时间和旧 index。publish 现在首先以当前 item 的映射校正 index，并同步清理旧曲封面，再构造一致的元数据；增加 player.rate 观察，按实际速率发布。
4. **返回时存在两层动画的代码路径。** 上一轮后台返回会主动打开 FullPlayer，它带有从 mini player 展开的 zoom/sheet。此时系统也在处理 App 返回过渡。现在仅在确需恢复且播放器尚未显示时，使用无动画事务恢复原有页面；用户主动点击 mini player 的动画保留。是否消除用户设备上的视觉卡顿仍需真机验证，不能仅靠源码认定全部闪烁根因。
5. **其余会话生命周期保留。** Home/锁屏/active 不新建会话或清空信息；pause 保留信息并发布速率 0；stop 清理；实际媒体服务重置或播放失败恢复才替换 player/session；沿用已修正的 KVO 释放顺序。播放音频类别为 playback/default/longFormAudio，不混音，后台 audio 配置保留。远程播放、暂停、切歌、seek 和原播放恢复边界不变。

修改文件：`ios/MusicDL/AudioEngine.swift`、`ios/MusicDL/NativeAppModel.swift`、`ios/Tests/MediaSessionTests.swift`、本文和 `PROJECT_STATUS.md`。诊断日志新增累计 metadata_updates，仍不含歌曲、凭证或 URL。

## 验证与系统限制

新增真实 AVQueuePlayer + 合成 WAV 回归：连续进度与前台通知不重写元数据/不更换会话；暂停与暂停 seek 立即同步；不等待 KVO 的手动切歌信息匹配当前 item；单曲重复播放重置系统时间锚点。保留原会话、媒体服务重置、后台返回及全部既有测试。音频 fixture 延长至 12 秒，以免时间相关用例被 2 秒循环干扰。测试中的等候仅用于观察真实准备/播放，不是产品延迟动画。

本地 Node 6/6 通过，git diff --check 通过。Windows 没有 Swift/iOS SDK，本轮 macOS 编译与 XCTest 结果待后续写入 PROJECT_STATUS.md；上一轮 Build26 仅是历史结果。

真机验收矩阵（本轮均待执行）：

| 操作 | 原生验收预期 | 证据边界 |
|---|---|---|
| 前台开始播放 | App 播放器与系统信息一致，不重复创建活动 | 是否显示岛由 iOS 决定，不能硬性断言必须隐藏 |
| 滑回桌面，连续往返三次 | 声音/进度连续，同一 player/session；没有额外播放器展开动画 | 自动化通知不能证明系统 Home 动画流畅 |
| 从图标或媒体岛返回 | 系统激活 App 后恢复当前播放器，暂停状态保持 | 传统 MediaPlayer 不区分两种激活来源；激活失败仍查签后身份/系统日志 |
| 暂停/恢复，前后台切歌，单曲循环 | 正确标题/封面/队列索引/速率/进度；不瞬时混用曲目 | 岛暂停后停留多久由系统决定 |
| 锁屏/控制中心播放、暂停、下一首、进度拖动 | 操作同一个引擎，返回 App 状态一致 | 必须用真机操作系统控件验证 |
| 轻点/长按媒体岛 | 轻点系统打开 App，长按系统展开控制，操作有效 | 模拟器未暴露目标时明确跳过，不用 app.activate 冒充点击 |
| 同设备 Apple Music 对照 | 相同 OS/路由/其他活动，录制上述操作及时间戳 | 不保证第三方拥有系统 App 的全部呈现策略 |

不使用私有 API，不修改 bundle/signing，不新增自我 openURL。源码能修正冗余发布、曲目信息竞态及重复导航动画；不能强制系统前台藏岛、后台显岛，不能控制长按展开/锁屏/多活动竞争动画，不能用无真机日志证明已解决 SideStore 激活问题。

回滚：本轮代码形成独立修复提交，可 `git revert <本轮修复提交>`；保留 Build26 IPA，不卸载 App 或触碰本地音乐数据。
