import Foundation
import Security

/// The API key for the remote notes backend, in the Keychain.
///
/// Not UserDefaults: that file is world-readable inside the app container,
/// lands in every iCloud backup, and shows up in a shared session folder if
/// anyone ever syncs one. A key that bills the user's card doesn't belong in
/// any of those places.
///
/// `ThisDeviceOnly` — the key is not carried to a restored device. Re-entering
/// it costs one paste; a key silently resurrected onto a phone the user sold
/// costs money.
///
/// ponytail: one item, one account string, no generic wrapper. A second
/// credential can generalize this then.
enum RemoteCredential {
    private static let service = "com.digimata.quill-ios.remote-enhance"
    private static let account = "apiKey"

    static var key: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Store (or replace) the key. An empty string clears it, so the settings
    /// field can both set and unset without a second control.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Update first; SecItemAdd on an existing item fails with duplicate.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// `sk-ant-…········…api03` — enough to tell two keys apart, never enough
    /// to use. The settings row shows this instead of the key.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let edge = min(8, key.count / 4)
        return "\(key.prefix(edge))\(String(repeating: "•", count: 8))\(key.suffix(4))"
    }

    #if DEBUG
    /// Round-trip through the real Keychain. Wrong accessibility or a failed
    /// update-vs-add branch means the key silently doesn't persist, and the
    /// symptom is "remote notes stopped working after a relaunch".
    nonisolated(unsafe) private static var checked = false

    static func selfCheck() {
        guard !checked else { return }
        checked = true
        let original = key          // never destroy a real key the user set
        defer {
            if let original { save(original) } else { clear() }
        }

        assert(save("sk-ant-test-first"), "save failed")
        assert(key == "sk-ant-test-first", "key did not round-trip")
        // Second save must replace, not fail as a duplicate.
        assert(save("sk-ant-test-second"), "overwrite failed (add-vs-update branch)")
        assert(key == "sk-ant-test-second", "overwrite did not replace")
        // Whitespace from a paste must not become part of the key.
        save("  sk-ant-padded  ")
        assert(key == "sk-ant-padded", "whitespace survived into the stored key")
        // Empty clears, so one field can set and unset.
        assert(save(""), "empty save should clear")
        assert(key == nil, "empty save left a key behind")
        assert(clear(), "clear on an absent item must succeed, not error")

        assert(!masked("sk-ant-api03-abcdefghijklmnop").contains("efghijklm"), "mask leaked the middle")
        assert(masked("short").allSatisfy { $0 == "•" }, "short key not fully masked")
    }
    #endif
}
