import Foundation
import Security

public enum StoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Account tokens live in the login keychain, never in a file this app writes.
public struct KeychainSecretStore: SecretStore {
    private let accessGroupLabel = "vibecom bar"

    public init() {}

    public func read(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw StoreError.keychain(status)
        }
    }

    public func write(_ data: Data, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: accessGroupLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    /// The legacy keychain would otherwise put up a password dialog for an
    /// item another build owns; with interaction off the call just fails.
    public func deleteIfSilent(service: String) {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        try? delete(service: service)
    }

    public func services(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let attributes = items as? [[String: Any]] ?? []
            return
                attributes
                .compactMap { $0[kSecAttrService as String] as? String }
                .filter { $0.hasPrefix(prefix) }
                .sorted()
        case errSecItemNotFound: return []
        default: throw StoreError.keychain(status)
        }
    }
}

public struct DiskFileStore: FileStore {
    private var manager: FileManager { FileManager.default }

    public init() {}

    public func read(_ url: URL) throws -> Data? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    public func remove(_ url: URL) throws {
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }
}
