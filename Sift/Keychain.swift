import Foundation
import OSLog
import Security

/// Stores the Fastmail API token in the keychain, synced through iCloud Keychain
/// so the Mac and iPhone share one sign-in.
enum Keychain {
    private static let service = "com.markschmidt.Sift.fastmail-token"
    private static let log = Logger(subsystem: "com.markschmidt.Sift", category: "keychain")

    /// iCloud Keychain. Needs a keychain access group, which comes from the
    /// provisioning profile (on the Mac, from Sift-macOS.entitlements).
    private static var syncedQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    #if os(macOS)
    /// This Mac's login keychain, for builds signed without a profile, which
    /// can't use iCloud Keychain. Not synced, but survives rebuilds.
    private static var localQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
    #endif

    static func token() -> String? {
        if let token = read(syncedQuery, from: "iCloud Keychain") { return token }
        #if os(macOS)
        if let token = read(localQuery, from: "the login keychain") { return token }
        #endif
        return nil
    }

    static func save(token: String) {
        deleteToken()
        var item = syncedQuery
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status != errSecSuccess else {
            log.info("Saved the Fastmail token to iCloud Keychain")
            return
        }
        log.error("Couldn't save the Fastmail token to iCloud Keychain (OSStatus \(status, privacy: .public))")
        #if os(macOS)
        var local = localQuery
        local[kSecValueData as String] = Data(token.utf8)
        let localStatus = SecItemAdd(local as CFDictionary, nil)
        if localStatus == errSecSuccess {
            log.info("Saved the Fastmail token to the login keychain instead")
        } else {
            log.error("Couldn't save the Fastmail token to the login keychain either (OSStatus \(localStatus, privacy: .public))")
        }
        #endif
    }

    static func deleteToken() {
        SecItemDelete(syncedQuery as CFDictionary)
        #if os(macOS)
        SecItemDelete(localQuery as CFDictionary)
        #endif
    }

    private static func read(_ base: [String: Any], from place: String) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.error("Couldn't read the Fastmail token from \(place, privacy: .public) (OSStatus \(status, privacy: .public))")
            }
            return nil
        }
        log.info("Loaded the Fastmail token from \(place, privacy: .public)")
        return String(data: data, encoding: .utf8)
    }
}
