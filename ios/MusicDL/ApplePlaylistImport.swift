import Foundation
import MusicKit

/// Browser relay and native MusicKit are separate access modes.
/// Reuses the same playlist metadata/pagination/import pipeline.
enum ApplePlaylistImport {
    private static func read(_ path: String) async throws -> JSONValue {
        return try await MusicAccounts.shared.readApple(path)
    }
    private static func ref(_ link: String) throws -> (store: String, id: String, library: Bool) {
        guard link.count <= 2048, let u = URLComponents(string: link), u.scheme == "https", u.host?.lowercased() == "music.apple.com", u.user == nil, u.password == nil, u.port == nil else { throw NativeError.message("请使用 music.apple.com 的完整歌单链接") }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "playlist", let id = parts.last,
              id.count <= 100, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              (id.hasPrefix("pl.") || (parts[0] == "library" && id.hasPrefix("p."))) else { throw NativeError.message("这不是可读取的 Apple Music 歌单链接") }
        let library = parts[0] == "library"
        guard library || (parts[0].count == 2 && parts[0].allSatisfy({ $0.isASCII && $0.isLetter })) else { throw NativeError.message("无效的 Apple Music 地区") }
        return (parts[0].lowercased(), id, library)
    }
    static func playlists(offset: Int) async throws -> (items: [NativeCollection], more: Bool) {
        guard offset >= 0, offset < 5000 else { throw NativeError.message("账号歌单数量已达读取上限") }
        let value = try await read("/v1/me/library/playlists?limit=50&offset=\(offset)")
        guard case .array(let data) = value["data"] else { throw NativeError.message("Apple Music 未返回歌单列表") }
        let items = data.map { row in
            NativeCollection(id: row["id"].stringValue, name: row["attributes"]["name"].stringValue,
                             source: "apple", link: "https://music.apple.com/library/playlist/" + row["id"].stringValue)
        }
        return (items, !value["next"].stringValue.isEmpty)
    }
    static func page(link: String, offset: Int) async throws -> ImportPlaylistPage {
        let r = try ref(link)
        guard offset >= 0, offset < 5000 else { throw NativeError.message("单次最多导入 5000 首") }
        let base = r.library ? "/v1/me/library/playlists/\(r.id)" : "/v1/catalog/\(r.store)/playlists/\(r.id)"
        let head = try await read(base)
        guard let item = head["data"].arrayValue.first else { throw NativeError.message("Apple Music 歌单不可访问，可能为私有、已删除或未授权") }
        let value = try await read(base + "/tracks?limit=100&offset=\(offset)")
        guard case .array(let data) = value["data"] else { throw NativeError.message("Apple Music 未开放曲目列表") }
        let tracks: [ImportTrack] = data.enumerated().map { index, row in
            let a = row["attributes"]
            let id = row["id"].stringValue.isEmpty ? "unavailable-\(offset + index)" : row["id"].stringValue
            return ImportTrack(id: "apple:" + id, title: a["name"].stringValue.isEmpty ? "不可用曲目" : a["name"].stringValue,
                               artist: a["artistName"].stringValue, album: a["albumName"].stringValue,
                               duration: Int(a["durationInMillis"].numberValue / 1000), source: "apple", sourceID: id, playlistID: r.id,
                               isrc: a["isrc"].stringValue, cover: artwork(a["artwork"]), localPath: "")
        }
        let more = !value["next"].stringValue.isEmpty
        guard !more || !tracks.isEmpty else { throw NativeError.message("Apple Music 分页未返回新曲目") }
        // Some Apple responses omit total; -1 explicitly means unknown.
        let totalValue = value["meta"]["total"]
        let total = totalValue == .null ? (more ? -1 : offset + tracks.count) : Int(totalValue.numberValue)
        let revision = item["attributes"]["lastModifiedDate"].stringValue
        return ImportPlaylistPage(title: item["attributes"]["name"].stringValue, cover: artwork(item["attributes"]["artwork"]), total: total, tracks: tracks, next: offset + tracks.count, more: more, revision: revision.isEmpty ? nil : revision)
    }
    private static func artwork(_ value: JSONValue) -> String {
        value["url"].stringValue.replacingOccurrences(of: "{w}", with: "300").replacingOccurrences(of: "{h}", with: "300")
    }
}
