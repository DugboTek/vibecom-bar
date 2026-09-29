import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Activity log")
struct ActivityLogTests {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-log-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("activity.log")
    }

    @Test("appends timestamped lines to a private file")
    func appendsLines() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = ActivityLog(url: url)
        let date = Date(timeIntervalSince1970: 1_789_830_000)

        log.record("first", at: date)
        log.record("second", at: date)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
        #expect(text.contains(" first\n"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("rolls over instead of growing without bound")
    func rollsOver() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = ActivityLog(url: url, maxBytes: 200)

        for index in 0..<40 { log.record("line \(index) with some padding text") }

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size <= 200)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("line 39"))
    }
}
