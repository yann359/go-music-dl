import Foundation
import Security

protocol AccountTokenStorage {
    func read() throws -> SpotifyTokens?
    func write(_ tokens: SpotifyTokens) throws
    func remove() throws
}

struct KeychainAccountStorage: AccountTokenStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.guohuiyuan.musicdl.spotify.oauth", kSecAttrAccount as String: "pkce-session"]
    }
    func read() throws -> SpotifyTokens? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let tokens = try? JSONDecoder().decode(SpotifyTokens.self, from: data) else { throw MusicAccountError.storage }
        return tokens
    }
    func write(_ tokens: SpotifyTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MusicAccountError.storage }
        } else if status != errSecSuccess { throw MusicAccountError.storage }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MusicAccountError.storage }
    }
}
