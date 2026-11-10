# Apple Music 原生媒体交互与 MusicDL 灵动岛专项

日期：2026-11-10。范围仅限系统媒体会话、场景恢复、重签身份及回归。干净基线 `4e9e094`，分支 `codex/now-playing-island`。用户真机为 **iPhone 17 / iOS 27.3**；已核验的上次交付IPA为 **Build23**，不是项目默认构建号1。尚未读取手机实际安装版本，不宣称两者一致。

**同机用户对照已收到：Apple Music播放时，轻点桌面媒体岛直接返回Apple Music；MusicDL的相同操作不能正常返回。** 这是用户提供的真机观测，不是Codex/REA远程操作结果。由此C不能被解释为“该iOS版本所有音乐App的正常单击语义”；异常属于MusicDL/其安装环境路径，具体激活失败层仍待日志。锁屏和控制中心对照结果尚待用户补充。

## 结论先行：A/B保持系统行为，C分层修复与验证

| 用户真实场景 | 当前判断 | 本轮处理 |
|---|---|---|
| A：App前台能播放，但顶部没有封面/媒体状态 | 单凭该现象不能判为App故障；系统媒体岛不是应用可强制常驻的界面 | 不制造前台媒体岛，不改变系统显示时机 |
| B：上滑到桌面才出现入岛动画，后台继续播放 | 与系统跨App展示媒体状态及过渡策略相容；动画本身不是缺陷证据 | 保留真实后台音频，继续发布系统媒体信息，不提前伪造动画 |
| C：桌面轻点媒体岛未正常返回MusicDL | 优先问题，需区分“系统未激活App”和“App已激活但停在旧页面” | 后者有明确源码缺口，已补恢复当前播放器；前者加入公开会话绑定及归属诊断，真机因果仍待日志 |

