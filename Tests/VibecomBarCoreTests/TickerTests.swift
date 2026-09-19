import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Token ticker")
struct TickerTests {
    static let start = Date(timeIntervalSince1970: 1_789_830_000)

    @Test("writes every digit, grouped so a ten-digit count still reads at a glance")
    func fullCount() {
        #expect(UsageFormatter.fullTokens(1_634_221_907) == "1,634,221,907")
        #expect(UsageFormatter.fullTokens(512) == "512")
        #expect(UsageFormatter.fullTokens(0) == "0")
    }

    @Test("shows the first reading straight away rather than counting up from zero")
    func firstReadingIsImmediate() {
        var ticker = TokenTicker()

        ticker.receive(1_000_000, at: Self.start)

        #expect(ticker.value(at: Self.start) == 1_000_000)
    }

    @Test("glides from the last reading to the new one instead of jumping")
    func glides() {
        var ticker = TokenTicker(duration: 5)
        ticker.receive(1_000, at: Self.start)

        ticker.receive(2_000, at: Self.start.addingTimeInterval(5))

        let middle = ticker.value(at: Self.start.addingTimeInterval(7.5))
        #expect(middle > 1_000 && middle < 2_000)
        #expect(ticker.value(at: Self.start.addingTimeInterval(10)) == 2_000)
        #expect(ticker.value(at: Self.start.addingTimeInterval(60)) == 2_000)
    }

    @Test("never runs backwards while it climbs")
    func monotonic() {
        var ticker = TokenTicker(duration: 5)
        ticker.receive(1_000, at: Self.start)
        ticker.receive(9_000, at: Self.start.addingTimeInterval(1))

        var previous = 0
        for step in 0...60 {
            let value = ticker.value(at: Self.start.addingTimeInterval(1 + Double(step) * 0.1))
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("carries on from where it is when a reading lands mid-glide")
    func retargetsSmoothly() {
        var ticker = TokenTicker(duration: 5)
        ticker.receive(0, at: Self.start)
        ticker.receive(10_000, at: Self.start)
        let shown = ticker.value(at: Self.start.addingTimeInterval(2.5))

        ticker.receive(20_000, at: Self.start.addingTimeInterval(2.5))

        #expect(ticker.value(at: Self.start.addingTimeInterval(2.5)) == shown)
        #expect(ticker.value(at: Self.start.addingTimeInterval(7.5)) == 20_000)
    }

    @Test("drops straight to the new day's count at midnight")
    func resetsAtMidnight() {
        var ticker = TokenTicker(duration: 5)
        ticker.receive(5_000_000, at: Self.start)

        ticker.receive(1_200, at: Self.start.addingTimeInterval(5))

        #expect(ticker.value(at: Self.start.addingTimeInterval(5)) == 1_200)
    }
}
