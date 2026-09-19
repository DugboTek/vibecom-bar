import Foundation
import Testing

@testable import VibecomBarCore

/// These touch the real keychain and the real disk, but only under names this
/// suite owns and cleans up.
@Suite("Live storage", .serialized)
struct LiveStoreTests {
    static let service = "build.vibecom.bar.test.\(UUID().uuidString)"

    @Test("stores and reads back a secret in the login keychain")
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore()
        defer { try? store.delete(service: Self.service) }

        try store.write(Data("hello".utf8), service: Self.service)

        #expect(try store.read(service: Self.service) == Data("hello".utf8))
    }

    @Test("overwrites an existing secret rather than failing on a duplicate")
    func keychainOverwrite() throws {
        let store = KeychainSecretStore()
        defer { try? store.delete(service: Self.service) }
        try store.write(Data("first".utf8), service: Self.service)

        try store.write(Data("second".utf8), service: Self.service)

        #expect(try store.read(service: Self.service) == Data("second".utf8))
    }

    @Test("reports a missing secret as nil, not as an error")
    func keychainMissing() throws {
        let store = KeychainSecretStore()

        #expect(try store.read(service: "build.vibecom.bar.test.absent") == nil)
    }

    @Test("lists the app's own keychain items so accounts survive a reinstall")
    func keychainListsByPrefix() throws {
        let store = KeychainSecretStore()
        defer { try? store.delete(service: Self.service) }
        try store.write(Data("x".utf8), service: Self.service)

        let found = try store.services(withPrefix: "build.vibecom.bar.test.")

        #expect(found.contains(Self.service))
    }

    @Test("creates missing folders and keeps credential files private to this user")
    func diskWriteIsPrivate() throws {
        let store = DiskFileStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-bar-test-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("nested/accounts.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(Data("{}".utf8), to: file)

        #expect(try store.read(file) == Data("{}".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test("replaces a file in one step so a crash cannot leave it half written")
    func diskWriteIsAtomic() throws {
        let store = DiskFileStore()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-bar-test-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("auth.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.write(Data("old".utf8), to: file)

        try store.write(Data("new".utf8), to: file)

        #expect(try store.read(file) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["auth.json"])
    }
}
