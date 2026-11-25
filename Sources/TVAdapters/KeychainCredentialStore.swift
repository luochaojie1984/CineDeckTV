import Foundation
import Security

/// 密码只进 Keychain，绝不写进 JSON / UserDefaults / 日志。
public enum KeychainCredentialStore {
    private static let service = "local.personal.cinedecktv"

    public static func save(password: String, accountID: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VFSErrorKeychain.storeFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw VFSErrorKeychain.storeFailed(status)
        }
    }

    public static func password(accountID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum VFSErrorKeychain: Error, Sendable, LocalizedError {
    case storeFailed(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .storeFailed(let status): return "钥匙串写入失败（OSStatus \(status)）"
        }
    }
}
