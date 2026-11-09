# 项目持续状态

更新：2026-11-09（北京时间）。每次开发结束或可控中断前更新本文件；以下状态只描述已验证事实。

## 目标与核心需求
- 将 Go Music DL 改为高品质原生 iOS 音乐客户端“澄音 / MusicDL”，面向 iPhone 17 Pro Max / iOS 27。
- 原生 SwiftUI TabView、NavigationStack、Sheet 与 iOS 26+ Liquid Glass；主要界面不使用 WebView。
- 保留所有原音源、搜索、歌单/专辑/榜单、收藏、下载、歌词、本地音乐、账号 Cookie、WebDAV、AI API 和设置。
- 原生后台音频、锁屏/控制中心/耳机控制；真机测试与模拟器测试分开报告，禁止虚报。

## 当前架构
- Go 音乐核心与 SQLite 保持原有结构；新 `MusicDLRequest` C ABI 提供原生 JSON 功能接口。
- 前台管理功能可复用固定 loopback JSON 路由；音频解析经 C ABI，音频由原生文件缓存与 AVQueuePlayer 播放，不依赖网页 JavaScript 或本机 HTTP 音频流。
- Swift `NativeClient` 负责结构化数据与错误；`AudioEngine` 是唯一播放状态所有者；`AppModel` 连接原生 UI 与 AI SSE 控制。
- 原生设计使用独立品牌、系统字体、深浅色与安全区域。REA Windows 仅用于可用的静态包检查；没有观察 iPhone Apple Music 内部源码/动态界面。

## 分支与已保留版本
- 当前开发分支：`codex/ios-native-redesign`，基于 `9b18983`。
- 上阶段通过的 Build 5：源提交 `a7c784c8ffd378418bdde33f65da746e71b58ee2`。
- IPA：`../outputs/ios-build5/music-dl-ios-native-unsigned.ipa`。
- SHA256：`72f1dc69ef597258df90f3a526961c01b6c6e7a1d64ea8046ef6069a8f8781c7`。
- 上阶段工作流：https://github.com/yann359/go-music-dl/actions/runs/42483202980 。

## 已完成与代理成果
- 上阶段原生缓存播放、音频会话、系统远程控制、中断/路由处理与后台声明。
- REA doctor/capabilities 已运行，结果摘要 `docs/rea-ios-readiness.json`；原 Build 5 IPA 已通过 REA 静态包检查。
- `docs/ios-native-design.md`：公开参考、证据边界、字体间距/交互/动效/状态规范。
- `docs/ios-native-feature-matrix.md`：14 音源与完整功能保留清单。
- 后端代理：`internal/web/native_client*.go`、`ios/bridge/main.go`、`Bridge.h`。
- 客户端代理：`NativeClient.swift`、`NativeClientTests.swift`，包含显式 UI 测试样例模式。
- 主代理：`DesignSystem.swift`、`NativeAppModel.swift`、`NativeRoot.swift`、`NativeScreens.swift`，以及 AudioEngine 可观察状态/队列操作。

## 上次中断点（已恢复）
- 已补齐全屏/迷你播放器、LRC 跟随与点击跳转、队列排序/移除/清空、系统输出选择器。
- 已补齐我的、Cookie/二维码、完整设置/WebDAV、音源浏览/分类/榜单和用户平台歌单。
- 原管理界面 WebView 已从 iOS UI 目标中移除；不改动原网页/Android 页面。
- CI 已改为 macos-26，并校验 SDK >=26；加入原生页面深浅色截图和无 WebView 断言。
- 第二轮云端运行 `42537993412`：Go 检查、原生 release 编译、模拟器单元测试通过；UI 自动化及测试报告上传失败，最终日志归档未结束，具体原因待查。不能记为 UI 验收通过。
- 补充专辑/原始链接/VIP元数据保留、失败与空结果区分、当前换源保留队列/进度、本地及锁屏封面；等待最终 macOS 重验。
- 已将 UI 检查设备限制为 iOS 26+，优先 iPhone 17 Pro Max；使用模拟器 ad-hoc 签名；播放器断言改为可见的收起按钮，避免依赖 SwiftUI 容器的可访问性类型。
- 已取得第二轮日志：Xcode 26.6；13 项原生单元测试通过；两项 UI 测试均找不到迷你播放器的可访问性标识；报告上传为 ArtifactService/CreateArtifact 请求超时（不是已证实的存储配额问题）。将展开区域改为有明确标签的原生 Button，并移除外层重复标识，等待重验。

## 测试与已知限制
- 重设计首轮 macOS 运行 `42537618882` 在原本地音乐测试清理阶段失败：索引异步写与 SQLite 关闭竞争。已增加索引任务收尾等待、隔离新原生测试数据库；原断言保留。定向测试连续 5 轮通过，等待全量与 macOS 重验。
- Build 5：Go 回归、6 项桥接测试、5 项原生模拟器测试通过；Windows/Linux 5 组构建通过。
- 本轮 Windows 实际运行：`go test ./internal/web ./internal/appshell ./core ./internal/spotify ./internal/cli ./cmd/music-dl` 全通过；原 Node 桥接 6 项通过。
- 新增 Swift 客户端 5 项测试、歌词解析 3 项测试与原生 UI 截图测试，等待 macOS 执行。
- 后续新增测试：全部来源失败不伪装空结果、专辑/授权元数据保留、手动换源保留暂停与队列、真实 C ABI 启动及收藏增删。新增测试需以最终云端运行结果为准。
- AI 状态上报改为串行合并，避免快速暂停被节流丢弃或旧状态覆盖新状态；C ABI 集成测试增加真实原生 SSE 连接与音量指令往返。
- 第五轮 `42539762359`：Go/release 编译成功，17 项原生测试中 16 项通过；真实 C ABI 收藏增删通过，手动换源的暂停进度断言失败，UI 阶段未运行。报告上传已成功，旧上传超时并非持续阻塞。
- 针对失败修复：换源读取 AVPlayer 实际时间或待执行跳转，跳转等待 AVPlayerItem 就绪再执行；测试等待明确就绪/跳转结果，保留原进度断言。待下一轮验证。
- Windows 无 Xcode/SwiftUI 编译器；iOS 编译、模拟器与截图必须在 macOS Actions 执行。
- 无 iPhone 连接；30 分钟后台、三首完整真实歌曲、真实来电及 AirPods 测试未执行。
- 音源可达性、账号权限、格式解码、首曲缓存延迟仍需实测；不绕过版权或付费授权。

## 本次恢复与下一步
1. 已检查当前 Git 历史、目录、全部未提交文件与代理成果；未重建项目。
2. 创建本文件以固定恢复点。
3. 已补齐缺失原生页面并通过 Go/Node 检查；构建独立品牌图标与新的 `com.guohuiyuan.musicdl.nativedesign` 安装标识，与旧预览版并排。
4. 正在提交到开发分支以执行 Xcode 26+ 构建，修复实际编译错误并运行原生测试/截图。
5. 验证 unsigned IPA、更新功能矩阵和测试记录，再交付安装与真机验收步骤。
