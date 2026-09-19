import Foundation

/// Tokens for one request, split the way pricing treats them.
public struct TokenUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0, cacheWrite1hTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    public var total: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }
}

/// A port of vibecom's `cli/src/pricing.ts`: what a token volume costs at
/// today's published list price. It is an API-equivalent figure, not a bill —
/// nobody on a flat subscription was charged it. Keep the two tables in step.
public enum Pricing {
    /// USD per million tokens, per token class.
    public struct Rate: Equatable, Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        /// Requests above 272K input receive OpenAI's long-context uplift.
        let longContext: Bool
    }

    private static func anthropic(_ input: Double, _ output: Double) -> Rate {
        Rate(
            input: input, output: output, cacheRead: input * 0.1, cacheWrite5m: input * 1.25,
            cacheWrite1h: input * 2, longContext: false)
    }

    private static func openai(
        _ input: Double, _ output: Double, cacheWrite: Double = 0, longContext: Bool = false
    ) -> Rate {
        Rate(
            input: input, output: output, cacheRead: input * 0.1, cacheWrite5m: input * cacheWrite,
            cacheWrite1h: input * cacheWrite, longContext: longContext)
    }

    private static let rates: [String: Rate] = [
        "claude-fable-5": anthropic(10, 50),
        "claude-mythos-5": anthropic(10, 50),
        "claude-opus-5": anthropic(5, 25),
        "claude-opus-4-8": anthropic(5, 25),
        "claude-opus-4-7": anthropic(5, 25),
        "claude-opus-4-6": anthropic(5, 25),
        "claude-sonnet-5": anthropic(2, 10),
        "claude-sonnet-4-6": anthropic(3, 15),
        "claude-haiku-4-5": anthropic(1, 5),

        "gpt-5.6-sol": openai(5, 30, cacheWrite: 1.25, longContext: true),
        "gpt-5.6-terra": openai(2, 12, cacheWrite: 1.25, longContext: true),
        "gpt-5.6-luna": openai(0.2, 1.2, cacheWrite: 1.25, longContext: true),
        "gpt-5.5": openai(5, 30, longContext: true),
        "gpt-5.4-mini": openai(0.75, 4.5),
        "gpt-5.4": openai(2.5, 15, longContext: true),
        "gpt-5.3-codex": openai(1.75, 14),
        "gpt-5.2": openai(1.75, 14),

        "k3": openai(3, 15),
    ]

    /// Never billed: Claude Code's locally generated interrupt and notice records.
    private static let free: Set<String> = ["<synthetic>"]
    /// Known models with no published rate, kept distinct from "free".
    private static let unpriced: Set<String> = ["gpt-5.3-codex-spark"]

    public static var pricedModels: [String] { rates.keys.sorted() }

    /// Dated and tiered ids resolve to their family, with a hyphen boundary so
    /// `gpt-5.5` never swallows `gpt-5.55`, and the longest family winning.
    public static func rate(for model: String?) -> Rate? {
        guard let model else { return nil }
        if free.contains(model) { return anthropic(0, 0) }
        if unpriced.contains(model) { return nil }
        let normalized = model == "kimi-code/k3" ? "k3" : model

        let best = rates.keys
            .filter { normalized == $0 || normalized.hasPrefix($0 + "-") }
            .max { $0.count < $1.count }
        return best.flatMap { rates[$0] }
    }

    /// Cost at list price, or nil when the model has no rate — a silent zero
    /// would look exactly like a real one.
    public static func price(model: String?, usage: TokenUsage, allowLongContext: Bool = true) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let promptTokens =
            usage.inputTokens + usage.cacheReadTokens + usage.cacheWrite5mTokens + usage.cacheWrite1hTokens
        let long = allowLongContext && rate.longContext && promptTokens > 272_000
        let inputMultiplier = long ? 2.0 : 1.0
        let outputMultiplier = long ? 1.5 : 1.0

        let micro =
            Double(usage.inputTokens) * rate.input * inputMultiplier
            + Double(usage.outputTokens) * rate.output * outputMultiplier
            + Double(usage.cacheReadTokens) * rate.cacheRead * inputMultiplier
            + Double(usage.cacheWrite5mTokens) * rate.cacheWrite5m * inputMultiplier
            + Double(usage.cacheWrite1hTokens) * rate.cacheWrite1h * inputMultiplier
        return micro / 1_000_000
    }
}
