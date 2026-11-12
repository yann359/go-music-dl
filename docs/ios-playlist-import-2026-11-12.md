# MusicDL iOS 歌单导入：实现、来源证据与验收

## 范围与架构

基线 cf62e57；备份 backup/pre-playlist-import-20261112；开发 codex/playlist-import。先读 PROJECT_STATUS.md、历史提交、NativeScreens/NativeClient/AudioModel/SearchSession、Go native_client/collection、Spotify 会话与原有工作流。没有更换框架或播放器。

SwiftUI 原生界面 → NativeClient → 现有 C ABI → Go；手工歌单通过 SQLite Collection/SavedSong 存储，历史 imported 类型仅保存外部引用。本次两个入口只允许编辑手工歌单。复用原搜索后端、来源注册、搜索取消/防抖与最多三来源并发；复用 Song、source+id、extra 和同一 AudioEngine 队列。本地与在线 ID 在各自来源命名空间内，不把名称当作歌曲 ID。原 AudioEngine、MPNowPlayingSession、后台音频、系统控制和灵动岛代码未改。

新分层：PlaylistImportService（预览/匹配/恢复）、PlaylistImportRepository（独立检查点）、SongMatchingService（纯元数据匹配）、PlaylistImportView（原生交互）、Go playlist_import（解析/批次事务）、playlist_import_provider（受限平台分页）、ApplePlaylistImport（MusicKit）。

## Folia 最新源码实际核对

