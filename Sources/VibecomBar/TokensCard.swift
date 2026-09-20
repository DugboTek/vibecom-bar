import SwiftUI
import VibecomBarCore

/// What this Mac has spent today, counted from the CLIs' own transcripts and
/// priced the same way vibecom.build prices it.
struct TokensCard: View {
    @Environment(\.brand) private var brand
    let summary: TokenSummary?
    let ticker: TokenTicker
    let isCounting: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if let summary {
                    header(summary)
                    Sparkline(
                        values: summary.hourly,
                        currentHour: Calendar.current.component(.hour, from: Date()))
                    split(summary)
                } else {
                    counting
                }
            }
            .padding(10)
        }
    }

    private func header(_ summary: TokenSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if summary.isLive(at: Date()) {
                    LiveBadge(rate: summary.tokensPerMinute)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                TickerNumber(ticker: ticker)
                Text("tokens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("\(UsageFormatter.dollars(summary.today.cost)) at API prices")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(
                    "What these tokens would cost at list API prices. Subscriptions are not billed this — it is the same figure vibecom.build shows."
                )
        }
    }

    private func split(_ summary: TokenSummary) -> some View {
        let total = max(summary.today.tokens, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ForEach(CodingTool.allCases) { tool in
                    let tokens = summary.byTool[tool]?.tokens ?? 0
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tool == .claudeCode ? Color(brand.accent) : Color(brand.signal))
                            .frame(width: 6, height: 6)
                        Text(tool == .claudeCode ? "Claude" : "Codex")
                            .foregroundStyle(.secondary)
                        Text(UsageFormatter.tokens(tokens))
                            .monospacedDigit()
                        Text("\(Int((Double(tokens) / Double(total) * 100).rounded()))%")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.system(size: 11))

            Divider()

            HStack {
                Text("Last 7 days")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(UsageFormatter.tokens(summary.week.tokens)) · \(UsageFormatter.dollars(summary.week.cost))")
                    .monospacedDigit()
            }
            .font(.system(size: 11))

            if let top = summary.topModels.first {
                HStack {
                    Text("Top model")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(top.model) · \(UsageFormatter.tokens(top.totals.tokens))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
            }
        }
    }

    private var counting: some View {
        HStack(spacing: 8) {
            if isCounting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "text.page.slash").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(isCounting ? "Counting this week's tokens…" : "No transcripts found yet")
                    .font(.system(size: 12, weight: .medium))
                Text("Read from Claude Code and Codex on this Mac. Nothing is uploaded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Today's count to the last digit, climbing between readings like a ticker.
private struct TickerNumber: View {
    let ticker: TokenTicker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
            let value = ticker.value(at: context.date)
            Text(UsageFormatter.fullTokens(value))
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy(duration: 0.18), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel("\(UsageFormatter.fullTokens(value)) tokens today")
        }
    }
}

private struct LiveBadge: View {
    @Environment(\.brand) private var brand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rate: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(brand.signal))
                .frame(width: 6, height: 6)
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1 : 0.6))
                .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.5))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse)
                .onAppear { if !reduceMotion { pulse = true } }
            Text("\(UsageFormatter.tokens(rate))/min")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Tokens per minute over the last five minutes")
    }
}
