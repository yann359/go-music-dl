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
5. 返回链接只有id/state/code，无Apple令牌。App严格核对scheme/host/path、重复参数、state、有效期，携verifier兑换。服务原子消费code，抵御重复兑换与自定义scheme被其他App截取后的使用。
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

构建和实际测试结果将在验证后追加。明确未验：付费服务配置、真实Apple授权/密码/2FA、浏览器MUT上游可用性、Safari/Universal Links往返、个人歌单与目录真实请求、本轮iPhone媒体回归。首次部署还需校准Apple授权涉及的域名/CSP要求并观察真实状态，不宣称静态安全策略已覆盖未来Apple变更。

回退以revert本轮提交为主，不删用户库、不卸载App；新Keychain条目在回退前可通过断开清理。服务停机将使其短时会话失效，App显示需重连，已有导入数据仍在SQLite。下一轮先读PROJECT_STATUS.md、本报告与git log。
