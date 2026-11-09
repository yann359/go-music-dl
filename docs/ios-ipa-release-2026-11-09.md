# iOS Release IPA 打包记录

日期：2026-11-09（北京时间）。代码基线 `52acc6e`，打包分支 `codex/ios-ipa-release`。

## 构建方法

使用现有 `.github/workflows/ios-native.yml`，GitHub Actions macOS Runner 执行真实 Xcode Release iPhoneOS 编译。Go 以 `c-archive` 静态链接进 SwiftUI App；XcodeGen 生成工程，原有图标生成与第三方许可证脚本保留。没有 Windows 版 Xcode，也没有把任意 ZIP 改后缀充作 IPA。

首轮记录：[Build 13](https://github.com/yann359/go-music-dl/actions/runs/42629940184)，源码 `1f80c29`。Release 编译与包内验证已成功，48 项原生单元测试通过；首轮 UI 的歌词用例误以 StaticText 查询可跳转的歌词 Button，导致 4 个断言失败，其余 4 个 UI 用例通过。已从截图与界面层级确认歌词内容及重复副歌正确，仅修正测试定位；该失败构建未上传 IPA。另补充真实启动 UI 检查：不启用界面样例数据，走内嵌 Go / SQLite / 原生页面路径，已在最终 Build 14 中通过。

## 签名与兼容

- 目标：未签名、未加密 iPhoneOS arm64 Release IPA，供 SideStore / AltStore Classic 重签；不是可直接点击安装的已签名包。
- Bundle ID：`com.guohuiyuan.musicdl.nativedesign`；显示名及 App ID 名称继续使用 `MusicDL`，避免历史中文 App ID 名称错误。
- 最低版本：iOS 18；iOS 26+ 使用原有 Liquid Glass，较低支持版本沿用原兼容路径。实际设备安装与音频仍需真机验收。
- 保留后台 audio、系统音乐访问说明、Spotify 回调 scheme、文档导入和原数据存储。
- 不要求 Apple 密码/私钥/Provisioning Profile；如需 MusicKit 官方服务，仍须与实际签名 Bundle ID 匹配的开发者配置。普通个人侧载签名不能据此假定有 MusicKit 权限。
- Spotify 继续保持用户之前的待配置状态，不替用户创建账号、购买 Premium 或更换公开 Client ID。

## 包内核验

新增 `ios/scripts/verify-ipa.py`，检查 ZIP 完整性、Payload、Mach-O 可执行文件、arm64/iPhoneOS 平台、最低系统版本、未加密/无旧签名、Bundle 元数据、资源与动态依赖。必须存在 Assets.car、LICENSE、NOTICE.md、ThirdPartyNotices.txt；缺失的非系统框架会报错。CI 输出核验 JSON，下载后再次验证实际 IPA 并对比 SHA256。

## 本地服务边界

核心启动、来源目录、公开搜索、收藏/歌单、本地数据与原生音频在 iPhone 进程内工作，不需要 Windows 电脑或 Node 常驻服务。AI 的可选连接仅在 iPhone 自身回环地址，未开放公网。

历史汽水会员整曲路径使用桌面客户端 bdms.node 与 Node 签名模块，iOS 不具备此桌面环境；此路径不能宣称可用，按来源实际公开音频或已有合法能力处理。部分导出/视频处理依赖外部 FFmpeg，也不能因 IPA 编译成功而宣称 iOS 支持。此次不部署签名服务器，不引入付费 API，不改现有配置。

Apple 兼容目录与 5sing 个别歌单的已知接口限制仍保留；13 个来源入口不等于所有受授权限制的操作都通过。

## 安装与数据

最终 IPA 应通过原先使用的 SideStore / AltStore Classic、原 Apple 账号进行覆盖签名安装，保持一致的应用标识；不要先卸载旧版。若工具要求删除旧 App，先停止并导出需要的数据。安装、信任或开发者模式按侧载工具实际提示完成，Apple 凭证仅在工具中输入。

参考：[GitHub 产物下载](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)、[SideStore 官方安装说明](https://docs.sidestore.io/docs/installation/install)、[AltStore Windows 安装说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)。

## 真机剩余验收

签名安装后检查：真实来源搜索和有权播放的歌曲、歌词同步、歌单/缓存、原有历史与收藏；暂停后后台 2/5/15 分钟恢复、锁屏 30 分钟、控制中心/耳机按钮、网络切换、蓝牙和音频中断。模拟器合成音频与 UI 样例不能替代这些结果。详细步骤保留于 `docs/ios-source-recovery-stability.md`。

第二轮：[Build 14](https://github.com/yann359/go-music-dl/actions/runs/42633849708)，源码 `2f0b7d4`，包含歌词按钮查询修正和真实启动 UI 检查；Release、包内核验、48 项单元与 6 项 UI 全部通过。

## 最终结果：已成功交付 Build 14

- [成功运行 42633849708](https://github.com/yann359/go-music-dl/actions/runs/42633849708)，源码 `2f0b7d43d0c80f0d1ac27d3c2faf80b1946436d8`，保留 `52acc6e` 修复。
- **真实 iPhoneOS Release 编译成功**：macOS-26、Xcode 26.6 (17F113)、SDK 26.5、Go 1.26.1；arm64，最低 iOS 18.0。使用系统框架，未发现缺失非系统动态依赖。
- **未签名、未加密**，无签名目录或 Provisioning Profile，实际可执行文件为 Mach-O MH_EXECUTE。SideStore / AltStore Classic 仍需使用用户自己的 Apple 账号在本地重签；没有执行真实手机安装，不能写成“真机安装已通过”。
- 本地 IPA：`C:/Users/Administrator/Documents/ChatGPT/apple music/outputs/ios-release-build/build14/music-dl-ios-native-unsigned.ipa`。
- [云端交付包（IPA、对应源码、许可证与核验 JSON）](https://github.com/yann359/go-music-dl/actions/runs/42633849708/artifacts/13684521858)，19,093,394 字节，云端保留至 2026-12-09。下载云端 artifact ZIP 后先解压，取真正的 `.ipa` 导入侧载工具；不能把外层 ZIP 改后缀。
- IPA：14,257,557 字节（约 14.3 MB）；版本 1.0.0 / Build 14；Bundle ID `com.guohuiyuan.musicdl.nativedesign`，名称与可执行文件均为 `MusicDL`。
- IPA SHA256：`836d7f43ef0de2d7b801b18b8e8775f1785fb9656b48762cd60196ed0b65994c`。
- GitHub artifact ZIP SHA256：`e0ad961b50c57a065ec4f6bac5187e0415065f716814f9d007fdeaeea68d28c2`；与 Actions digest 完全一致。
- 本机重新解压核对：IPA 校验文件一致，源码提交一致，本机包内核验结果与 CI JSON 完全一致；源代码 ZIP 完整且含原生客户端、嵌入服务与来源核心。未改动下载后的 IPA。
- 本地核验文件：`../outputs/ios-release-build/build14/local-verification.json`；原始日志：`../outputs/ios-release-build/build14.log`。外层 GitHub archive 和对应源码 ZIP 同目录保留。

### 实际验证范围

1. macOS Go 四包及 Node 原生桥接 **6/6** 通过；未重复宣称未执行的真实来源整曲验证。
2. iPhone 17 Pro Max / iOS 26.5 模拟器，**48/48 原生单元测试通过**。包括 AudioEngine 的 9 项、歌词、缓存/服务状态、官方授权流程，以及真实 Go C ABI / SQLite / 13 来源集成。
3. 人工抽查本轮浅色发现、深色播放器、真实来源目录截图，保留原有布局及系统玻璃效果；截图在 `../outputs/ios-release-build/build14/screenshots/`。
4. **6/6 UI 测试通过**：全部账号入口、空播放器与冷启动、暂停后 Home/返回、歌词署名与重复副歌、深浅色导航/播放器，以及新增的真实启动测试。
5. `testRealNativeStartupAndRestoredSourcesWithoutPreview` 使用真实 Go / SQLite / 来源目录，不启用 `--ui-testing` 样例数据，实际通过（约 15.4 秒）；其余样例 UI 截图用于设计/交互回归，不能当作真实音源播放证据。
6. 原生音频单元测试使用合成 WAV，中断通过通知注入验证；不等于 iPhone 上的真实来电、AirPods、锁屏 30 分钟或完整网络歌曲。
7. 本轮没有改变 AudioEngine、音乐来源、详情缓存、歌词解析、Liquid Glass 设计、Info.plist 与数据库结构；AppModel 仅新增 Debug 启动检查开关，正常 Release 行为保持不变。

### 首轮失败的实际原因

Build 13 已生成真实 Release IPA并通过 48 原生测试，但 5 项 UI 中歌词用例的 4 个断言失败。保留的 UI 层级与截图清楚显示：`作曲：周杰伦`、`编曲：林迈可` 均只有一行，`重复副歌` 两行；它们是可点击定位播放进度的 **Button**，并非 StaticText。修正为按歌词按钮的可访问标签查询，保持全部断言，不删测试、不改 UI、不伪造歌词。最终 Build 14 的全部测试重新通过，正式交付只使用 Build 14。

### 尚未完成的外部验证

没有连接用户 iPhone，也没有使用用户 Apple 账号签名。用户须在 SideStore / AltStore Classic 以原账号覆盖安装，确认现有数据、真实歌曲与账号权限、iOS 27 后台/锁屏/蓝牙/网络切换/中断。具体步骤见前文。Apple Music 签名服务资格、Spotify 待配置、5sing 个别歌单、汽水桌面签名及外部 FFmpeg 功能的限制保持真实提示，不能因编译成功而改成“所有功能全部通过”。

最终进度与报告属于构建结束后的文档更新；IPA / 源码快照对应上方已验证的 `2f0b7d4`，不会为文档结果更新重复构建或修改成品 IPA。
