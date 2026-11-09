# iOS Release IPA 打包记录

日期：2026-11-09（北京时间）。代码基线 `52acc6e`，打包分支 `codex/ios-ipa-release`。

## 构建方法

使用现有 `.github/workflows/ios-native.yml`，GitHub Actions macOS Runner 执行真实 Xcode Release iPhoneOS 编译。Go 以 `c-archive` 静态链接进 SwiftUI App；XcodeGen 生成工程，原有图标生成与第三方许可证脚本保留。没有 Windows 版 Xcode，也没有把任意 ZIP 改后缀充作 IPA。

当前首轮：[Build 13](https://github.com/yann359/go-music-dl/actions/runs/42629940184)，源码 `1f80c29`。Release 编译与包内验证已成功，模拟器测试尚在执行。另补充真实启动 UI 检查：不启用界面样例数据，走内嵌 Go / SQLite / 原生页面路径；需以包含该测试的最终成功构建为交付依据。

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

## 最终结果

待记录最终成功运行、源码提交、Xcode/SDK、单元/UI 测试结果、实际 IPA 本地路径、云端产物及哈希。
