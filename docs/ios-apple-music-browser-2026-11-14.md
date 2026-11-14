# Apple Music 浏览器连接：实现、配置与验证

## 当前交付边界

用户于2026-11-14确认没有 Apple Developer Program 和 HTTPS 服务器。实现可配置的客户端与独立服务，不部署、不制造Apple凭据。未配置时明确显示“服务配置不可用”，不会打开普通Apple账号登录页后冒充音乐授权。实际账号成功、2FA、真实Safari往返与音乐资料读取尚未验证。

基线345818e/Build48，分支codex/apple-music-browser；先读PROJECT_STATUS.md、Git历史、MusicAccounts/AccountViews/ApplePlaylistImport、Spotify Keychain与原工作流。原架构SwiftUI→C ABI/Go搜索与SQLite保持；新增服务独立部署，不放进App的loopback本地服务。

## 官方研究结论

2026-11-14通过Firecrawl实际读取Apple官方文档。文档站外壳最初仅返回标题；继续读取Apple官方CDN的iframe文章后获得v3实际初始化和授权说明，未把论坛用户报错当作官方保证。

- [MusicKit JS v3 Getting Started](https://js-cdn.music.apple.com/musickit/v3/docs/iframe.html?id=get-started--page&viewMode=story)：官方CDN `https://js-cdn.music.apple.com/musickit/v3/musickit.js`，等待musickitloaded，await MusicKit.configure，传入signed Developer Token。
- [JS User Authorization](https://js-cdn.music.apple.com/musickit/v3/docs/iframe.html?id=user-authorization--page&viewMode=story)：music.authorize打开登录/音乐授权，已有有效授权可能直接返回；music.unauthorize使该网站的Music User Token失效。连接页按钮直接由手势调用authorize，避免初始化后的异步自动弹窗被拦。登录、密码、2FA和同意音乐权限由Apple提供；本项目没有密码表单，也不使用Sign in with Apple替代音乐授权。
- [Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens)：Apple Developer Program、ES256、10位kid/Team ID、iat/exp；web推荐origin数组限制。本服务仅生成15分钟Token，私钥只读服务器外部PKCS8文件，不进客户端/源码/日志。
- [Media ID与private key](https://developer.apple.com/help/account/capabilities/create-a-media-identifier-and-private-key)：为媒体服务登记Media ID、关联启用对应服务的Media Services key，授权显示名称来自登记信息。配置地址不代表这些资格已具备。
- [User Authentication](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)：个性化资料请求需Music User Token，Apple平台/网页分别有自动管理方式；服务端实际调用官方API验证数据。本实现不把网页MUT安装到原生MusicKit，更不假定有完整播放/下载权限。
- [原生automatic token generation](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)：对应签名Bundle ID需在开发者后台启用MusicKit App Service，系统允许弹窗不等于API成功。系统备用独立请求storefront、订阅资格并显示实际错误类别/码。
- [Universal Links](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app)、[Associated Domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)：需要网站AASA与签名匹配的Associated Domains。没有域名/资格时不擅加虚假的entitlement。

公开UIApplication HTTPS打开请求交给系统默认浏览器，不能保证用户默认浏览器一定是Safari，也不能通过非公开Safari scheme强制打开。授权页可能需要额外点击“在Apple官方页面继续”和“返回MusicDL”；不承诺自动跨应用跳转一定成功。当前原生自定义scheme与可选Universal Link均是MusicDL自身安全中转协议，不声称Apple直接提供原生OAuth code回调。

## 实现与数据流

1. 设置优先浏览器入口，校验HTTPS裸域名与服务/v1/config版本、回调；无服务时显示明确配置阻碍。
2. App生成32字节随机state/verifier，仅把S256 challenge与state发服务。服务返回短时flow与bootstrap fragment，App先安全写Keychain再打开浏览器。
3. 网页以fragment建立Secure/HttpOnly/SameSite=Strict cookie，清除地址栏fragment，不收集Apple密码。仅加载Apple官方MusicKit JS；点击后调用music.authorize。
4. MUT通过同源HTTPS POST发送服务，服务用实际Apple storefront与library/playlists验证。验证成功才生成两分钟一次性code。不存在假成功兜底。
5. 成功返回链接只有id/state/code，取消返回id/state/error=cancelled，无Apple令牌。App严格核对scheme/host/path、重复参数、state、有效期，携verifier兑换。服务原子消费code，抵御重复兑换与自定义scheme被其他App截取后的使用。
6. 原生Keychain只保存24小时随机服务会话，不保存Apple私钥/Developer Token/MUT。服务MUT用启动时随机AES-GCM密钥加密内存存储，不落磁盘；重启即失效。App再次读取storefront和一项资料库列表成功后才显示“连接成功”。
7. 只读资料页支持当前账号歌单、歌曲分页、地区目录歌曲搜索、下拉同步。只保存本页内存结果，不自动改SQLite。已有“自建歌单→导入其他软件的歌单→Apple Music”继续分页预览、匹配、确认后持久化；元数据导入不等于音频迁移。
8. 原生MusicKit备用独立保存enabled/verified与状态，单独验证，不使用网页会话。两种模式按用户最近选择读取，登录原生不暗中切换到网页，网页成功不更改原生播放资格。
9. 取消、断开、重复连接使用操作代次防止晚到回调恢复已取消状态。待处理信息在Keychain，可在App终止重开后继续回调；十分钟到期或服务器重启要求重新授权，不自动重开浏览器。

## 安全与部署约束

- 固定只读Apple API路径，拒绝任意URL/写入、重定向、过长输入、额外查询、错误分页；8MB响应、20秒Apple请求、单页最多100、上限5000。上游401报开发者服务不可用，403报音乐访问拒绝，404报删除/无权限，429限流；不转发可能含敏感内容的原始错误体。
- 同源Origin校验、CSRF、一次bootstrap/一次code、Strict cookie、安全头、无CORS通配、无日志中间件/分析脚本。developer JWT是web SDK必需的可见短时凭证，其签名私钥从不出服务器；不能把“网页需要Developer Token”误解为应在App源码硬编码Token。
- 代码不自行写浏览器MUT到localStorage或日志；MusicKit JS可能自行管理浏览器授权，网站撤销入口调用官方unauthorize。本机断开删除本机及relay会话，不谎称撤销设备Apple账号/系统权限或所有浏览器的授权。
- 本服务为单实例、有界内存：最多4096待处理flow、4096会话、4096限流键，按到期清理，每地址每分钟90请求。反代下RemoteAddr可能是同一个loopback，届时该限制相当于整体限流；不信任客户端伪造X-Forwarded-For。生产反代应另加可信IP限流、连接/资源限制与TLS。多实例需替换为共享、加密、带原子兑换/撤销的存储后再做水平扩展，不能直接多副本轮询。
- 服务端不保留用户身份明文、密码或账号档案；不提供下载/DRM/播放代理。是否具备个人资料库访问取决于Apple实际账号/授权/服务资格。

## 后续部署步骤（本轮未执行）

1. 加入Apple Developer Program，登记自己的Media ID并启用MusicKit，创建关联的Media Services key。将.p8放服务器受限文件目录，不能提交Git或发到聊天。
2. 编译独立服务：`go build -o apple-music-relay ./cmd/apple-music-relay`。通过部署平台的环境变量/秘密管理提供：

   ```text
   APPLE_MUSIC_ORIGIN=https://music.example.com
   APPLE_TEAM_ID=<自己的10位Team ID>
   APPLE_MEDIA_KEY_ID=<自己的10位Key ID>
   APPLE_MEDIA_KEY_FILE=/etc/musicdl-secrets/AuthKey.p8
   APPLE_MUSIC_CALLBACK=com.guohuiyuan.musicdl.apple-login://callback
   ```

3. 服务只监听127.0.0.1:8787。用可信HTTPS反代提供上述域名；关闭此站点的请求体、Cookie、Authorization及回调query访问日志。保证有效证书和TLS；不暴露loopback服务到公有HTTP。运行代码不会替你购买、申请或配置Apple服务。
4. 在App账号页填写**自己的**HTTPS裸域名，或构建时填写Info.plist公开AppleMusicRelayOrigin；不填Token/密钥。校验失败时先核对服务/v1/config，再核对开发者服务。此公开地址是信任边界，不建议填写陌生服务。
5. 默认custom scheme不需Associated Domains服务能力，仍需有效iOS安装签名；它不能替代服务器的付费开发者服务资格。可选Universal Link：回调设为`https://music.example.com/apple-music/return`，签名工程另配置`applinks:music.example.com`的Associated Domains，并在网站 `/.well-known/apple-app-site-association` 仅关联`/apple-music/return`与真实`TeamID.BundleID`。本轮不修改现有签名或Actions；须按真实资格配置后在设备验证。
6. 若Universal Link没有打开App，页面只提示检查关联配置，不把浏览器页面显示当作原生连接完成。返回App可取消并重新连接；不要反复点击过期code。
7. 按下述矩阵逐项真实验收；尤其检查iPhone默认Safari、取消Apple弹窗、2FA、用户拒绝、网络断开、App终止重开、重复code、撤销后API拒绝。

## 兼容性、测试与回退

不迁移SQLite，不覆盖旧歌单；新增独立Keychain service及公开UserDefaults键。原有Spotify协议、搜索后端、来源、播放器、后台/锁屏/控制中心/媒体岛逻辑保持。NativeRoot仅加onOpenURL/onContinueUserActivity。旧系统Apple授权标志保留，用户仍可点系统备用重新验证。

协议测试使用明显的虚构令牌与URLProtocol/HTTP transport，测试成功仅证明状态机与安全协议，不冒充Apple账号成功。Go涵盖JWT签名/origin/时限、完整协议/双资料验证、错误MUT、取消/到期、重放、并发兑换、取消期间上游返回、CSRF、限定API；Swift涵盖无配置、PKCE/回调、重复、取消、恢复、断开/Keychain失败、错误原因与浏览器/原生隔离。UI增加真实无配置入口和原有页面备用按钮，未用虚构Apple账号制造连接截图。

Build52 attempt2已完成编译/自动化与交付核验，详见末尾最终结果；明确未验：付费服务配置、真实Apple授权/密码/2FA、浏览器MUT上游可用性、Safari/Universal Links往返、个人歌单与目录真实请求、本轮iPhone媒体回归。首次部署还需校准Apple授权涉及的域名/CSP要求并观察真实状态，不宣称静态安全策略已覆盖未来Apple变更。

回退以revert本轮提交为主，不删用户库、不卸载App；新Keychain条目在回退前可通过断开清理。服务停机将使其短时会话失效，App显示需重连，已有导入数据仍在SQLite。下一轮先读PROJECT_STATUS.md、本报告与git log。


### 本地验证记录

2026-11-14：relay Go九个顶层用例及六个上游状态子用例通过；go vet通过。网页Node6/6（显式手势、令牌不进URL、上游错误脱敏、原始SDK错误不显示、取消返回、官方unauthorize、无效fragment），原桥接Node6/6，IPA格式7/7；原Go四包通过。当时待macOS执行的Swift新增16项协议/状态测试，后续均通过，成功fixture不代表Apple成功。Info.plist已解析验证，原Spotify scheme、Bundle占位、后台audio保留，Apple公开服务地址为空。

Build49/e4c1ab8启动原签名/Actions流程用于编译检查；随后补充网页取消后的state回调、错误脱敏、过期/断开保护和额外Swift测试。中间构建不交付，最终受测提交与结果后续记录。


后续复查修正：失败回调保留待处理请求时仍展示取消；“重新授权”明确取消旧flow后创建新flow；迟到的服务验证不会覆盖已断开状态；HTTPS证书失败与请求超时提供具体建议。Build49在安全补丁取代后被原并发策略取消；Build50/b6ea206为上述复查前中间版本，最终以更新提交构建为准，不能将任一未完成轮次算通过。


本地Windows的Go race检查因当前CGO/GCC不可用而未执行，不写作通过。新增独立`.github/workflows/apple-music-relay.yml`，仅测试/编译可选服务与网页，不更改原ios-native.yml或签名；在Linux开启CGO运行-race、vet及Node协议测试，不需要账号、密钥或部署权限。当时应用源码ec8172a，Build51运行43545154563，后被8e9bb4b取代取消；仅构建文档/额外测试工作流的后续提交不改变该IPA应用源码。


### 真实验收矩阵（与协议测试分开）

| 路径 | 本轮证据 | 当前结论 |
| --- | --- | --- |
| 无HTTPS服务/开发者资格 | 客户端配置检测、Swift用例、真实无配置UI19.121秒通过 | 不应打开普通账号登录冒充授权，显示配置不可用 |
| Apple网页账号、密码、2FA与同意权限 | 没有真实资格、密钥、服务和账号授权；仅官方文档 | 未验证成功，禁止写作已接通 |
| 浏览器成功后换取App会话并验证资料库 | Go/Swift传输fixture与安全协议测试 | 协议已测，非真实Apple授权 |
| 用户取消/拒绝/超时、重放、断开 | fixture单元测试和网页状态测试 | 代码路径已测；真实Apple弹窗与Safari仍待验 |
| 默认Safari从后台返回App | 已注册scheme、state/S256、Keychain恢复与URL处理 | iPhone外部浏览器交互未验证 |
| Universal Links | App handler和部署说明，未添加虚假签名能力 | 需真实域名AASA和Associated Domains签名，未验证 |
| 歌单/资料库歌曲/目录搜索/导入 | 正式只读API请求及现有导入通道 | 真实浏览器会话读取未验证；接口拒绝时如实报错 |
| 原生系统备用 | 保留独立MusicAuthorization与服务探测 | 系统权限不代表付费开发者服务或完整播放已可用 |
| 原播放器/后台/锁屏/控制中心/岛 | 生产逻辑未改，重跑UI13通过/2跳过 | 首次深色暂停失败留档，真机未验 |

可选AASA示例（替换为真实签名Team ID和Bundle ID，由HTTPS站点提供，不放秘密）：

```json
{"applinks":{"details":[{"appIDs":["TEAMID.com.guohuiyuan.musicdl.nativedesign"],"components":[{"/":"/apple-music/return"}]}]}}
```

示例不是已部署的域名绑定；以手机实际签名identity为准，不能假定SideStore改签后的ID仍与示例相同。


当前受测应用源码更新为8e9bb4b24d0ddd45c9a29180e5c2b7f6997e7676，Build52 / 43545576995。最后修正十分钟过期清理不能将旧结果写回新授权，并避免定时任务取消自身导致远端清理被中断。Build49–51为被修订取代的中间轮次，不交付。独立服务CI [43545288229](https://github.com/yann359/go-music-dl/actions/runs/43545288229)全部通过（-race/vet/网页Node6/独立编译），源码50eee53，服务源码与8e9bb4b逐字相同；日志外层outputs/apple-music-browser/relay-ci.log，SHA256 f59a53728924e4083d208a65388fc57d55a9e1da26971aed3c55f769d8d79815。当时iOS仍在验证；最终attempt2结果见下。


### Build52 attempt1 实际失败记录

应用源码8e9bb4b；设备Release/模拟器成功，Swift102/102（含新增Apple浏览器16项）全部通过。UI15项中12通过、2跳过、1失败：新Apple真实无配置页面23.545秒通过，双入口账号测试55.085秒通过，原歌单双选/文本/重启76.770秒通过。失败在原testColdEmptyPlayerNavigationAndPlaybackLifecycleDark的line180：从实际AX可见框(311,819,44,44)点击(333,841)后，五秒内仍为“正在播放”，暂停未成立。后续真实展开/清空、浅色、媒体修复及搜索均通过；不能将此次整体称为通过。

报告artifact14095375814，194,222,410字节，SHA256 3f224f46fcbaa8f509dcfb5ce0c68310354a6e161fad07c400373c786071d73f，已验服务器digest与ZIP CRC。实际看过Apple无配置页面、深色附件截图、录屏30秒帧和AX文本；失败录屏build52-409A91EE-729D-4ED3-A08A-B048171BFD63.mp4保留外层outputs/apple-music-browser。原始日志build52-failed.log，SHA256 9d55ad9804d2988528180f51e64854ce9c167fd7fd20530a0165df8865a62250。AudioEngine/PlayerViews/NativeAppModel与345818e无修改，不凭单次测试推断为Apple授权回归。已先重跑同提交、同断言、同签名/Actions流程，以核对是否重复；若再次失败再继续依据实际证据处理，不交付失败轮次。


### Build52 attempt2 最终结果与交付

- [同提交完整重跑成功](https://github.com/yann359/go-music-dl/actions/runs/43545576995)，job132305398760，源码8e9bb4b24d0ddd45c9a29180e5c2b7f6997e7676。所有构建、测试、上传步骤成功。未改变应用/测试源码、暂停断言、限时、播放器或原Actions取得通过。
- Swift102/102（含Apple浏览器协议16项）通过；UI共15项中13通过、2跳过、0失败。真实无配置Apple页面19.121秒通过；深色暂停/展开/清空56.645秒、浅色52.055秒通过；原歌单双选/保存/文本确认/终止重启90.527秒通过。系统媒体岛轻点/长按因模拟器不可定位跳过，不算真机通过。首次深色暂停点击失败继续保留为设备复核风险，不将重跑解释成已证明根因或修复。
- 原Go四包、桥接Node6、IPA格式7通过；真实C ABI搜索本轮34首、首779ms/全部1840ms/热缓存0ms、三来源缓存，仅此云端样本，不是iPhone性能。独立relay Linux race/vet、网页Node6与服务编译通过；Windows实际编译启动缺配置服务退出码1，明确提示配置服务器密钥，未启动监听。无真实Apple账号成功样本。
- 本地IPA ../outputs/ios-release-build/build52/MusicDL-Build52.ipa；14,760,113字节，SHA256 dfc00e5e63d6b2803cf9734d865ed462e59537457170b8974fe9070a1681c561。[云端IPA、对应源码、许可证](https://github.com/yann359/go-music-dl/actions/runs/43545576995/artifacts/14096875586)。仅更名、字节不变，原Bundle ID/MusicDL、1.0.0/Build52、arm64 iPhoneOS、iOS18+、后台audio、未签名。沿用原SideStore身份或有效签名覆盖安装，不需卸载；没有操作手机重签/安装。
- IPA artifact14096875586：19,871,160字节，SHA256 72b2648bdfe2623c5407acdaee4e3a47c8351bced8e77069d4958945e13d158a；成功报告artifact14096166076：156,314,781字节，SHA256 dc11f9313146c9200336b39bfc668ebd5788ef45d4a57d4b2a6103d4c5f357ce。均实际下载核对服务器digest与ZIP CRC。IPA通过原verify-ipa.py，CI与本地JSON一致，附带hash、source SHA、源码ZIP CRC及20份本轮改动与固定提交逐字一致。封包AppleMusicRelayOrigin为空，独立Apple/Spotify callback scheme均在。
- 最终十张关键截图已实看：Apple主入口/服务配置不可用、独立系统备用、浅深附件暂停与清空、原歌单双选/预览/实际完成/重启后保留。截图保留外层outputs/ios-release-build/build52/screenshots；[交付JSON](verification/apple-music-browser-build52.json)标注具体已看文件，不将截图当作Apple授权成功。
- 原始重跑日志build52/build.log，1,111,579字节，SHA256 56f492e7a8e7495ef682d89cd23a0ff85b7600107d580d0d69fa6b91cf24d036。环境Xcode26.6/SDK26.5、iPhone17 Pro Max/iOS26.5模拟器。最终文档在构建后单独提交，App/测试代码在受测提交后不变。
- 真实可用边界：本包提供真实配置检测与入口，当前无开发者资格/HTTPS服务时显示不可用。浏览器账号/密码/2FA/音乐授权、真实MUT访问、歌单/目录读取与导入、Safari往返尚未验证；Universal Links需AASA与签名资格；原生MusicKit与完整播放能力独立。服务端单实例、24小时/重启失效、限流和断网清理/CSP域名还需部署后验收；本轮没有发布或部署服务。
