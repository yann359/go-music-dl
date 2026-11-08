# iOS 原生播放审计与验收记录

日期：2026-11-08（北京时间）。基线提交：`119f1c143a626959e56cc91271d1cbb851952197`。
目标仓库：https://github.com/yann359/go-music-dl

## 状态与范围

这是第一阶段后台播放预览版，**不是已完成的原生 UI 正式版**。
必须先通过真机 30 分钟后台及连续三首验收，才能开始第二阶段整体界面替换。
截至建立本记录时，没有连接到用户的 iPhone，也没有真机测试证据。
用户提供设备：iPhone 17，iOS 27.3；旧文件名 `music-dl-ios-unsigned.ipa`。
这些信息来自用户陈述，尚未通过设备连接核验；旧文件名不能识别唯一构建提交。

Fork 的 `main` 与基线一致；当前 GitHub 连接报告 `push/admin=true`。
Fork 建立时没有 Actions 运行记录，不能据此证明用户现有 IPA 的构建来源。
请用旧 IPA 的下载链接、构建提交和手机 App 版本做最终比对。

## 修改前代码审计

| 项目 | 证据 | 结论 |
|---|---|---|
| 容器 | `desktop_app/main.go`: Gio + giowebview；启动 appshell 服务 | 现有 iOS 界面是 WKWebView 网页 |
| 音频 | `app.js`: APlayer，`buildStreamURL()` 指向 `/music/download?stream=1` | 当前播放和自动切歌依赖 JS 与本机 HTTP |
| iOS 平台实现 | `desktop_app/storage_permission_other.go`: `!android`，播放相关函数全部为空 | 没有原生 iOS 音频会话及系统控制实现 |
| 生命周期 | `desktop_app/main.go`: 根据长帧间隔推测恢复，可能重载 WebView | 不是可靠的原生音频状态来源 |
| Info.plist | `package_ios.sh`: 只增加 ATS/本地网络字段 | 没有 `UIBackgroundModes=audio` |
| 编解码 | `core.PreparePlaybackSource` | 已有汽水/咪咕解密，可直接复用 |
| 构建 | `.github/workflows/ios.yml`: macOS + gogio | 保留旧流程，新增独立 native 流程 |

## 第一阶段结构

```text
原网页功能 → WKWebView bridge → Swift AudioEngine → AVQueuePlayer → 沙盒音频文件
                                     ↓
                           MPRemoteCommandCenter / Now Playing
                                     ↓
                           AVAudioSession(.playback)

准备音频：Swift → C ABI → Go 原音源解析/换源/解密
                         ↓
             URLSession 携授权头取回音频 → 沙盒缓存

本机 HTTP 服务：只保留浏览、搜索、下载、设置等原有功能；不传送原生播放音频。
```

缓存当前及后两首；原生队列在曲目结束时前进并补充下一首。
播放不依赖网页定时器、Gio 帧或 `/download` HTTP 流。
Native 队列状态返回网页；恢复前台时拉取真实状态。WebContent 崩溃只恢复浏览层。
Cookie/带签名音源 URL 只在原生层传递，不注入 JS，不写入日志。
本阶段优先完整缓存再播，因此起播延迟高于流式播放；不是无限离线队列。

## 功能矩阵（保留不等于已验收）

| 功能 | 原实现/入口 | 第一阶段处理 | 真机状态 |
|---|---|---|---|
| 多平台搜索 | `/search`，core 各平台 | 原样保留网页/Go | 待测各平台 |
| 手动换源 | `/switch_source` | 原样保留 | 待测 |
| 失败换源 | 原匹配与校验函数 | 原生失败时经 C ABI 复用匹配，一次后明确失败 | 待测匹配正确性及授权 |
| 播放 | APlayer/HTML Audio | iOS 目标改为 AVQueuePlayer，其他目标不改 | 待测 |
| 下载/队列/导出 | `/download`、`/api/downloads/queue` 等 | 原网页保留；WKDownload 导出到文件/分享 | 待测大文件/后台下载 |
| 歌单/收藏 | collection 路由及 SQLite | 不更改原数据结构 | 待测 |
| 专辑/排行榜 | `/album`、toplist 路由 | 原样保留 | 待测 |
| 歌词 | `/lyric`、KaraokeLyrics | 原网页歌词读取原生进度 | 待测逐字歌词 |
| 本地音乐 | local_music 路由 | 复用路径检查；原生读本地文件 | 待测导入/删除/锁屏 |
| 登录/Cookie | auth/qr_login 路由 | 保留原桌面壳的本机信任模式、平台登录流程 | 待测登录弹窗与扫码 |
| WebDAV | core/webdav.go | 原样保留上传功能 | 待测连接/上传 |
| 无损 | 原下载解析/解密 | 缓存原始音频字节，不转码；AVFoundation 不能解码时换源/报错 | 待测 FLAC/ALAC/不同采样率 |
| AI API | `/api/ai/*`，SSE 控制网页 | 原接口保留；网页前台控制桥接原生 | 后台 SSE 指令暂未原生化，待解决 |
| 定时播放/视频生成等附加功能 | 原 app.js/videogen.js | 入口保留；JS 定时不承诺后台执行 | WebAudio 可视化/视频导出待适配原生音频 |
| 原 iOS 用户数据 | Gio DataDir + 网页存储 | 预览默认独立 Bundle ID 并排安装，保留旧 App | 尚未实现跨 App 数据迁移 |

