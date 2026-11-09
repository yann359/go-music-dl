# 后台音频阶段记录（2026-11-09）

本轮按用户最新指令只处理音频回归和结果保存；仅主智能体，不开始下一轮 UI 开发。

## 已有架构与本轮修复

已有代码使用 SwiftUI + Go C ABI + AVQueuePlayer。`AudioEngine.activate()` 使用 AVAudioSession `.playback` / `.longFormAudio`；`Info.plist` 已声明 `UIBackgroundModes(audio)`。播放器读原生缓存文件，队列、切歌、系统媒体控制和来电恢复不依赖 WebView JavaScript 或 loopback HTTP 音频流。未发现退到桌面或界面失去焦点即暂停的 SwiftUI 处理。该架构具备实现后台音频的条件，无需更换框架。

本轮修复并提交于 `97b36c9c39562dfb9376b2497e98d09763ab3744`：

| 文件 | 修改目的 |
|---|---|
| `ios/MusicDL/AudioEngine.swift` | 换源读取 AVPlayer 实际时间/尚待执行的跳转；AVPlayerItem 就绪后再跳转，避免新文件还未就绪时丢失进度；保留暂停意图和其余队列 |
| `ios/Tests/AudioEngineTests.swift` | 等待真实就绪/跳转结果，验证换源前后都保持 0.5 秒进度、暂停和其余歌曲；不降低原断言 |
| `ios/MusicDL/NativeAppModel.swift` | 原生播放状态串行上报并合并中间进度，避免快速暂停被节流丢弃、旧请求覆盖新状态 |
| `ios/Tests/NativeBridgeIntegrationTests.swift` | 真实启动嵌入式 Go 服务，验证原生 SSE 连接及音量命令往返；保留收藏增删测试 |

这次修复针对换源、状态同步和恢复可靠性，不代表已重现并证实修复用户手机上每一种退后台中断。现有系统控制、中断/路由处理及 UI 页面均保留，没有新增静音循环等保活方式。

## 实际测试结果

对应代码：`97b36c9`。成功构建：[GitHub Actions 42540853672](https://github.com/yann359/go-music-dl/actions/runs/42540853672)。macOS runner，Xcode 26.6，iPhone 17 Pro Max / iOS 26.5 模拟器；不是用户的 iOS 27 真机。

- Go 回归通过：`internal/web`、`internal/appshell`、`core`、`internal/spotify`；Windows 同时检查 `internal/cli`、`cmd/music-dl` 通过。
- 原 Node 桥接测试 6 项通过。
- 原生单元/集成测试 **17 项全部通过**，其中音频引擎 **6 项全部通过**：换源保留暂停和进度、媒体服务重置保留暂停、耳机路由移除后暂停、丢弃过期队列准备、三段音频推进、用户在中断期间暂停后不自动恢复。
- 实际 Go 桥接、SQLite 收藏增删、原生 SSE/音量往返通过。
- 收窄任务前已经启动的同一次工作流另有深浅色 UI 自动化 2 项通过。本阶段没有据此进行新 UI 开发，也不把它计作后台播放证明。
- 之前失败运行 `42539762359` 为 17 项中 1 项失败（换源后进度变零）；保留失败记录，修复后同一断言通过。

音频测试使用短合成 WAV；三段推进测试只证明原生队列会进入第三段，**不是三首完整真实歌曲播放完毕**。中断/耳机用例向系统通知中心注入通知，不等于真实来电或 AirPods 验收。当前没有自动化点击系统锁屏/控制中心按钮的结果。

## 安装与剩余验收

[unsigned IPA、对应源码与许可证下载](https://github.com/yann359/go-music-dl/actions/runs/42540853672/artifacts/13641678130)：下载 artifact ZIP，解压后在 SideStore 导入 `music-dl-ios-native-unsigned.ipa` 并重签。新 Bundle ID 为 `com.guohuiyuan.musicdl.nativedesign`；旧 Build 5 IPA 保留，用户现装 IPA 仅有文件名，尚无设备侧构建号证据可精确对应。

已下载并检查 Build **11**：arm64、后台 `audio` 声明、无签名目录、对应源码 SHA 正确；IPA SHA256 为 `c2fbcaf6f09d34484dc6f889635e5cb975e816a9ce768c4faddbeda6fefd9303`，与构建校验文件一致。本机位于 `../outputs/ios-audio-stage/music-dl-ios-native-unsigned.ipa`；旧 Build 5 文件哈希未变。

本次没有连接 iPhone，以下项目全部待实际设备执行并填写结果：

1. 用有权播放的真实曲目建立至少三首的队列，开始播放后退回桌面，再锁屏；总计至少 30 分钟，记录中断时间和是否三首完整连续播放。
2. 锁屏和控制中心执行播放/暂停、上一首/下一首、拖动进度；重新打开 App 核对状态。
3. AirPods 操作、摘下/断开耳机、来电接听/结束，并核对用户主动暂停后不会误恢复。
4. 在锁屏切歌、不同来源、授权失败、换源、弱网/断网下核对真实行为；无损格式另测设备解码。

没有这些记录，不能写“已通过 30 分钟后台播放”或“已修复所有真机中断”。本阶段保存后停止，后续 UI、完整功能迁移与设备验收等待用户指定。
