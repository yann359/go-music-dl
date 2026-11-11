# 媒体状态修复与主题颜色（2026-11-11）

## 范围与基线

开发前读取PROJECT_STATUS.md、实际设置/主题/播放源码及Git历史。基线28abc31（Build35代码91983c0），分支codex/media-repair-theme-colors。本轮不使用REA，不重做界面，不改变搜索、下载、来源、收藏、数据库或签名配置。

## 灵动岛修复

“我的→灵动岛修复”及“完整设置→灵动岛修复”均可进入原生Form。按钮启动真实检测，过程防重入，完成后分别展示检查、发现的问题、执行的修复、错误及限制，并可重新检测。无可修复异常时明确显示“未发现可自动修复的异常”，不声称控制灵动岛动画。

- 检查实际AVAudioSession类别、模式、共享策略、混音配置、输出线路，以及本App的激活调用/中断记录。旧SDK公开接口没有通用的实时isActive查询，不把MPNowPlayingSession.isActive当作音频激活证明。即使配置偏离，也不在检测中切换类别或重新激活正常音频；显示限制，留给正常手动播放入口处理。
- 读取当前会话自己的MPNowPlayingInfoCenter，与实际AVPlayerItem对应歌曲、缓存封面、真实时长、原生速率、暂停进度核对；播放中的elapsed可能是系统推算基准，不与不断前进的当前时间简单比较。准备中/定位中/中断中不发布未来曲目或猜测进度。
- 对确实不一致的静态信息恢复真实item元数据。系统信息偏差时，在同一会话发布一次当前真实快照，保留自动发布，不清空正在播放的信息，不切换发布模式制造显隐。回读仍不一致则显示具体字段错误，不假装成功。空队列且无播放意图的残留信息才可清除。
- 六个远程命令持有Apple返回的注册令牌，注册入口幂等；仅用这些令牌移除自己的异常绑定，不调用removeTarget(nil)。按真实item存在性恢复启用状态。公开API无法枚举系统或第三方的处理器，因此结果只声明本App持有的注册情况。
- 弱引用登记存活引擎与本引擎创建过的会话；只可关闭本引擎已退休、未播放且不含当前player的旧会话发布。多个活跃引擎或当前会话播放器异常只报告，不停止、不removePlayer、不重建。保留此前修复的KVO生命周期约束。
- 当前项目未接入ActivityKit、没有已知ActivityAttributes类型，不伪造全局“Live Activity数量为0”的检测。Apple的活动列表按本App具体Attributes类型查询；不结束其他App或未知活动。
- 一次修复没有play、pause、seek、setActive、rebuild调用。回读期间若歌曲、队列、速率、播放意图、中断或定位发生变化，停止旧状态核验并提示重新检测，不回写旧歌曲。
- Diagnostics记录repair-started/check/action/completed/failed、结果代码、计数和原生引擎状态；不记录歌曲、封面字节、播放URL、账号或凭证。复用有界日志。

官方依据：[AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)、[MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)、[会话自动发布](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/automaticallypublishesnowplayinginfo)、[真实item信息](https://developer.apple.com/documentation/avfoundation/avplayeritem/nowplayinginfo)、[进度基准推算](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime)、[MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)、[注册令牌](https://developer.apple.com/documentation/mediaplayer/mpremotecommand/addtarget(handler:))、[精确移除令牌](https://developer.apple.com/documentation/mediaplayer/mpremotecommand/removetarget(_:))、[按类型活动列表](https://developer.apple.com/documentation/activitykit/activity/activities)。

## 独立主题颜色

新增AppearanceSettings集中管理，沿用原music.appearance键（system/light/dark）并新增music.themeColor；既有明暗选择迁移不丢失。八色为Apple红默认、海洋蓝、薄荷绿、梦幻紫、落日橙、樱花粉、极光青、石墨灰。原生外观Form提供圆形色卡、对勾、VoiceOver选中值、即时预览与恢复默认确认。

主题通过环境值和系统tint传播；按钮、导航选中、播放/暂停、进度条、歌词/队列选中、搜索来源选中、账户状态及AirPlay活动色共享同一配置，不逐页硬编码。每种主题有浅/深两套色值，填色按钮与色卡对勾使用对应的浅/深前景色。保留原Liquid Glass材质、模糊、透明度与系统交互。

恢复默认只写入上述两个外观键，不删除UserDefaults域，不操作文件、数据库、缓存、歌曲、下载或账号。持久化与主题选择即时生效。

## 修改文件

- AppearanceSettings.swift（新）：模式/八色/持久化/外观页/环境值。
- MediaRepair.swift（新）：检测报告、字段比对与原生修复页。
- AudioEngine.swift：安全检测、持有注册的幂等绑定、弱引用会话范围、更新采样和激活证据；不替换播放管线。
- NativeRoot.swift、ProfileViews.swift、DesignSystem.swift、PlayerViews.swift、NativeScreens.swift、AccountViews.swift：入口及主题传播；既有布局保留。
- MediaSessionTests.swift、AppearanceSettingsTests.swift（新）、NativeVisualTests.swift：播放连续性、异常恢复、24种组合、持久化与新UI流程。
- verify-ipa.py、test_ipa_verifier.py（新）、ios-native.yml、.gitignore：ZIP交付检查与负例回归。

## 测试与交付（待macOS结果补录）

Windows：Node6/6，IPA格式测试7/7；八色在明暗画布及填色前景的采样文字对比度均至少4.5:1。新ZIP核验器也成功复查旧Build35，未改变旧包。原生编译/XCTest/UI需macOS流程，不把Windows检查当iPhone实测。

新测试覆盖实际AVQueuePlayer播放修复不换player/session、不丢队列、不回退进度、不多激活；暂停时修复错误元数据/禁用命令/关闭自动发布仍保持暂停；准备中与中断期间不抢播；重复注册无增长；关闭引擎明确失败；播放时间基准不误报。外观测试覆盖全部24种组合保存恢复、旧键迁移、未知值回退及恢复默认只触及两键。UI增加八色×三模式、重启保存/恢复默认、修复前后播放/暂停状态与截图。

IPA检查在CI与下载后都运行：ZIP CRC、标准单卷非加密ZIP、唯一条目、无路径越界/反斜杠、无ZIP64/异常尾数据、store/deflate压缩、Payload/MusicDL.app、Info.plist、arm64 iPhoneOS Mach-O、依赖与资源、原bundle/build/hash和匹配源码。七项负例包含截断、HTML伪IPA、重复路径、错误Payload、非兼容压缩、附加尾数据；不能把这些检查称为LCSign实际安装通过。

## 系统限制与下一步

灵动岛显示和Home过渡由iOS执行；本按钮只修复能确认的媒体同步异常。实时音频激活、全局媒体归属、未知活动及外部指令处理器不可用现有兼容公开接口完全检查。锁屏/控制中心、真实后台、灵动岛轻点/长按、SideStore/LCSign重签和用户iOS27.3需要新IPA真机验收，不用模拟器skip或静态截图代替。