## 测试记录

| 测试 | 状态/证据 |
|---|---|
| JS 原生桥接 6 项：队列先于播放、原生同步不回环、切歌/模式、清空/暂停、WebView 恢复、缓存等待可暂停 | 本地 Node 测试 6/6 通过 |
| 原 app.js JavaScript 语法 | `node --check` 通过 |
| Go 输入解析、授权元数据保留、本地路径穿越 | 本地通过 |
| 原 web/appshell/core 回归测试 | 本地通过；云端运行 42482135341 通过 |
| Spotify 适配器授权/元数据/分页主机检查 | 本地 4 项通过 |
| iOS 编译与 unsigned IPA 打包 | [运行 42482135341](https://github.com/yann359/go-music-dl/actions/runs/42482135341) 通过，基于 01b8c66；补强后的最终构建需另行核对 |
| iOS 模拟器三曲/中断/耳机断开测试 | 同次运行 3 项通过；新加队列替换及音频服务重置测试待下一次云端运行；不是物理设备测试 |
| 真机桌面后台 ≥30 分钟 | **未执行** |
| 真机锁屏/息屏 ≥30 分钟 | **未执行** |
| 真机连续三首、曲目边界 | **未执行** |
| 控制中心、锁屏和 AirPods 指令 | **未执行** |
| 来电、Siri、拔耳机与恢复 | **未执行** |
| 各音源失败/过期/弱网/断网 | **未执行** |

## 真机验收步骤

1. 安装 `MusicDL Preview`，保留原 MusicDL，使用有权播放的三首歌曲建立队列。
2. 前台确认播放、进度、歌词、下一首和暂停均正常，再开始后台测试。
3. 播放后返回桌面，计时至少 30 分钟；让队列跨过至少三首，记录每次曲目边界时间、停顿及音源。
4. 锁屏/息屏再测至少 30 分钟。用锁屏与控制中心执行播放、暂停、上一首、下一首和进度拖动。
5. 用 AirPods 测播放/暂停/切歌、摘下/重新连接。断开输出设备必须暂停，不能突然从扬声器外放。
6. 接听真实来电并结束：只有系统允许恢复且用户没有主动暂停时才恢复；再测通话中手动暂停不恢复。
7. 后台切过三首后回到前台，检查歌曲、进度、暂停状态、歌词和队列不倒退、不重播。
8. 分别测本地文件、网易/QQ/B站/汽水/咪咕等已授权音源、无损文件和不可用音源；记录换源结果。
9. 填写设备型号、iOS/SideStore 版本、IPA SHA256、构建提交、测试开始/结束时间以及异常；没有这些证据不记为通过。

## 构建与安装

工作流：`.github/workflows/ios-native.yml`。macOS 上构建 Go iOS C archive，再通过 XcodeGen/Xcode 编译 Swift 原生目标。
产物：`music-dl-ios-native-unsigned.ipa`、SHA256、源提交、完整源代码 ZIP、AGPL 与第三方许可证。unsigned 包必须由 SideStore 重签。
默认 `com.guohuiyuan.musicdl.nativepreview`，显示名 MusicDL Preview；不要为覆盖旧版而擅改 ID。
下载 Actions 的 `music-dl-ios-native-unsigned` artifact，解压后在 SideStore 的 My Apps 中通过 `+` 导入 IPA，使用已有的签名流程安装。
若无法安装，保留 SideStore 错误原文，不删除旧版或其数据来排障。

## 第二阶段与未解决问题

- 真机验收是当前硬性关卡。尚未开始将四个页面替换成 SwiftUI；不以 CSS 模糊宣称 Liquid Glass。
- 后续采用系统 `TabView`（发现/搜索/音乐库/我的）、原生迷你播放器、全屏播放器、原生动态歌词、封面过渡、深浅色和 Safe Area。iOS 26+ 使用系统 Liquid Glass；低版本原生降级。
- 首次完整下载的延迟、网络/电量开销和缓存滚动策略仍需实机评估；单曲上限 512 MB。
- 应用被用户强制退出后不会继续播放；系统后台资格来自真实可听音频，不使用静音保活。
- 部分格式/编码 AVFoundation 可能不支持。不得把“保留无损原始字节”描述成“所有无损格式均播放通过”。
- 背景中所有预加载曲目耗尽、音源解析很慢时仍可能间断，需要实机数据决定进一步预取/流式缓存设计。
- 旧 Gio 应用的持久化路径及网页存储需独立迁移方案；预览并排安装不改动旧 App 数据。
- AI 后台 SSE 控制、WebAudio 视频可视化及所有原功能的真机回归仍待完成，不能记为完整兼容。
- 上游基线引用不存在的 `music-lib/spotify`，导致首轮编译失败；新增 `internal/spotify` 官方 API 适配器修复该缺口，保留各工厂入口。Spotify API 仅返回可授权的 preview，不支持完整音频或歌词；部分目录端点因账号/API 规则不可用会明确报错，尚未做授权账号实测。原 Spotify 测试仅调整导入路径，未删除断言。
- iOS ATS 对使用 HTTP 的原音源仍有全局兼容例外；不把 HTTP 宣称为安全传输。后续需逐平台收敛为 HTTPS/精确域名例外。
- 分发需附带 AGPL 对应源码、许可证与第三方声明，使用者需持有平台和音乐的相应授权。

参考：Apple [后台音频类别](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback)、[AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)、[系统播放控制](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)、[原生 Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)。
