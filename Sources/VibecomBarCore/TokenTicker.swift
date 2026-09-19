import Foundation

/// Makes a count that arrives in bursts read like a live ticker: each new
/// reading is reached by climbing steadily across one update interval, so by
/// the time the next one lands the number has been moving the whole time.
public struct TokenTicker: Equatable, Sendable {
    private var from = 0
    private var to = 0
    private var start = Date.distantPast
    private var hasReading = false
    /// How long a climb takes; the same as the gap between readings.
    public let duration: TimeInterval

    public init(duration: TimeInterval = 5) {
        self.duration = duration
    }

    public mutating func receive(_ reading: Int, at now: Date) {
        let shown = value(at: now)
        guard hasReading, reading >= shown else {
            // First reading, or a new day starting from zero: no climb.
            from = reading
            to = reading
            start = now
            hasReading = true
            return
        }
        from = shown
        to = reading
        start = now
    }

    public func value(at now: Date) -> Int {
        guard to > from, duration > 0 else { return to }
        let progress = min(max(now.timeIntervalSince(start) / duration, 0), 1)
        return from + Int((Double(to - from) * progress).rounded(.down))
    }
}