2026-11-12 GitHub API 查询 main 为 [a44758bbc02929225ca7304b5a4c4580d7b4e87b](https://github.com/chthollyphile/folia-major/commit/a44758bbc02929225ca7304b5a4c4580d7b4e87b)，release v0.7.28。浅克隆传输未完成，随后按固定提交从 raw.githubusercontent.com 实际读取源文件，避免将网页介绍当作实现。参考文件在工作区外层 outputs/folia-source，未打入 App。

| 指定文件（均存在） | 当前实现与 MusicDL 映射 |
| --- | --- |
| src/services/onlineMusic/omni.ts | 汇总 providerRegistry 的能力及歌曲来源引用，统一操作。MusicDL 保留 core 来源注册和 NativeClient，不新建重复搜索后端。 |
| src/types/onlineMusic.ts | ProviderCapabilities、PlaybackSourceRef、ProviderCollection、ProviderPage 等区分来源、媒体 ID、能力、分页与播放。MusicDL 新建 ImportTrack/ImportRow，保留原 Song，明确“信息匹配”和“可播放验证”不同。 |
| src/services/onlineMusic/netease/neteaseProvider.ts | catalog.getPlaylistTracks 调 neteaseApi.getPlaylistTracks(id,limit,offset)，另有50首详情批次与登录状态错误处理。MusicDL 用公开曲目索引+50首详情请求，并检查完整性。 |
| src/services/onlineMusic/qq/qqProvider.ts | 自有歌单带授权的真实分页、我喜欢单独接口；公开收藏/分享歌单走匿名读取后切片，返回 nextOffset/hasMore，空页停止。MusicDL 实际验证公开接口 song_begin/song_num，拒绝重复/空页，未复用私有登录实现。 |
| src/services/onlineMusic/spotify/spotifyCatalog.ts | fetchPlaylist GraphQL 的 offset/limit、空/不可用行及 totalCount；spotifyTransport.ts 明确依赖 window.electron.spotifyRequest。MusicDL 使用已有官方 PKCE 与 /v1/playlists/{id}/items，不移植 Electron Web Player token。 |
| src/services/onlineMusic/ytm/ytmCatalog.ts | createYtmPager、continuation、公有读取与账号路径、mix/album 区分；ytmTransport.ts 依赖 Electron IPC。不能推出 iOS MusicDL 已获歌单读取权限，当前不接通。 |
| src/services/localPlaylistFileService.ts | 本地 M3U 路径归一化、唯一/歧义区分、歌单导出。MusicDL 独立实现已有本地库路径匹配，不读取外部路径、不下载流地址；本轮不增加未要求的导出模块。 |
| src/components/app/AddToPlaylistHost.tsx | 独立选择器与批次选择，按 local/Navidrome/provider 能力确定目标；不绑定播放器面板。MusicDL 歌单详情打开原生选择器，搜索/多选与播放状态分离。 |

额外核对 providerRegistry.ts、网易 netease.ts、Spotify/YouTube transport、酷狗 provider 与 onlineMusic/README.md。GitHub recursive tree 实际列出 appleMusic、bodian、fnmusic、kugou、netease、qishui、qq、spotify、ytm 等 provider 文件；不把文件存在视为每平台具备合法/稳定的 iOS 歌单 API。

Folia 和 MusicDL 的 LICENSE 均为 GNU AGPL v3 文本。本次参考架构、独立实现，未复制 Folia 代码或整套播放器。保留现有署名、完整许可证、匹配源码归档和构建脚本；若后续实际移植代码，需另核对具体文件头、依赖许可及署名和相应源码义务。这里不声称 AGPL 自动授予音乐内容或第三方服务访问权。

## Soundiiz 与平台状态

[Soundiiz webapp](https://soundiiz.com/webapp/home) 未登录重定向到登录页，未声称查看了登录后的 UI。[官方 API](https://soundiiz.com/api) 与 [Playlist Import API](https://soundiiz.com/api/doc/public_import) 是准备向 Soundiiz 导入的临时链接，不是 MusicDL 全平台免费读取后端。当前官方页还列出 Creator 订阅的预览 User API；本项目不依赖它，不向 Soundiiz 上传用户曲目。采用自身“读取→预览→匹配→复核→确认→结果/重试”流程。

| 平台 | 源码/官方依据 | 实际状态 |
| --- | --- | --- |
| 网易云 | Folia provider；MusicDL 原有网易来源；公开 music.163.com/api/v6/playlist/detail 与 /api/song/detail | 已真实完整读取公开热歌榜 3778678，200首/4页，写入隔离数据库并重开。公开接口非稳定官方开放 API 合约；受限、私有、删除歌单报错，不补造结果。 |
| QQ | Folia provider 与现有 music-lib QQ 实现；c.y.qq.com 的公开歌单接口 | 9209322004，100首/2页，song_begin=0/50，真实曲目不同，已完整持久化。无公开稳定 SLA；不读取私有歌单。 |
| Spotify | [官方 Playlist Items](https://developer.spotify.com/documentation/web-api/reference/get-playlist-items)、[PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)、现有 Keychain 原生会话 | 已实现链接、账号歌单选择和分页，复用既有授权；无本轮可用账号，成功读取/导入未验证。受 scopes、账号/开发模式、接口政策限制，401/403/429 显示实际失败。 |
| Apple Music | [MusicDataRequest](https://developer.apple.com/documentation/musickit/musicdatarequest)、[Library Playlists](https://developer.apple.com/documentation/applemusicapi/get-all-library-playlists)、[Catalog Playlist](https://developer.apple.com/documentation/applemusicapi/get-a-catalog-playlist) | MusicKit 请求系统授权后的目录/个人歌单，分页实现；本轮无有效授权设备/签名，成功路径未验证。保留原签名配置，不用新 entitlements 假装修好访问。 |
| 酷狗 | 实际读 Folia kugouProvider.ts；项目有酷狗搜索/播放来源 | 未完成适用于本 App 的歌单读取权限和端到端验证，未开放链接入口；文件/文本可用。 |
| YouTube Music | Folia continuation + Electron IPC；[YouTube 官方 playlistItems](https://developers.google.com/youtube/v3/docs/playlistItems/list) 提供另一种有配额/授权的接口 | 当前未配置官方开发者接入，未冒用 Folia 桌面登录或推断两种目录完全相同；文件/文本可用。 |
| SoundCloud | [官方 API guide](https://developers.soundcloud.com/docs/api/guide)：应用注册、OAuth、分页 | 尚无该平台应用注册与令牌，未开放直接链接；文件/文本可用。Folia provider tree 未见同名平台，不能声称其支持。 |
| 其他 | Folia 中的波点、汽水、方糖等 provider，另有本地/Navidrome | 未新增未经验证来源，原项目其他来源仍可被搜索匹配。 |

## 数据、安全与恢复

- ImportTrack 保留歌名、歌手、专辑、时长、来源/歌曲ID/歌单ID、ISRC、封面、本地路径；ImportRow 保存匹配状态、候选 Song（含 MusicDL 内部 source+id）、失败原因与提交状态。
- 文件与粘贴数据限制 5MB/5000 首，单字段4096字节。CSV 正确处理引号/换行并拒绝列数不一致；JSON 支持数组、tracks 或 songs；文本按“歌手 - 歌名”；M3U 解析 EXTINF，HLS EXT-X 清单明确拒绝。UTF-8/带BOM UTF-16，其他编码清楚报错。
- M3U 路径只在已有本地索引内匹配；精确路径优先，文件名仅唯一时自动选；歧义转手动。网络流行只保留元数据，不当作可迁移音频、不请求该地址。
- 歌曲匹配优先来源 ID/ISRC，并仍核对非空歌手、标题与版本；名称宽度、大小写、标点标准化，保留版本差异；专辑和时长加权，多种可能录音/歌手缺失不强行匹配。Live、Remix、伴奏、翻唱、不插电、重制等不得与原版混同。未知候选可手动选择，搜索仍用现有引擎。
- 歌单 URL 只接受明确平台完整 HTTPS 域名和路径，拒绝用户信息、端口、IP/伪装域名、非法ID和短链接；外部网络请求固定 HTTPS API 域名，禁重定向，20秒超时、8MB响应限制。不接收任意 API URL，不复制密码/Cookie，不绕过DRM或付费。
- 逐页保存检查点、逐首匹配，三来源并发，上游页间350ms、曲目间300ms。429 停止并提示稍后人工重试，不自动洪泛重试；已有内容保留。单次读取上限5000；匹配可很耗时，支持取消和继续。
- 预览存在 Application Support/PlaylistImports/<数字歌单ID>.json，原子写、解锁后文件保护；与SQLite完全分开。每页、每10首及暂停/后台保存；进后台主动暂停，不承诺任意后台持续跑网络。最多九首未落检查点的元数据匹配会在进程被强杀后重做，已存数据库不会丢。
- 用户明确确认后分批100首写入现有SavedSong，单批事务（最多200）。source+id唯一约束及保守ISRC+歌名+歌手去重保护重复点击和丢响应重试；失败批次全回滚，之前成功批次不丢。确认前不动目标歌单。
- 未匹配行使用 import-metadata 来源保存，sourceAvailable 为false，原播放队列自动跳过；显示暂不可播放，绝不声称已验证音频。后续手动匹配只替换该导入元数据占位，保留原曲序；从歌单移除仅删关联，不动文件和其他歌单。
- 不改SQLite结构。新字段在已有 Extra 中，musicdl_import_metadata、musicdl_match_state、musicdl_import_key、musicdl_playlist_order；原有来源 extra 保留。旧行排序保持原样，新批次按源顺序追加。独立预览版本校验/大小限制；不兼容或损坏则明确报错，不清空原库。

## 验证与当前边界

本地 Windows：Go ./internal/spotify ./internal/web ./internal/appshell ./core 通过；JS桥接6/6；IPA格式测试7/7。新增 Go 测试涵盖文件格式、错误/大文件/大歌单、URL白名单、重定向/429、批量事务回滚、重复、顺序、相册信息、库关闭重开、歌单隔离、占位替换。实际公开网络测试命令：

```powershell
$env:MUSICDL_IMPORT_LIVE='1'
..\.tools\go\bin\go.exe test ./internal/web -run TestPlaylistImport -v
Remove-Item Env:MUSICDL_IMPORT_LIVE
```

本轮已成功读取网易200+QQ100首并写入隔离临时SQLite，关闭重开保持300首；原始日志外层 outputs/playlist-import-go-tests.log。未使用真实用户歌单数据库/私有账号。

Swift 新增匹配版本/歌手/歧义/时长、UTF16、仓库恢复/损坏、预览不写库、失败保留、取消防串写、重复保存测试；原 C ABI 集成测试增加真实搜索结果批量保存/重读/重复/移除、真实文件和文本解析。新增非preview UI流程创建歌单→两个入口→文本预览→明确确认→App终止重启→未匹配信息仍在；这是真实持久化UI路径，但输入是测试元数据，不代表外部播放。

macOS CI 编译、原生和UI结果及IPA：待本轮构建完成后补充；未通过前不得将新包称为验收成功。真机验证仍需：已创建歌单搜索多选、网易/QQ链接、系统文件选择、文本/自动及手动匹配、失败/后台/重启恢复、真实音源播放/切歌、后台整曲、锁屏/控制中心/媒体岛；并检查搜索、收藏无回归。Spotify/Apple无授权成功样本明确未验证。

## 回退与继续开发

代码回退到 backup/pre-playlist-import-20261112 可恢复旧行为；优先使用 git revert 本轮实现提交，保留后续工作。不清库、不卸载App。旧代码不会因新增 Extra 键读不懂而删数据；可能恢复旧排序，import-metadata仍为不可用来源。已导入曲目是新增关联，若要撤回，应在歌单逐项移除，不能恢复旧整库覆盖新数据。预览sidecar可以保留，重新升级可恢复。

下一轮先读 PROJECT_STATUS.md、本报告、git log 和新增代码，优先完成CI/真机验收、平台授权成功样本，再评估其他平台官方接入；不要重做AudioEngine或岛逻辑。
