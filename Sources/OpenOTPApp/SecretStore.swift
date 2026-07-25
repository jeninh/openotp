import Foundation
import Security

enum SecretStore {

    private static let service = "com.openotp.app"

    // One-time import of the pre-Keychain plaintext store (secrets.json).
    // The file is removed only after every entry lands in the Keychain, so a
    // partial failure keeps it around for the next launch to retry.
    private static let migrateLegacyFile: Void = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let file = base.appendingPathComponent("OpenOTP/secrets.json")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if dict.allSatisfy({ write($0.value, for: $0.key) }) {
            try? fm.removeItem(at: file)
        }
    }()

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        _ = migrateLegacyFile
        return write(value, for: key)
    }

    static func get(_ key: String) -> String? {
        _ = migrateLegacyFile
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        _ = migrateLegacyFile
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