Apple公开资料说明Now Playing是系统媒体界面的一种来源，ActivityKit是自定义Live Activity的另一路径；普通音频无需创建Live Activity。[Apple：Live Activities团队问答](https://developer.apple.com/news/?id=qpqf1gru)

**没有读取Apple Music私有源码，Codex/REA也未亲自操作Apple Music真机或录屏。** 下述是官方公开机制、用户观测、项目代码证据三者的对照，不能称为已证实Apple Music所有版本每一帧行为。Apple资料未承诺“播放App在前台时永远显示/永远不显示媒体岛”；所以不将A/B武断改成强制显示。其他第三方音乐App同样应使用公开媒体会话；本轮没有虚构Spotify等App的同机对照结果。

## 十个研究问题

### 1—3. 前台展示、退后台动画与差异

Music在App内提供MiniPlayer与Now Playing页面，这是用户在前台操控歌曲的主要界面；本项目保留相同交互结构。[Apple音乐播放器指南](https://support.apple.com/en-gb/guide/iphone/iph676daac9b/ios)

Dynamic Island的呈现、收起、并行活动及动画由系统管理。官方指南支持在桌面或其他活动App中查看活动，并说明长按展开等操作；这不是App可以指定动画时刻的许可。[Apple Dynamic Island指南](https://support.apple.com/en-mide/guide/iphone/iph28f50d10d/ios)

据此，用户A/B现象与原生呈现方式相容，本轮不修改。其精确差异（iOS27.3、同机Apple Music、其他App占岛、路由及暂停状态）仍需同机对照；不能把通用Live Activity说明当作音乐岛前台显示的绝对规则。

### 4—5. 轻点恢复与长按控制

系统为当前Now Playing应用显示信息并路由控制。长按媒体岛展开的是系统控件；App提供元数据、音频状态与远程命令响应，不直接绘制该面板。**没有可用于传统MediaPlayer的公开“灵动岛点击回调”，也没有公开API可强制SpringBoard启动一个指定Bundle。** 本轮不使用私有MediaRemote、应用标识伪装、虚假AssetURL或后台自我openURL来代替系统激活。

实际故障必须分层：媒体会话有无激活 → 当前归属与实际Bundle → 系统是否激活MusicDL场景 → UI是否恢复当前歌曲。如果系统没有激活App，单加SwiftUI导航不能修复这一层；如果激活后仍停留旧页面，则是本项目可直接修复的导航缺口。系统启动原生App与其生命周期由UIKit/Scene管理。[UIKit生命周期](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle)

### 6—7. 音频、Now Playing、锁屏和控制中心如何协同

公开的系统入口为非混音播放音频会话、Now Playing信息、远程控制处理。Apple在WWDC22推荐使用与AVPlayer关联的MPNowPlayingSession；它把播放器、会话信息中心与远程命令中心聚合。单会话可以成为默认会话，多会话必须正确选定活动会话。[WWDC22](https://developer.apple.com/videos/play/wwdc2022/110338/)

本项目已经使用AVQueuePlayer、AVAudioSession的playback/longFormAudio以及远程播放、暂停、切歌、进度命令，符合基础资格；**旧的全局MPNowPlayingInfoCenter路径本身是有效API，不得把“没有MPNowPlayingSession”宣称为已证实的C根因。** 本轮改成显式单会话，是把播放器归属、命令和元数据统一到同一可观测对象，降低歧义。[MPNowPlayingSession](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession)

当前publish由前台同样运行的播放器观察/定时回调调用，未被background条件包围，不是“等到后台才注册媒体信息”。还必须区分：MPNowPlayingSession.isActive指该App的活动会话，不是可读取其他App的全局Now Playing身份接口，更不等于系统激活/签名验证成功。实际系统归属仍需系统日志与操作结果。

### 8. 切换、挂起、场景恢复

App的inactive并不等于background：拉下控制中心、系统弹窗都可能只经历inactive。只有真实background→active返回，且仍有当前曲目时，才恢复现有FullPlayer。不重建AVPlayer、不seek、不调用play、不抢夺其他App音频。传统API无法识别本次激活来自媒体岛还是App图标，因此两者采用同一返回目的地；此行为明确说明，不伪装成已捕获媒体岛点击来源。

### 9. iOS27新版NowPlaying框架是否适用

官方文档标注NowPlaying从iOS27.0引入，使用MediaSession/MediaSessionRepresentable、元数据及播放快照、结构化命令来发布本地媒体；还支持与本地播放不同的远程设备会话。[NowPlaying](https://developer.apple.com/documentation/nowplaying)、[发布媒体会话](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions)、[WWDC26](https://developer.apple.com/videos/play/wwdc2026/312/)

用户手机27.3不等于当前编译器有27 SDK。已完成Build23实际工具链为Xcode26.6 / iPhoneOS26.5；本轮保持iOS18+及现有稳定构建，不混合两套系统媒体发布链。公开MPNowPlayingSession从iOS16可用，适合当前AVQueuePlayer。将来升级27 SDK后可独立评估完整迁移；新框架并不等于获得任意控制媒体岛或修复SideStore安装身份的权限。iOS27发布说明中RemoteMediaSession的特定问题属于远程会话，不能套为当前本地播放器的根因。[iOS27发布说明](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)

### 10. Apple Music与第三方的边界

系统Music、订阅音乐访问与第三方本地音频并非同一产品权限。第三方应使用公开媒体会话，不复制系统App身份/私有entitlement，不绕过MusicKit、DRM或会员限制。普通系统Now Playing整合不是MusicKit订阅授权。本轮不要求新增付费接口、Live Activity扩展或私人证书。

系统用Bundle标识应用；签名、描述文件与实际Bundle身份需一致。未签名IPA的元数据只能证明构建输入，不证明SideStore签后安装、LaunchServices注册或手机运行身份。本轮不能在缺少重签产物/系统日志时认定“就是SideStore”；也不会硬编码或修改签名entitlement来猜测修复。[CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)、[Apple签名前缀诊断](https://developer.apple.com/library/archive/qa/qa1879/_index.html)

## REA真实执行与证据边界

- 实际调用REA 6.4.0的binary_session；Windows的native UI/Mach-O运行时工具不可用，Ghidra未配置。没有重复启动智能体或扫描其他平台。
- 对当前Build23 IPA真实执行open_binary / inspect_artifact，SHA256 `7e8efc21c734c6083ea305f9407372d9fd358e2dc2a69f09fe85b10a89b8a169`；证据 `ev_87e450f88ec37fb80066d1b4d332248bbd5eacaa6130dbd0de9db5ce2eaf9fb3`。这是归档静态证据，不是系统点击行为证据。
- 已导出 `../outputs/island-rea-evidence-initial.json` 并关闭目标。官方DocC JSON保存在外层 `outputs/island-apple-*.json`，区分静态文档/SDK可用性与真实运行结果。REA不能在本机替代Apple Music真机观察；Swift源码和后续XCTest由Codex执行并记录，不冒充REA反编译输出。

## 当前源码证据、修复与风险

| 文件/路径 | 审查结果 | 实施内容 |
|---|---|---|
| AudioEngine.init/configureRemoteCommands/publish | 单一原生引擎；旧全局命令/信息中心；有真实播放状态/封面/进度 | 单一MPNowPlayingSession绑定唯一player；同一session的命令与手动信息中心；记录资格和归属变动 |
| AudioEngine.recreatePlayer/resetMediaServices/shutdown | 播放器可重建；需保证新会话不保留旧player/命令 | 重建时解绑旧会话/命令再绑定新player；停止清元数据，销毁移除所有关联；不创建竞争播放器 |
| NativeRoot场景active → AppModel.resumeConnections | 仅重连服务，不恢复当前歌曲页，这是已确认的导航缺口 | 记录真实background，active时恢复现有FullPlayer；不改变暂停、进度、队列 |
| AppModel/NativeRoot/NativeAIConnection | 生产代码只有同一个AudioEngine；原生界面无WebView音频owner | 保持原生所有权及Go解析边界，不新增Web音频路径 |
| Info.plist/Build23实际包 | MusicDL、原Bundle ID、后台audio；SwiftUI WindowGroup，单场景 | 身份/签名配置不随意更改；仍需手机实际Build/签名/激活证据 |
| MediaSessionDiagnostics | 之前没有针对系统激活/归属的持久日志 | 仅事件变更写OSLog及Files可取的Diagnostics/media-session.jsonl；文件约128KiB有界，无歌名、凭证或URL |

## 验证计划与本轮状态

新增实际AVQueuePlayer/合成WAV测试：单会话、命令、真实播放/暂停元数据、停止清理、媒体服务重置解绑、后台返回不重建/不自动播放。现有真实键盘搜索UI更新为返回后显示FullPlayer，再收起回原搜索结果；既有后台/歌词/搜索/来源回归保留。

系统媒体岛探测使用SpringBoard公开可访问性目标；如果模拟器不暴露可定位的媒体岛，将明确skip并保留桌面截图，**不会用app.activate或猜测坐标冒充岛点击通过**。无论该探测结果如何，SideStore重签iPhone17/iOS27.3的轻点/长按、锁屏/控制中心仍需真机验收。

当前Windows没有Swift/iOS SDK；新增Swift代码尚待macOS真正编译/XCTest。Go/Node回归另记，不以其通过代替iOS测试。最终构建、日志与IPA核验完成后在本节追加。

阶段检查点：`1d5f2b52a3328768d33bedb93ca7b87f28937e9c`，[Build24实际运行](https://github.com/yann359/go-music-dl/actions/runs/42806577036)。Windows Go四包、Node6/6已通过，新增Swift/系统媒体探测以该运行终态为准，不把旧Build23当本轮包。

### Build24失败及据证调整

设备/模拟器编译成功，但原生运行失败，UI与IPA上传均未执行。真实错误为 `Cannot remove an observer ... MPNowPlayingSession ... currentItem ... not registered`（NSRangeException），包括原有播放器退出/重建用例。该问题来自本轮新增会话清理，不把它归为用户原有故障或简单归为模拟器不可用；原始日志在 `outputs/island-build24.log`，测试诊断artifact保留。

调整：整会话退出时清空元数据、关闭命令、断开delegate并释放会话引用，由会话自身生命周期完成观察者清理，不先逐个removePlayer再销毁会话。测试若主动持有旧会话，其player仍随它存活，这是引用所有权的预期；必须断言旧命令失效及元数据清空，而非人为要求一个仍被持有的会话清空其数组。原有失败用例全部保留，不用异常捕获、空catch或忽略KVO错误来通过。活动请求也限制到显式播放/资格变化，暂停和停止均记录实际状态事件。修订版需重新运行整个既有macOS验收。

## 真机取证步骤（不要求Apple密码或私钥）

1. 安装本轮包后在“文件 → 我的iPhone → MusicDL → Diagnostics”读取media-session.jsonl，可核对实际build/bundle/os。它才是手机运行版本证据，不能用源配置默认1代替。
2. 播放同一曲目，记下Home、轻点媒体岛、长按、控制中心点封面、图标返回的时间。日志对照scene-background / ownership-* / scene-active / player-restored。
3. 若点击没有scene-active而图标返回有，继续获取同时间SpringBoard/FrontBoard/RunningBoard/mediaremoted的系统Console或sysdiagnose，查看激活目标与拒绝原因。若已有scene-active则查UI导航；不要把签名猜测当结论。
4. 同机用Apple Music重复A/B/C，记录声音路由、是否有其他活动占岛。测试暂停恢复、前后台切歌、锁屏进度、长按控制及原搜索/换源；本轮没有强行改变A/B的显示规则。

### Build25证据与数值契约修正

[Build25](https://github.com/yann359/go-music-dl/actions/runs/42809023352) 执行62项原生测试，61通过、1失败、无上述KVO异常/测试进程重启。失败是暂停速率被`as? Float`读取为nil，不能据此推断整个Now Playing信息已清空；当前字段处于`[String: Any]`上下文，暂停分支字面量0与播放分支Float的动态类型可不同。将发布的0明确为Float，测试按MediaPlayer的数值契约读取NSNumber.floatValue，仍要求暂停速率为0、原生player.rate为0、停止清信息且命令禁用，未放宽或删除行为断言。该修订需要下一轮真实macOS验证；Build25无IPA。
