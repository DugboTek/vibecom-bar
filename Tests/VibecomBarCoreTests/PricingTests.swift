import Foundation
import Testing

@testable import VibecomBarCore

/// Mirrors vibecom's `cli/src/pricing.test.ts`, so the menu bar and the site
/// derive the same dollars from the same tokens.
@Suite("Pricing")
struct PricingTests {
    private func usage(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0
    ) -> TokenUsage {
        TokenUsage(
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
            cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h)
    }

    private func close(_ value: Double?, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let value else {
            Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(value - expected) < 1e-9, "got \(value)", sourceLocation: sourceLocation)
    }

    @Test("input and output bill at the model's list rate")
    func listRate() {
        close(Pricing.price(model: "claude-opus-5", usage: usage(input: 1_000_000, output: 1_000_000)), 30)
    }

    @Test("cache reads bill at a tenth of input, writes at a premium")
    func cacheRates() {
        close(Pricing.price(model: "claude-opus-5", usage: usage(cacheRead: 1_000_000)), 0.5)
        close(Pricing.price(model: "claude-opus-5", usage: usage(write5m: 1_000_000)), 6.25)
        close(Pricing.price(model: "claude-opus-5", usage: usage(write1h: 1_000_000)), 10)
    }

    @Test("GPT-5.6 bills cache writes and discounts cache reads")
    func gpt56Cache() {
        close(Pricing.price(model: "gpt-5.6-sol", usage: usage(write5m: 100_000)), 0.625)
        close(Pricing.price(model: "gpt-5.6-sol", usage: usage(cacheRead: 100_000)), 0.05)
        close(Pricing.price(model: "gpt-5.5", usage: usage(write5m: 100_000)), 0)
    }

    @Test("every GPT-5.6 tier uses its published list rate")
    func gpt56Tiers() {
        close(Pricing.price(model: "gpt-5.6-terra", usage: usage(input: 100_000)), 0.2)
        close(Pricing.price(model: "gpt-5.6-terra", usage: usage(output: 100_000)), 1.2)
        close(Pricing.price(model: "gpt-5.6-luna", usage: usage(input: 100_000)), 0.02)
        close(Pricing.price(model: "gpt-5.6-luna", usage: usage(output: 100_000)), 0.12)
    }

    @Test("published rates cover the Codex models present in historical scans")
    func historicalCodex() {
        close(Pricing.price(model: "gpt-5.2-codex", usage: usage(output: 100_000)), 1.4)
        close(Pricing.price(model: "gpt-5.3-codex", usage: usage(input: 100_000)), 0.175)
        close(Pricing.price(model: "gpt-5.4", usage: usage(output: 100_000)), 1.5)
        close(Pricing.price(model: "gpt-5.4-mini", usage: usage(input: 100_000)), 0.075)
    }

    @Test("OpenAI long-context pricing is applied per request")
    func longContext() {
        close(
            Pricing.price(model: "gpt-5.6-sol", usage: usage(input: 2_000, output: 10_000, cacheRead: 270_000)),
            0.445)
        close(
            Pricing.price(model: "gpt-5.6-sol", usage: usage(input: 2_001, output: 10_000, cacheRead: 270_000)),
            0.74001)
    }

    @Test("GPT-5.4 mini does not receive the long-context uplift")
    func miniNoUplift() {
        close(Pricing.price(model: "gpt-5.4-mini", usage: usage(input: 1_000_000)), 0.75)
    }

    @Test("Sonnet 5 uses its current introductory rate")
    func sonnet5() {
        close(Pricing.price(model: "claude-sonnet-5", usage: usage(input: 1_000_000, output: 1_000_000)), 12)
    }

    @Test("Kimi K3 and its wire model id use the published API rate")
    func kimi() {
        for model in ["k3", "kimi-code/k3"] {
            close(Pricing.price(model: model, usage: usage(input: 100_000)), 0.3)
            close(Pricing.price(model: model, usage: usage(cacheRead: 100_000)), 0.03)
            close(Pricing.price(model: model, usage: usage(output: 100_000)), 1.5)
        }
    }

    @Test("a dated snapshot resolves to its model family")
    func datedSnapshot() {
        close(Pricing.price(model: "claude-haiku-4-5-20251001", usage: usage(output: 1_000_000)), 5)
    }

    @Test("the longest matching family wins")
    func longestFamily() {
        close(Pricing.price(model: "gpt-5.6-terra", usage: usage(input: 100_000)), 0.2)
        close(Pricing.price(model: "gpt-5.6-sol", usage: usage(input: 100_000)), 0.5)
    }

    @Test("a family key does not match a longer sibling number")
    func siblingBoundary() {
        #expect(Pricing.rate(for: "gpt-5.55") == nil)
        #expect(Pricing.rate(for: "gpt-5.5") != nil)
    }

    @Test("an unrated model returns nil rather than zero")
    func unrated() {
        #expect(Pricing.price(model: "gpt-5.3-codex-spark", usage: usage(output: 5_000_000)) == nil)
        #expect(Pricing.price(model: nil, usage: usage(output: 5_000_000)) == nil)
    }

    @Test("locally generated messages are free, not unrated")
    func synthetic() {
        close(Pricing.price(model: "<synthetic>", usage: usage(output: 1_000)), 0)
    }

    @Test("every priced model charges more for output than input")
    func outputCostsMore() {
        for model in Pricing.pricedModels {
            let input = Pricing.price(model: model, usage: usage(input: 1_000_000)) ?? 0
            let output = Pricing.price(model: model, usage: usage(output: 1_000_000)) ?? 0
            #expect(output > input, "\(model)")
        }
    }

    @Test("total counts every class exactly once")
    func totalTokens() {
        #expect(usage(input: 1, output: 2, cacheRead: 3, write5m: 4, write1h: 5).total == 15)
    }
}
