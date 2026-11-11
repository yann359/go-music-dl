## 当前阶段：已分析真机日志，修复准备阶段提前发布媒体状态（2026-11-11，待本轮macOS验证）

- 已实际读取用户的真机media-session.jsonl：20,818字节、45条有效记录，Build28/iOS27.3；北京时间07:56:25–08:25:56。[完整分析与证据边界](docs/ios-real-device-media-timing-2026-11-11.md)。原始用户日志不入库。
- 一引擎/一会话，仅启动时自动active，无主动认领、反复激活或重建。正常播放多次前后台时metadata_updates稳定5；远程暂停确实进入App。故Build29删除主动提升不是这份日志中现象的已证实根因，不能继续归咎于重复创建/闪写。
- 确认源码时序缺陷：资源准备尚无currentItem，play已设置rate1，publish却从请求队列发布歌曲/封面并启用命令。真机两段preparing窗口与之相容。旧state是publish缓存，日志未记录原生item/status，因此不把rate1或缓存preparing当作实际发声/屏幕可见性的证明。
- 修复：唯一MPNowPlayingSession使用官方自动发布，静态信息绑定真实AVPlayerItem，系统从player维护动态时间/播放状态；真实item ready后才激活音频会话并发起原生播放，准备期间暂停不自动抢播。没有前后台条件隐藏、固定延时、清信息假动画或私有API，没有改动画。
- schema2诊断加入毫秒/单调时间、事件序号、item/timeControlStatus、会话标识、实际命令与inactive/中断事件；仍有界且无歌名/地址/凭证。MiniPlayer仅补无障碍播放状态，UI探测等待真实playing后截图；搜索/下载/来源/数据库和签名不动。
- 分支codex/real-device-media-timing，基线36d6a43；新增两项准备门闩回归，保留原有媒体/业务回归并验证自动发布；本地Node6/6和diff检查通过，macOS编译/XCTest待执行。旧IPA保留，本轮不使用REA。
- 用户要求的“前台真实播放不显示歌曲小岛→Home自然承接”仍需新包真机验证；这份日志不包含岛可见性、手势动画或签后entitlements，不能认定已定位全部视觉根因，也不能未经证据归因SideStore。新包及实际测试结果将在本节补录。

## 上阶段：用户确认 Build28 提前上岛，核心体验未达成（2026-11-11）

