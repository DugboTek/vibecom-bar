import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Single menu bar instance")
struct SingleInstanceLockTests {
    @Test("another launch cannot acquire the same lock")
    func excludesAnotherLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        let owner = try #require(try SingleInstanceLock.acquire(at: url))

        try withExtendedLifetime(owner) {
            let anotherLaunch = try SingleInstanceLock.acquire(at: url)
            #expect(anotherLaunch == nil)
        }
    }

    @Test("quitting releases the lock without deleting the shared file")
    func permitsRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var owner = try SingleInstanceLock.acquire(at: url)
        #expect(owner != nil)
        owner = nil

        #expect(FileManager.default.fileExists(atPath: url.path))
        let nextOwner = try #require(try SingleInstanceLock.acquire(at: url))
        try withExtendedLifetime(nextOwner) {
            let anotherLaunch = try SingleInstanceLock.acquire(at: url)
            #expect(anotherLaunch == nil)
        }
    }

    @Test("failure to open the lock is reported instead of allowing an unguarded launch")
    func reportsOpenFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try SingleInstanceLock.acquire(at: directory)
        }
    }
}
