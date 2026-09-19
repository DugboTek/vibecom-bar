import Foundation
import Testing

@testable import VibecomBarCore

/// The fast path must agree with Foundation's own ISO 8601 parser exactly.
@Suite("Timestamps")
struct TimestampTests {
    private func reference(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    @Test(
        "matches Foundation for every shape the transcripts and APIs use",
        arguments: [
            "2026-09-19T14:21:49.595Z",
            "2026-09-19T17:56:51Z",
            "2026-09-19T19:20:00.689272+00:00",
            "2026-09-26T03:00:00.689294+00:00",
            "2026-01-01T00:00:00-05:30",
            "2024-02-29T23:59:59.999Z",
            "1999-12-31T23:59:59+14:00",
        ])
    func matchesFoundation(_ string: String) throws {
        let fast = try #require(ISO8601.fastDate(from: string))
        let expected = try #require(reference(string))
        #expect(abs(fast.timeIntervalSince(expected)) < 0.001)
    }

    @Test("declines shapes it does not understand instead of guessing", arguments: [
        "", "not a date", "2026-09-19", "2026-13-01T00:00:00Z", "2026-09-19 14:21:49Z", "2026-09-19T14:21:49",
    ])
    func declinesUnknownShapes(_ string: String) {
        #expect(ISO8601.fastDate(from: string) == nil)
    }
}