- 用户已明确确认：手机运行 **Build28**，在 App 内点歌即显示**封面+波形的紧凑小岛**；期望是 App 内不显示歌曲小岛，滑回桌面时通过系统过渡自然承接。不是旧包或自动展开的大卡片问题。用户另确认是 **SideStore直接安装的独立App，不是容器运行**；这不等于已证实签名不匹配。用户另确认**同机Apple Music确实前台不显示、退出桌面才显示**，因此当前App表现相对该对照未达标。此为用户提供的真机反馈，未由本机远程观察。
- 因此 Build28 的65项原生回归/UI流程通过，只证明那些受测功能，没有证明核心前台→Home视觉体验成功；本项重新记为**未达成**。不能用“系统控制”直接认定当前异常符合 Apple Music 行为。
- 复查 Apple [WWDC22 5:32–5:56](https://developer.apple.com/videos/play/wwdc2022/110338/?time=332)：单个 MPNowPlayingSession 自动作为默认会话，不需要 becomeActiveIfPossible；主动提升用于同一 App 多会话的选择。现有代码在播放和资格变化时仍主动提升，属于多余干预，已移除方法、调用和重试标志，保留单一会话、信息中心和命令中心。这一事实不证明它就是提前上岛的根因。
- 继续实时发布正确元数据，不按前后台隐藏、不延迟到 background、不创建假岛；没有公开的 Home 手势进度/媒体岛动画控制接口。本轮没有将多余调用删除包装为已经实现目标动画。
- 修改：`ios/MusicDL/AudioEngine.swift`；`ios/UITests/NativeVisualTests.swift` 增加 App 内播放→Home 之前的截图，和已有 Home 图保留对照。既有媒体/暂停/切歌/后台/系统探测回归保留；搜索、下载、音源和界面设计未动。本轮不使用 REA。
- 新分支 `codex/island-system-handoff`，基线 `552c84f`。Node6/6、diff检查通过；代码 `2a711e08e1d315d6aebee2b1b6d8b3f406663c61` 的 [Build29](https://github.com/yann359/go-music-dl/actions/runs/42928367771) 全部成功：Go四包、Node6、设备/模拟器编译、Swift65/65、UI7通过/2跳过/0失败。跳过仍是系统岛不可定位，不能证明核心视觉目标已实现。
- [Build29 IPA/匹配源码](https://github.com/yann359/go-music-dl/actions/runs/42928367771/artifacts/13815463642) 已下载至 `../outputs/ios-release-build/build29/music-dl-ios-native-unsigned.ipa`，14,350,439字节，SHA256 `4c980040a56abe13ffc964a7f516c8a25aa962f2c0b8acc7f4119ce26e7a894a`。原Bundle ID、MusicDL、Build29、arm64 iPhoneOS/iOS18+、未签名、后台audio；本地与CI验证JSON一致，源码/附带hash/ZIP CRC/GitHub artifact digest已核验。旧包保留，未操作手机安装或签名。[原始测试报告](https://github.com/yann359/go-music-dl/actions/runs/42928367771/artifacts/13816521561)，日志 `../outputs/island-native-build29.log`。
- 复查Build28导出图发现 `system-media-home-probe` 为Home退场动画中间帧，不能证明桌面稳定后的岛状态；不能用截图或模拟器skip冒充丝滑过渡已验收。本轮已查看Build29的 `foreground.png` 和 `home-transition.png`，两图均没有可辨认的媒体岛内容；模拟器不能复现/验证用户的真机视觉差异，新增前台图不替代真机录屏。
- 下一步取证：现有Build28已可在“文件→我的iPhone→MusicDL→Diagnostics→media-session.jsonl”导出日志，无需为了取日志再装包；核对实际运行bundle/build、app_state、session_active与事件序列。已向用户请求该文件，当前尚未收到。回滚本轮代码：`git revert 2a711e0`。
- 真机最终验收必须分别观察：①App内开始播放不提前显示歌曲小岛；②滑回桌面时系统自然承接；③重新进App后的呈现与Apple Music同机对照；同时验证锁屏/控制中心/暂停/切歌。若仍失败，需手机实际 `Diagnostics/media-session.jsonl` 与短录屏定位运行身份/场景及系统呈现；当前没有这些证据，不能认定签名、SideStore或系统版本为根因。

## 上阶段：原生灵动岛时机与过渡复查（2026-11-11，Build28自动化通过，真机待验）

- 本轮不使用 REA；已先读源码、Git 历史及本文。从干净 `3afcf14` 建立 `codex/island-native-transitions`，保留历史 Build26。范围仅媒体系统交互，不改 UI 设计、搜索、下载、来源或签名。
- 已在线读取用户指定的四份 Apple 官方资料及媒体时间/会话文档；[本轮报告](docs/ios-native-island-transitions-2026-11-11.md) 记录来源、根因、测试与真机矩阵。没有 Apple Music/iPhone 实测，不把文档推断写成同机对比。
- 确认没有 ActivityKit/自制岛/重复生产引擎。前台显示系统 Now Playing 不能据此认定异常，公开 API 不承诺仅后台上岛；保持前后台真实信息，不延迟、不清空隐藏、不用私有 API。
- 修复 `AudioEngine.swift`：系统元数据按显著变化发布，每秒只保留本地状态刷新；seek、循环新 item、封面/时长/队列/实际速率仍即时同步；先对齐当前 item 的曲目索引与封面，避免异步 KVO 使新进度配旧标题。停止/销毁重置发布缓存，前后台不重建会话。诊断新增累计 metadata_updates。
- 修复 `NativeAppModel.swift`：后台返回确需恢复 FullPlayer 时禁用额外 zoom/sheet 动画，避免与系统返回动画叠加；已显示时不重复恢复。用户主动展开动画保留，不自动播放/seek。
- `MediaSessionTests.swift` 新增连续进度/前台不重发、暂停 seek、即时切歌身份、同曲新 item 时间锚点回归；保留全部旧测试。本地 Go 四包、Node 6/6、diff 检查通过。`NativeVisualTests.swift` 收紧歌曲目标识别并补充长按/系统暂停恢复探测，无法定位明确 skip。代码 `d55096eafc577cc0ce0d8a2521b70e4a04935098` 的 [Build28](https://github.com/yann359/go-music-dl/actions/runs/42923690865) **全部成功**：macOS Go四包/Node6、设备与模拟器编译、Swift65/65（64单元/受控回归+1真实C ABI集成），UI7通过/2跳过/0失败。两项跳过均为模拟器没有暴露可识别媒体岛，不能当作轻点/长按通过。Build27被补齐探测的新版本取代取消，未交付。
- [Build28 IPA/匹配源码/许可证](https://github.com/yann359/go-music-dl/actions/runs/42923690865/artifacts/13813703204) 已下载至 `../outputs/ios-release-build/build28/music-dl-ios-native-unsigned.ipa`，14,353,065字节；SHA256 `e9aa3d5570f67db085b4c5f04bbfca3bb7635438f7e30f68bbd9aeb11f0a6ef7`。MusicDL、原Bundle ID、1.0.0/Build28、arm64 iPhoneOS、iOS18+、未签名/未加密、后台audio。源码、资源/依赖、hash、ZIP CRC、GitHub artifact digest及本地/CI验证一致；旧包保留，未重签/安装。云端有效至2026-12-11（本地时间）。[测试报告](https://github.com/yann359/go-music-dl/actions/runs/42923690865/artifacts/13814302395)，原始日志在外层 `outputs/island-native-build28.log`。
- 尚待真机：前台播放→Home→返回、锁屏/控制中心控制、轻点/长按岛、切歌/暂停及 Apple Music 同机对照。系统决定岛显隐、暂停保留时长、形态和系统动画；不能承诺强制前台隐藏或已彻底修复签后激活。
- 回滚代码：`git revert d55096e 1b349ba`；状态记录单独docs提交，不改变已通过验证的Swift源码。

## 上阶段：原生媒体岛交互专项（2026-11-10，Build26自动化通过，真机待验）

- 代码 `755451b00f741f68ad6d9b0261fd6ecb6e82aaee`，[Build26](https://github.com/yann359/go-music-dl/actions/runs/42811102169) **成功**：Go四包、Node6/6、iPhone设备/模拟器编译、Swift XCTest62/62（61单元/受控回归+1真实Go C ABI集成）；UI7通过/1跳过/0失败。实际媒体岛探测因模拟器未暴露可定位目标跳过，不能据此宣布iPhone轻点/长按已修复。
- 三源真实C ABI搜索返回30首，首批945ms、全部8021ms、热请求2896ms、2来源命中缓存；这是本次网络样本，不表示三个来源都成功，也不作为iPhone延迟指标。2项非preview原生启动/搜索UI与5项fixture UI通过，未重复前轮205组来源矩阵。
- [下载Build26 IPA/匹配源码/许可证](https://github.com/yann359/go-music-dl/actions/runs/42811102169/artifacts/13762827822)，云端有效至2026-12-10。本地 `../outputs/ios-release-build/build26/music-dl-ios-native-unsigned.ipa`，14,350,298字节；SHA256 `6095d2aa8aa5dfd069becb8cc1f0a85bba45ea9168472811f3742bb7a4ab92a6`。实际包：MusicDL、原Bundle ID、1.0.0/Build26、arm64 iPhoneOS、iOS18+、未签名/未加密、后台audio；ZIP/资源/依赖/Mach-O、附带hash/源码、GitHub artifact digest及本地/CI校验完全一致。旧IPA保留；完整 [交付JSON](docs/verification/island-build26-delivery.json)。
- 真机验收仍待：SideStore覆盖重签、桌面轻点/长按、锁屏/控制中心、后台整曲。安装后“文件→我的iPhone→MusicDL→Diagnostics→media-session.jsonl”核对实际build/bundle/scene-active；没有真机激活日志，不将C宣告彻底修复。已修复可证实的页面恢复缺口并改进官方会话绑定；A/B保持系统呈现。
- 历史Build25 `42809023352`：62项原生测试61通过/1失败；无Build24的KVO异常/进程重启。唯一失败是暂停元数据用`as? Float`读到nil；明确发布Float(0)，并按NSNumber读取数值，继续断言暂停为0、原生速率0、stop清理及命令禁用。原始日志及53,699,146字节完整报告保留在外层outputs，报告digest/ZIP CRC已核验；UI/IPA跳过，没有交付该失败包。修订在Build26通过。

- 基线 `4e9e094`，独立分支 `codex/now-playing-island`；用户设备iPhone17/iOS27.3。只核查媒体会话、场景恢复与重签身份，未重复全项目审计。
- 已读取实际Build23 IPA：build=23、MusicDL、原Bundle ID、后台audio与单场景；当前手机安装版本无法远程读取，不能声称一致。
- REA 6.4.0真实调用并审查Build23归档，证据 `ev_87e450f88ec37fb80066d1b4d332248bbd5eacaa6130dbd0de9db5ce2eaf9fb3`。Windows原生运行时不可用，不假称观察Apple Music或iPhone。官方资料/10问题/证据边界见 [研究报告](APPLE_MUSIC_DYNAMIC_ISLAND_RESEARCH.md)。
- A/B与系统呈现策略相容，保持原样；C分“未激活App”和“已激活但未恢复播放器”。已确认旧scene active只重连服务，没有恢复当前页；无真机日志，不宣称该导航缺口就是完全无法返回的唯一原因。
- 代码：单一MPNowPlayingSession绑定AVQueuePlayer，使用同session信息/命令中心；播放器重建解绑旧会话；后台真实返回恢复FullPlayer但不自动播放/seek/重建；加入有界Files诊断日志，可核对手机实际build/bundle及系统激活时间。
- 保留iOS18+与现有构建链，未混用iOS27 NowPlaying框架，未添加Live Activity、假岛、私有API或自我openURL。Swift新增媒体/场景测试与系统可定位媒体岛探测；探测无法定位时明确skip，不用app.activate冒充岛点击。
- Windows Go四包与Node6/6通过，业务Go源码/搜索/音源未改；macOS实测结果见上，不用旧Build23冒充本轮修复包。
- 首次代码检查点 `1d5f2b52a3328768d33bedb93ca7b87f28937e9c`，[Build24](https://github.com/yann359/go-music-dl/actions/runs/42806577036) 设备编译通过、测试失败，原因如下。研究报告已补isActive不是全局归属证明的边界。
- Build24真实失败：退出/重建会话时出现 `Cannot remove an observer MPNowPlayingSession ... currentItem ... not registered` / NSRangeException，旧播放器用例也受影响，未上传IPA。日志 `outputs/island-build24.log`。已撤销“整会话销毁前逐个removePlayer”的重复观察者清理，改由会话生命周期释放其KVO；仍禁用旧命令并清理元数据。保留原用例与新会话回归，不捕获/吞掉NSException。另将活动会话请求限制在显式播放/资格变化，避免ticker反复请求；准备修订后重验。
- 用户已补充同机Apple Music对照：iPhone17/iOS27.3轻点直接返回Apple Music，而MusicDL不能。C是相对原生参考的异常，不是“27.3全体音乐App正常语义”；这是用户提供的真机结果，非REA远程观察。具体失败层和手机安装Build仍待诊断；锁屏/控制中心结果未收到。

## 上阶段：REA 审计、故障修复与 Build23 IPA 已交付（真机待验）

- 分支 `codex/rea-search-crash-audit`；最终构建源码 `c1f965733aaf973ff6ffb1797e454cdb12a1c98b`。修复提交 `5c34f8f`、`351eabd`、CI准备修复 `c1f9657`；保留全部历史、13在线来源+本地、当前UI/播放器/数据库与旧IPA。
- 根因：旧自动换源搜索/验证worker的panic跨协程逃逸（修复前真实子进程退出码2、修复后通过）；播放解析ABI缺保护；本地空成功掩盖在线失败；旧music-lib导致Apple新版页面解析失败。已修复并加入回归、脱敏异常栈及Release搜索阶段日志。
- REA 6.4.0真实调用的JS/IPA/上游静态证据已存档；Windows不支持其iOS运行时，Ghidra未配置。Swift/Go根因由源码及受控执行交叉验证，不冒充REA反编译或真机结果。
- Windows Go六包 **364通过 / 15条件跳过 / 0失败**；Node **6/6**，vet和后端构建通过。上游39组真实搜索、当前205组后端检查+3组全源聚合另行完成；12在线平台返回歌曲，Spotify仍受官方OAuth配置限制。真实换源3候选，酷我/咪咕片段通过，JOOX失败。
- [最终Build23](https://github.com/yann359/go-music-dl/actions/runs/42792576244) **全部成功**：Swift XCTest **59/59**（58项单元/受控回归+1项真实C ABI集成），UI **7/7**（2项真实原生启动/搜索+5项界面fixture回归）。真实键盘搜索、点击进入播放器、Home返回与清空用例通过，未将fixture或模拟器当作iPhone实测。
- [下载新IPA及对应源码/许可证](https://github.com/yann359/go-music-dl/actions/runs/42792576244/artifacts/13754860083)。本地 `../outputs/ios-release-build/build23/music-dl-ios-native-unsigned.ipa`，**14,337,073字节**；SHA256 `7e8efc21c734c6083ea305f9407372d9fd358e2dc2a69f09fe85b10a89b8a169`。arm64、iPhoneOS、iOS18+、版本1.0.0/Build23、未签名/未加密；纯英文名称MusicDL，Bundle ID仍为 `com.guohuiyuan.musicdl.nativedesign`，后台audio保留。ZIP、Mach-O、资源、动态依赖、源码、CI/本地校验及GitHub artifact digest一致。云端有效期至2026-12-10，本地副本保留。
- Build21被新运行取消；Build22因模拟器测试进程bootstrap耗尽步骤10分钟而失败，未上传IPA。真实日志后将冷启动/bootstatus拆为独立准备步骤，Build23全部重验通过；未删除测试或放宽断言。日志/失败诊断及最终报告在外层 `outputs/rea-*`。
- 尚未进行iPhone重签/安装/整曲/真实断网/锁屏中断验证，未获取用户ips或Jetsam。Spotify匿名Web Player/TOTP路径未接入现有OAuth边界；咪咕部分专辑、5sing歌单及JOOX探测限制如实保留。下载ZIP后解压IPA交给SideStore重签，沿用原身份及Bundle ID覆盖安装，不主动卸载旧App。
- 逐文件根因、REA证据、全部来源差异、12场景证据类型和真机日志步骤见 [本轮完整报告](docs/ios-rea-search-crash-audit-2026-11-10.md)；[交付核验JSON](docs/verification/rea-build23-delivery.json)。

## 本轮过程记录：REA 搜索/换源回归审计

- 干净起点 `8eac5d4`，独立分支 `codex/rea-search-crash-audit`；上游已重新 fetch，仍为 `c445ddd`。本轮停止功能/UI扩展，所有13在线来源和本地、现有UI/播放器/数据库均保留。
- REA 6.4.0 已真实调用：当前JS静态分析、Build20 IPA归档核查、上游app.js静态分析；完整证据在外层 `outputs/rea-regression-audit-2026-11-10.json` 和 `rea-upstream-evidence-2026-11-10.json`。Windows不能执行REA iOS运行时，Ghidra未配置；不宣称REA审过Swift/Go执行栈或完成真机验证。
- 新增受控真实panic子进程复现：旧自动换源搜索及验证worker均退出码2（`outputs/rea-panic-before.log`）。已复用按来源有界请求池保护两路径，保留健康来源；补齐播放解析ABI保护，Release也记录脱敏符号栈。
- 修正本地空结果掩盖在线错误：无结果且有错误一律显示失败明细；Swift保留网络错误类型，区分解析/服务/来源异常；增加Release搜索阶段日志。
- Windows Go六包 **364通过 / 15条件跳过 / 0失败**；Node **6/6**，go vet、后端构建通过。真实矩阵及聚合已另行执行成功，来源详情即将写入本轮报告。
- 追加确认：当前依赖旧于上游，Apple旧bundle匹配失败；精确更新 `music-lib` 到上游 `af5e6d8` 后复验Go仍364/15/0，Apple五词120首/0歌曲错误。上游独立工作树39组真实搜索通过；本轮最终205组矩阵+3组聚合通过（125首歌/104专辑/119歌单），并非所有平台都成功。
- Spotify上游新匿名Web Player/TOTP搜索路径未引入现有官方OAuth边界；入口保留，未配置时明确失败。已用nativebridge依赖清单核查没有链接music-lib/spotify匿名实现。
- 真换源3候选：酷我/咪咕音频片段成功，JOOX失败；不等于真机整曲播放。逐来源差异、REA证据、修复路径及验收表见 [本轮报告](docs/ios-rea-search-crash-audit-2026-11-10.md)。
- 首轮macOS [Build21](https://github.com/yann359/go-music-dl/actions/runs/42788448454)（`5c34f8f`）已通过Go/JS、设备Release和模拟器Go库构建，XCTest在执行；它不含最后依赖对齐，不作为最终交付。本轮最终macOS/XCTest/UI/IPA待后续工作流完成，下节Build20仅为历史包。尚无iPhone crash/ips报告或真机验证。
- 最终代码候选为 `351eabdc65391d93bef12bba417cd64d635f6cd9`；[Build22](https://github.com/yann359/go-music-dl/actions/runs/42789761149) 已通过Go/JS、设备Release及模拟器Go库，XCTest进行中。Build21被同分支新运行按工作流并发规则取消，不是已通过的交付包；最终IPA下载和本地核验仍待完成。
- Build22终态：XCTest步骤10分钟超时，UI/IPA上传跳过，**没有交付IPA**。实际 `scheduling.log` 显示09:27:41拿到worker、09:37:18才完成bootstrap，而步骤09:37:03已超时；不能计为已执行测试通过或断言失败。日志 `outputs/rea-build22.log`、测试诊断ZIP保留；已把模拟器冷启动/bootstatus拆为独立15分钟步骤并保存服务日志，测试断言与原10分钟测试预算不变，准备新运行。

## 上阶段：搜索恢复与IPA交付完成（2026-11-10）

- 分支 `codex/search-parity`，干净起点 `4ce3d96`；原修复`52acc6e`及此前功能保留。最终构建代码为`65dbda79373ab13c6b947e4dabf8684cd148cfee`，上游比对`c445dddb66eec1b34c04fb16a72577f1115285c7`。
- 搜索：键盘立即提交、450ms防抖、代次/取消隔离；全部注册来源+本地，按三种能力筛选并保存偏好；3来源并发、部分先显示、独立错误；120秒有限内存缓存；查询归一、稳定相关性排序、保留版本/音质的精确去重；本地跨字段组合查询。
- 根因修复：HTTP诊断包装吞掉EOF导致完整响应后io.ReadAll无限循环及全源超时；已保留EOF并改有界异步日志，真实UI显式开启追踪回归通过。正常启动只保留基础计时，深层追踪显式开启且不记录敏感错误URL。
- 换源：严格歌名/歌手/时长/版本候选、用户选择、完整Extra音频Range验证，失败不改队列；原平台Spotify未配置/失效不阻止其他来源元数据匹配，实际Spotify候选仍需授权。保留原播放器引擎、播放页、底部导航、账号与数据库结构。
- Windows Go六包 **360通过 / 15条件跳过 / 0失败**；Node **6/6**、go vet、后端构建通过；增量lint **0 issues**。真实API审计另行显式执行。
- 真实后端：五关键词205组检查，另3组全来源聚合105首歌/84张专辑/121张歌单；11个在线源有歌曲，Apple旧适配器与Spotify配置受限；5sing歌单及咪咕部分专辑抽查失败。真实晴天换源3候选，酷我/咪咕音频通过，JOOX未通过。
- 最终 **Build20 `42756768725` 全部成功：Swift 56/56、UI 7/7**。真实Go启动、开启追踪的聚合键盘搜索、点击播放、后台返回及清空均通过；C ABI三源34首，首批562ms、全部1058ms、热缓存低于1ms。网络样本波动，不宣称稳定提速百分比。
- 已核验未签名arm64 iPhoneOS IPA（iOS18+，后台audio、Bundle ID不变）：外层 `outputs/ios-release-build/build20/music-dl-ios-native-unsigned.ipa`，14,325,073字节，SHA256 `65d4fe0afb8fb025439dbce9f042eb73c9b26bfc6c8c40c4f084f3279247adee`；源码/产物digest/资源/Mach-O/CI与本地核验一致。
- [GitHub IPA下载](https://github.com/yann359/go-music-dl/actions/runs/42756768725/artifacts/13736807222)；可用SideStore/AltStore个人重签，尚未操作iPhone安装。无需部署Windows Go/Node服务；既有汽水会员解密等限制不由搜索结果掩盖。
- 真机剩余：签名覆盖安装、中文输入法、本地曲库、整曲播放及换源、真实断网、后台/锁屏/中断、Liquid Glass显示及账号地区权限；上游通用Search没有page，当前仅分批展示已返回结果；底层已发I/O仍无真正context取消。
- 逐文件清单、原仓库能力/差距、失败记录与最终验收见 [完整中文报告](docs/ios-search-parity-2026-11-10.md)；脱敏逐请求及包核验证据在 `docs/verification/search-api-2026-11-10.json`，原始日志在外层 `outputs/search-*`。

## 2026-11-09：iOS Release IPA 正式打包完成（Build 14，真机侧载待用户执行）
- 成功运行：[42633849708](https://github.com/yann359/go-music-dl/actions/runs/42633849708)，**Build 14**，实际源码 `2f0b7d43d0c80f0d1ac27d3c2faf80b1946436d8`；分支 `codex/ios-ipa-release`。基线 `52acc6e` 及原修复分支保留，未回退来源/播放器/缓存，未更改 UI、SQLite 结构或用户配置。
- 真实工具链：GitHub Actions `macos-26` / **Xcode 26.6 (17F113)** / **iPhoneOS SDK 26.5** / Go 1.26.1，Release iPhoneOS **arm64** 编译通过；不是模拟器包或演示壳。
- 当前 IPA：`../outputs/ios-release-build/build14/music-dl-ios-native-unsigned.ipa`，14,257,557 字节。**未签名、未加密、无旧签名目录及 embedded.mobileprovision**，适合交由 SideStore / AltStore Classic 个人重签；未实际在用户手机签名安装。
- IPA SHA256：`836d7f43ef0de2d7b801b18b8e8775f1785fb9656b48762cd60196ed0b65994c`。本地 IPA 校验与 CI 一致，GitHub artifact ZIP digest 一致，对应源码 SHA 一致。
- [云端 IPA / 对应源码 / 许可与核验 JSON](https://github.com/yann359/go-music-dl/actions/runs/42633849708/artifacts/13684521858)，云端有效期至 2026-12-09；本地副本不受此期限限制。解压后导入其中的 `.ipa`，不要将 artifact ZIP 改后缀。
- Bundle ID `com.guohuiyuan.musicdl.nativedesign`，显示名/可执行文件 `MusicDL`，版本 1.0.0，最低 **iOS 18.0**；后台 audio、系统音乐权限说明、Spotify callback、完整资源与所有 13 来源保留。
- 核验实际包内 Mach-O、iPhoneOS 平台、arm64、未加密/无签名、系统动态依赖、Assets.car、LICENSE、NOTICE.md、ThirdPartyNotices.txt 均通过，无缺失第三方框架；Go 静态编入 App。
- macOS 回归：Go 四包与 Node **6/6** 通过；iPhone 17 Pro Max / **iOS 26.5 模拟器**的原生单元测试 **48/48**、UI **6/6** 全部通过。真实 C ABI / SQLite / 13 来源集成，以及**不启用样例数据的真实原生启动 UI**测试通过；深浅色/歌词/空播放器/暂停返回/账号入口回归通过。合成 WAV / 通知注入不等于真实歌曲与实际系统中断。
- 首轮 Build 13：Release 与 48 单元测试通过，歌词 UI 用例因把可跳转 Button 当作 StaticText 查询而失败；根据截图和层级仅修正测试定位，未改歌词/UI实现。最终 Build 14 已全部重验通过，不交付失败构建。
- 核心启动、搜索、本地数据及 AVQueuePlayer 不需要 Windows / Node 服务。汽水会员整曲的旧桌面 bdms.node 签名路径、部分外部 FFmpeg 导出仍受 iOS 环境限制；未部署服务器、未新增付费接口。
- 仍需真机：原账号 SideStore/AltStore 覆盖重签、实际歌曲/权限、iOS 27 后台/锁屏/网络切换/蓝牙/中断与用户旧数据确认。Apple Music 真实服务仍需实际签名的 MusicKit 配置；Spotify 保持待配置；已知 Apple 兼容目录和 5sing 个别歌单限制未伪装为通过。无需向 Codex 提供 Apple 密码或签名私钥。
- 详细过程、首次失败修复、安装方法和验证边界见 [正式打包记录](docs/ios-ipa-release-2026-11-09.md)。实际核验 JSON 与日志在 `../outputs/ios-release-build/build14/local-verification.json`、`../outputs/ios-release-build/build14.log`；原有 Build 12 等安装包均保留。

## 上阶段：全部来源恢复与稳定性专项（截至 52acc6e 的历史记录，最新打包结果见上节）
- 分支 `codex/source-recovery-stability`，干净基线 `3bf0333`；原授权分支与旧 IPA 保留。未推送、未发布、未清除用户数据；SQLite 结构不变。
- 全部原有 **13 个在线来源 + 本地音乐**恢复，按 `ee4746a` 差异合并 Provider/播放/下载/歌词/CLI/账号入口。保留 MusicKit、Spotify PKCE/Keychain、Liquid Glass、歌词优化及原播放器。
- P0 播放：显式激活成功后清除残留中断；校验失败实例/丢失缓存文件；有限 watchdog 重建并保留队列/进度；状态由 AVPlayer 真值派生；旧队列清理不能删除新队列音频；过期 URL 最多重取一次。
- P0 服务：iPhone 内嵌 Go 核心，不依赖 Windows。原生收藏/本地/下载操作改走进程内路由，保留写入守卫；可选 AI 连接只绑定 127.0.0.1。修复桥接及配置数据库 sync.Once 首次失败后无法重试的问题；前端启动合并/3 次退避/前台重检，AI 重连有界。
- P1 数据：同来源 2 个底层调用槽、8 秒调用方截止、重复请求合并、跨来源搜索最多 3 并发且逐项显示；详情缓存 15 分钟复用/24 小时失效/最多 40 条及 8 MB，失败/部分结果不提升为完整缓存。详情 UUID 隔离旧请求，空/部分/成功/失败分开呈现，分页成功后才前进。缓存与存储结构独立。
- Windows 回归：Go 六包 **353 通过 / 13 跳过 / 0 失败**；Node **6/6**、JS 语法、go vet、后端构建通过；增量 golangci-lint **0 issues**。新增失败启动重试、端口被占用仍可读写 SQLite、来源隔离、详情部分/空/超时及请求合并验证。
- 真实公开接口：七个恢复来源均返回歌曲搜索结果；网易云/QQ/酷狗/酷我/咪咕/汽水/JOOX/Bilibili 抽样歌单可读；5sing 的抽样歌单详情失败，Apple 旧目录 index.js 解析失败，Spotify 缺授权配置，均不宣称可用。未验证整曲播放/所有歌单/地区与账号权限。
- 真实热歌榜两轮交叉顺序：旧路径 526.0901 / 456.6591 ms，新路径 478.7836 / 481.3941 ms，均 200 首；没有稳定网络耗时改善证据，不宣称 iPhone 性能提升比例。缓存首屏与后台恢复必须用新包实测。
- REA 6.4.0 当前可连，但无打开目标、留存证据为 0；本轮未借用第三方播放器代码。恢复来源沿用现有 AGPLv3 music-lib，保留 LICENSE/NOTICE。
- Windows 没有 Xcode、Swift/iOS SDK 或连接的 iPhone；当前 Swift 单元/UI 测试仅为源码待验收，没有新 IPA。不能把旧 Build 12 当作本轮修复包。
- 逐文件清单、原始证据、真实限制与真机步骤见 [专项报告](docs/ios-source-recovery-stability.md)。下一步：在现有 macOS 工作流构建并执行 XCTest/UI，再签名安装完成真机矩阵。

更新：2026-11-09（北京时间）。每次开发结束或可控中断前更新本文件；以下状态只描述已验证事实。

## 上阶段：六来源清理与官方账号授权（历史记录，六来源限制已被本轮撤销）
- 独立分支 `codex/six-sources-official-auth`，原始基线 `69e94bb`。原有 10 个已修改文件与 8 个未跟踪文件完整备份到外层 `outputs/six-sources-auth-baseline/`，并保存为本地检查点 `ee4746adfe82de631b2bded57da4c20c000e1013`。本轮改动另存本地提交，不推送、不强推、不重置用户数据。
- 唯一在线来源：网易云、Apple Music、QQ、汽水、酷狗、Spotify；本地文件作为独立能力保留。删除咪咕、酷我、5sing、Jamendo、JOOX、千千、Bilibili 的工厂、专属播放/下载/歌词分支、登录入口及独占测试；Go 编译依赖图已验证不含这七个适配器。公共 music-lib 保留给五个目标适配器使用。
- 根因与架构决策：旧来源由多个工厂、CLI 和 Web/原生目录共同注册，必须同步清理；旧 Apple/Spotify 只有手填凭证、没有原生授权生命周期。新增官方授权所有者，保留原播放器，原生模式隔离旧 Apple Cookie 和 Spotify Secret/Token 回退；绝不以保存凭证或获得系统权限代替实际服务验证。
- Apple 使用 `MusicAuthorization.request()`、真实用户 storefront 校验及订阅资格检查；Spotify 实现 PKCE/S256/state/ASWebAuthenticationSession/Keychain/到期刷新/401 有限重试，Go 仅接收内存短期 Access Token。统一账号页显示实际状态、能力与限制，Apple/Spotify 无默认 Cookie 输入框。
- 用户确认 Spotify Free 且不升级 Premium：真实 Spotify 授权保持“待配置”，未配置不会打开浏览器或阻塞其他来源。没有真实 Client ID、已登记回调或端到端登录结果。
- 网易云/QQ（含微信）/酷狗沿用已有兼容扫码，汽水保留已有凭证；都需实际验证账号歌单接口才显示已连接。未查证此应用具备官方音乐 OAuth 接入资格，不把原项目兼容接口标为官方授权。
- 数据兼容：旧来源条目、收藏、歌单、历史及凭证行保留，不改数据库结构；旧曲目标记来源已移除，播放队列跳过但不改保存条目。导入歌单保留已存快照。AudioEngine、PlayerViews、Lyrics.swift 相对检查点未修改，保留上轮空附件、连接、歌词重试与去重修复。
- Windows 验证：Go 六包 **344 通过 / 8 跳过**；最后请求头整理后再次通过 core 定向回归。Node 桥接 **6/6**、JavaScript 语法、go vet、Windows 后端构建、Info.plist 和依赖清理检查通过；增量 golangci-lint **0 issues**，新增 Go 文件无全量 lint 报告项。
- 未通过/未执行：全量 lint **77 项**（errcheck 49、staticcheck 24、unused 3、ineffassign 1）；`go mod tidy` 下载既有 Gio 字体测试依赖时 TLS 握手超时，go.mod/go.sum 未变。38 项 Swift 单元测试和 5 项 UI 测试在源码中就绪，Windows 无 Xcode，均未编译运行；8 项 Go 跳过用例需要账号、公开网络或显式诊断开关。
- 实际配置阻碍：Apple 需要与实际签名 Bundle ID 一致的 MusicKit App Service 和可用开发者配置，个人签名不能假定支持；Spotify 按用户决定继续待配置，当前开发模式 App 所有者 Premium 规则及回调限制见报告。没有新 IPA；旧 Build 12 不包含本轮代码。
- 修改文件、官方依据、回滚与测试边界见 [六来源授权报告](docs/ios-six-source-auth.md)；原始测试、逐文件清单及汇总证据在外层 `outputs/six-sources-verification.json`、`six-sources-go-tests.jsonl`、`six-sources-dependencies.txt`。
- 下一步仅为本轮验收：在 macOS 运行现有 XcodeGen/Release/XCTest/UI 工作流，通过后用实际签名验证 Apple Music 和 iPhone 的六来源搜索、播放、歌词、收藏、队列、后台/锁屏及深浅色安全区。Spotify 保持待配置，待用户以后主动决定满足条件时再做真实登录验证；不能宣称验收 A–I 全部通过。

## 上阶段：四项问题修复（代码已实现，iOS 验收待执行）
- 日期：2026-11-09；恢复基线 `69e94bb`，仓库初始干净，保留外层未跟踪目录、用户数据、所有旧 IPA。继续使用 `codex/ios-native-redesign`，本轮未提交/推送。
- 已定位并修改：空内容仍挂载底部附件；推荐聚合等待慢源且再串行请求榜单；歌词一次失败直接上抛；逐字方括号时间被当成整句的重复起点。
- 首页按当前歌曲启停 iOS 26.1+ 附件；来源最多 3 并行、6 秒调用截止、同源请求合并、逐项显示、成功结果 15 分钟复用/24 小时过期、单项及网络恢复重试。
- 歌词增加咪咕可取消请求、完整响应体校验和解码、最多 3 次退避重试、同曲缓存、严格歌名/歌手/专辑/已知时长匹配的已有来源降级；只对连续署名去重，保留正常重复正文。
- 修改集中在原生 Root/Client/Discover/Player、独立 Foundation 歌词解析和 Go 原生来源/歌词请求层；未改 AudioEngine、SQLite 数据结构、音源列表或视觉设计规范。完整逐文件清单、根因与恢复位置见 [四项维护报告](docs/ios-maintenance-2026-11-09.md)。
- Windows 回归：Go 六包 338 通过/11 跳过，Node 6/6，go vet、Windows 后端构建通过；增量 golangci-lint 0 issues。全量 lint 84 个存量问题未通过，不扩大范围清理；Go race 因无 CGO 编译器未执行。
- 实测 Windows 公开来源一次旧顺序/新并行：首内容 335.561/81.125 ms，全部 428.102/155.880 ms，结果数量一致；先旧后新有 DNS/连接复用偏差，不能宣称 iPhone 冷启动提升比例。受控弱源首内容 220.180/25.510 ms，仅为模型测试。
- 新 Swift 单元回归 10 项和 UI 回归 2 项已补，尚未编译运行。当前 Windows 无 Xcode/iPhone；冷/热启动、移动弱网、布局/深浅色截图、后台返回及真实歌词高亮仍待 macOS/真机验收，不能视为 A–E 全部通过。
- 依赖风险：旧 music-lib 无 context，调用方 6 秒返回后底层可能继续到两分钟；并发槽保持占用、重复请求合并，避免无限堆积。歌词备用匹配刻意保守；缺少确切歌曲 ID，未验证用户那一首上游原文。
- 下一步仅为本轮验收：运行现有 macOS 原生编译/XCTest/UI 工作流，成功后打包新 IPA 并完成上述 iPhone 检查。本轮没有新 IPA；下面历史 Build 12 不包含这些修复。

## 上阶段完成：SideStore App ID 名称修复
- 用户报告 `SideSign.DeveloperPortalError 10`，参数 `appIdName` 为 `澄音 MusicDL`；旧 Build 11 的实际包元数据含该显示名。
- 仅将 Info.plist 的 `CFBundleDisplayName`、`CFBundleName` 与应用构建 `PRODUCT_NAME` 统一为纯英文 `MusicDL`；Bundle Identifier 继续为 `com.guohuiyuan.musicdl.nativedesign`。
- 打包脚本检查构建产物及 IPA 内的实际名称、Bundle ID，防止仅改源配置却未生效。
- 不修改业务代码、播放行为或 App 内界面文案；旧 IPA 保留，Build 11 的 SHA256 再次核对未变。
- 名称修复提交：`35bfc86ae5673754d9f1e138c32c759bb3f5bbc4`；[构建 42588799339](https://github.com/yann359/go-music-dl/actions/runs/42588799339) **成功**。原有回归：17 项原生测试、2 项 UI 测试通过；未为文档结果更新重复构建。
- 新 IPA：**Build 12**，本机 `../outputs/ios-sidestore-name-fix/music-dl-ios-native-unsigned.ipa`；[云端安装包/对应源码/许可证](https://github.com/yann359/go-music-dl/actions/runs/42588799339/artifacts/13661057643)。下载 artifact ZIP，解压后将新 IPA 导入 SideStore 重签。
- 实际 IPA 内核验：`CFBundleDisplayName=MusicDL`、`CFBundleName=MusicDL`、`CFBundleExecutable=MusicDL`、`CFBundleIdentifier=com.guohuiyuan.musicdl.nativedesign`、`CFBundleVersion=12`。无 `InfoPlist.strings` 名称覆盖，arm64，后台 `audio` 声明保留，无 `_CodeSignature` 目录。
- IPA SHA256：`b71ce9fdbb548100d049b5df432bbb96bc4e94c9318048fb6b826222da60f098`；与构建附带校验文件一致，源码提交核对一致。下载 artifact ZIP 自身 SHA256 也与 Actions digest 一致。详细本地结果：`../outputs/ios-sidestore-name-fix/verification.json`。
- 本阶段源码变更仅 `ios/MusicDL/Info.plist`、`ios/project.yml`、`ios/scripts/package.sh` 与本进度文件。已完成打包和元数据修复；未在实际 SideStore/Apple 账号执行签名，错误是否消除须用户安装 Build 12 确认，不虚报安装成功。保存后停止。

## 目标与核心需求
- 将 Go Music DL 改为高品质原生 iOS 音乐客户端“澄音 / MusicDL”，面向 iPhone 17 Pro Max / iOS 27。
- 原生 SwiftUI TabView、NavigationStack、Sheet 与 iOS 26+ Liquid Glass；主要界面不使用 WebView。
- 当前恢复全部 13 个原有在线来源，另保留本地文件、WebDAV、AI API、设置；能力和可用性以专项报告的实际测试与限制为准。最新全来源指令替代历史六来源限制。
- 原生后台音频、锁屏/控制中心/耳机控制；真机测试与模拟器测试分开报告，禁止虚报。

## 当前架构
- Go 音乐核心与 SQLite 保持原有结构；新 `MusicDLRequest` C ABI 提供原生 JSON 功能接口。
- 前台管理功能可复用固定 loopback JSON 路由；音频解析经 C ABI，音频由原生文件缓存与 AVQueuePlayer 播放，不依赖网页 JavaScript 或本机 HTTP 音频流。
- Swift `NativeClient` 负责结构化数据与错误；`AudioEngine` 是唯一播放状态所有者；`AppModel` 连接原生 UI 与 AI SSE 控制。
- 原生设计使用独立品牌、系统字体、深浅色与安全区域。REA Windows 仅用于可用的静态包检查；没有观察 iPhone Apple Music 内部源码/动态界面。

## 分支与已保留版本
- 当前开发分支：`codex/ios-ipa-release`；来源修复分支 `codex/source-recovery-stability` 保留在 `52acc6e`；原授权分支 `codex/six-sources-official-auth` 保留；原 `codex/ios-native-redesign` 保持原提交，前阶段版本基于 `9b18983`。
- 上阶段通过的 Build 5：源提交 `a7c784c8ffd378418bdde33f65da746e71b58ee2`。
- IPA：`../outputs/ios-build5/music-dl-ios-native-unsigned.ipa`。
- SHA256：`72f1dc69ef597258df90f3a526961c01b6c6e7a1d64ea8046ef6069a8f8781c7`。
- 上阶段工作流：https://github.com/yann359/go-music-dl/actions/runs/42483202980 。

## 已完成与代理成果
- 上阶段原生缓存播放、音频会话、系统远程控制、中断/路由处理与后台声明。
- REA doctor/capabilities 已运行，结果摘要 `docs/rea-ios-readiness.json`；原 Build 5 IPA 已通过 REA 静态包检查。
- `docs/ios-native-design.md`：公开参考、证据边界、字体间距/交互/动效/状态规范。
- `docs/ios-native-feature-matrix.md`：历史迁移清单；当前全部来源范围以 `docs/ios-source-recovery-stability.md` 为准。
- 后端代理：`internal/web/native_client*.go`、`ios/bridge/main.go`、`Bridge.h`。
- 客户端代理：`NativeClient.swift`、`NativeClientTests.swift`，包含显式 UI 测试样例模式。
- 主代理：`DesignSystem.swift`、`NativeAppModel.swift`、`NativeRoot.swift`、`NativeScreens.swift`，以及 AudioEngine 可观察状态/队列操作。

## 上次中断点（历史恢复记录，最终结果见下节）
- 已补齐全屏/迷你播放器、LRC 跟随与点击跳转、队列排序/移除/清空、系统输出选择器。
- 已补齐我的、Cookie/二维码、完整设置/WebDAV、音源浏览/分类/榜单和用户平台歌单。
- 原管理界面 WebView 已从 iOS UI 目标中移除；不改动原网页/Android 页面。
- CI 已改为 macos-26，并校验 SDK >=26；加入原生页面深浅色截图和无 WebView 断言。
- 第二轮云端运行 `42537993412`：Go 检查、原生 release 编译、模拟器单元测试通过；UI 自动化及测试报告上传失败，最终日志归档未结束，具体原因待查。不能记为 UI 验收通过。
- 补充专辑/原始链接/VIP元数据保留、失败与空结果区分、当前换源保留队列/进度、本地及锁屏封面；等待最终 macOS 重验。
- 已将 UI 检查设备限制为 iOS 26+，优先 iPhone 17 Pro Max；使用模拟器 ad-hoc 签名；播放器断言改为可见的收起按钮，避免依赖 SwiftUI 容器的可访问性类型。
- 已取得第二轮日志：Xcode 26.6；13 项原生单元测试通过；两项 UI 测试均找不到迷你播放器的可访问性标识；报告上传为 ArtifactService/CreateArtifact 请求超时（不是已证实的存储配额问题）。将展开区域改为有明确标签的原生 Button，并移除外层重复标识，等待重验。

## 后台音频阶段测试与已知限制（保留记录）
- 该阶段成功运行：[42540853672](https://github.com/yann359/go-music-dl/actions/runs/42540853672)，代码 `97b36c9c39562dfb9376b2497e98d09763ab3744`。最新名称修复构建见上节。
- 环境：macOS / Xcode 26.6，iPhone 17 Pro Max / iOS 26.5 模拟器；不是用户的 iOS 27 真机。
- 原生测试 **17/17 通过**：AudioEngine 6、歌词解析 3、NativeClient 7、真实 Go 桥接集成 1（含 SQLite 收藏增删、原生 SSE 与音量往返）。
- Go 回归与 Node 桥接 **6/6** 通过。Windows 上 `go test ./internal/web ./internal/appshell ./core ./internal/spotify ./internal/cli ./cmd/music-dl` 同样通过。
- 收窄任务前已启动的同一次构建另有原生深浅色 UI 自动化 **2/2 通过**；此后未开展新 UI 工作，也未做人工截图验收。
- 历史失败：`42537618882` 的 SQLite 异步写/关闭竞争已修复并通过后续 macOS 回归；`42539762359` 的换源进度变零已修复，同一进度断言在最新运行通过；旧 UI 标识与上传超时也已在最新运行通过。
- 模拟器音频测试使用短合成 WAV：三段推进不等于三首真实歌曲完整播放；中断/路由用例是通知注入，不等于真实来电/AirPods。
- Windows 无 Xcode/SwiftUI 编译器；iOS 编译、模拟器与截图必须在 macOS Actions 执行。
- 无 iPhone 连接；桌面/锁屏 30 分钟、三首完整真实歌曲、系统锁屏/控制中心实际按钮、真实来电及 AirPods 测试均未执行。不能据自动测试宣称全部真机中断已修复。
- 音源可达性、账号权限、格式解码、首曲缓存延迟仍需实测；不绕过版权或付费授权。

## 后台音频阶段修改与留存安装包
- 代码阶段提交：`97b36c9`，修改 `ios/MusicDL/AudioEngine.swift`、`NativeAppModel.swift`、`ios/Tests/AudioEngineTests.swift`、`NativeBridgeIntegrationTests.swift`，修复就绪/跳转竞争和状态上报顺序；既有 UI 页面未修改。
- 详细改动、证据边界及真机步骤：`docs/ios-background-audio-stage.md`。
- 新 IPA：`../outputs/ios-audio-stage/music-dl-ios-native-unsigned.ipa`，Build **11**，arm64，包内声明后台 audio、无 `_CodeSignature` 目录，适合 SideStore 重签。
- IPA SHA256：`c2fbcaf6f09d34484dc6f889635e5cb975e816a9ce768c4faddbeda6fefd9303`；已核对构建附带校验值、对应源码提交和 Bundle ID。
- [云端安装包/源码/许可](https://github.com/yann359/go-music-dl/actions/runs/42540853672/artifacts/13641678130)，有效期至 2026-12-09。解压 artifact ZIP 后导入其中的 IPA。
- 已再次核对旧 Build 5 SHA256 未变化；未覆盖旧 IPA。

## 上一后台音频阶段与停止条件（保留记录）
- 本轮仅主智能体，聚焦后台音频与相关回归；不再开始 UI 或其他功能阶段，不重复全仓扫描/架构分析。
- 恢复时工作树干净；已有修改均保存在独立分支。保留前两阶段代码、既有 UI 与旧 IPA。
- 当前代码提交 `97b36c9`：修复原生换源/恢复的就绪与进度竞争，以及播放状态上报顺序；不改 UI 页面。
- 已确认现有后台实现：`AudioEngine.swift` 使用 `.playback` / `.longFormAudio`，`Info.plist` 声明 `UIBackgroundModes(audio)`，AVQueuePlayer 读缓存文件，MPRemoteCommandCenter 绑定系统控制。没有退后台即暂停的 SwiftUI 生命周期处理。
- macOS 验证和包核验已完成，结果如上；使用收窄指令前已启动的构建，没有为文档更新重新构建。
- 本阶段结果与恢复点保存后停止；不自动开始 UI、附加功能迁移或下一轮构建。后续先按记录执行真机验收，由实际结果决定是否需要修复。
- 必须保留的外部验收：iPhone 桌面/锁屏 30 分钟、三首完整真实歌曲、控制中心/锁屏按钮、AirPods、真实来电。Windows/macOS 模拟器测试不能替代这些结果。
