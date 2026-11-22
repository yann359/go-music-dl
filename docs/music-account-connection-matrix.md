# 音乐账号连接矩阵

2026-11-22。审计基线 dbf11ae / 已交付 Build 54，用户设备实际安装版本未知。下列“验证”列指实现采用的证据，本轮没有真实账号授权记录。

| 平台 | 授权与资格 | 账号验证与资料 | 个人歌单及收藏 | 完整播放 | 真机 / 真实授权 |
|---|---|---|---|---|---|
| Apple Music | 首选系统 MusicAuthorization；签名 App ID 启用 MusicKit。可选已部署的 MusicKit JS 网站 | MusicDataRequest 请求用户服务；Apple 不提供 Apple ID 昵称或头像 | /me/library/playlists 与 songs，分页；已有导入器。资料库歌曲与收藏是不同集合 | 本播放器未接入 DRM 完整播放 | 未测试 |
| Spotify | 自有应用公开 Client ID、PKCE、ASWebAuthenticationSession、Keychain。开发模式所有者 Premium，通常最多五名获准用户 | /v1/me 返回 ID、昵称，可用时有头像 | /me/playlists，受 scope 和平台模式限制；本轮不请求收藏歌曲权限 | 授权不提供整曲音频 | 未测试 |
| QQ 音乐 | 原依赖的 QQ、微信扫码内置第三方标识，原生桥接停止发起这两种流程；保留本人合法凭证。腾讯特定合作产品有音乐服务，未证实本 App 获开放 OAuth 资格 | 适配器只能探测歌单读取；没有独立身份接口 | Go 适配器，收藏列表依响应；不承诺收藏曲目 | 依原适配器与权利 | 未测试 |
| 网易云 | 既有兼容扫码及凭证，未证实第三方开放授权资格 | 兼容歌单接口，不能据此确认昵称或身份 | Go 用户歌单适配器；未验证收藏歌曲权限 | 依原适配器与权利 | 未测试 |
| 汽水 | 保留合法凭证输入；没有已验证可供本 App 使用的官方 OAuth | 兼容接口受平台限制 | 有 Go 歌单适配器，外部可用性未确认 | 依原适配器与权利 | 未测试 |
| 酷我 | 保留合法凭证配置；无已确认可用的官方个人授权 | 当前适配器没有身份验证接口 | 无用户歌单适配器；不展示虚构歌单 | 依原适配器与权利 | 未测试 |

## 开发者配置

1. Apple 原生：在 Certificates, Identifiers & Profiles 找到实际签名使用的显式 App ID，启用 MusicKit App Service，更新签名配置，再安装并允许媒体访问。MusicKit 自动管理开发者与用户令牌。单独写 entitlement 或用 SideStore 重签不能赋予账号服务资格。[Apple 服务设置](https://developer.apple.com/help/account/services/musickit/) · [自动生成令牌](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)
2. Apple 浏览器：MusicKit on the Web 面向网站；本项目可选中转需要自有 HTTPS 服务、Media ID、来源域和服务器密钥；原生路径独立运行。自定义 Scheme 负责返回，不是通用网页 Apple ID 登录。Universal Links 还需真实域名、AASA 和匹配签名。[用户令牌说明](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)
3. Spotify：在 Dashboard 注册自己的应用，登记页面中完整的回调地址，并将测试用户加入允许名单。将公开 Client ID 填入开发者配置，打开官方授权。禁止在 App 填入 Secret。自定义 Scheme 需由该应用后台接受。[官方回调说明](https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify) · [2026 配额](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
4. QQ 音乐：[腾讯物联网音乐服务](https://main.qcloudimg.com/raw/document/product/pdf/1081_67436_cn.pdf)有特定产品和接入范围。项目没有合作应用 ID 或授权合同的可验证证据。上线正式 QQ 音乐身份或收藏接口前需由平台确认本 App 接入资格、接口及 scope。其他兼容来源同样保留能力边界。

汽水与抖音可使用关联账号，但已核对的抖音登录和端内音乐收藏 scope 没有表明本 App 获得汽水个人资料库读取资格。[抖音能力概览](https://developer.open-douyin.com/docs/resource/zh-CN/dop/ability/common-solution)
