import Foundation
import Security

/// SSH 密码的唯一存放处。login keychain 的 ACL 绑定创建者的代码身份;
/// askpass 走同一个可执行文件,因此读取无弹窗,而其他进程读取会触发系统授权。
enum KeychainStore {
    static let service = "app.helm.ssh"

    private static func baseQuery(for alias: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
        ]
    }

    @discardableResult
    static func setPassword(_ password: String, for alias: String) -> Bool {
        let data = Data(password.utf8)
        let query = baseQuery(for: alias)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Helm SSH — \(alias)"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func password(for alias: String) -> String? {
        var query = baseQuery(for: alias)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只查属性不取数据,不会触发授权弹窗,用于 UI 显示“已保存”状态。
    static func hasPassword(for alias: String) -> Bool {
        var query = baseQuery(for: alias)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func deletePassword(for alias: String) {
        SecItemDelete(baseQuery(for: alias) as CFDictionary)
    }
}
