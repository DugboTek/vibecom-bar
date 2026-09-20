import SwiftUI
import VibecomBarCore

/// Local token activity and the signed-in builder's Vibecom standing.
struct TokensCard: View {
    @Environment(\.brand) private var brand
    let summary: TokenSummary?
    let ticker: TokenTicker
    let isCounting: Bool
    let standing: VibecomStanding?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if let summary {
                    activity(summary)
                    Sparkline(
                        values: summary.hourly,
                        currentHour: Calendar.current.component(.hour, from: Date()),
                        height: 18)
                    activityBreakdown(summary)
                } else {
                    counting
                }
                Divider()
                vibecomSection
            }
            .padding(10)
        }
    }

    private func activity(_ summary: TokenSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ON THIS MAC · TODAY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.35)
                    .foregroundStyle(.tertiary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    TickerNumber(ticker: ticker)
                    Text("tokens")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if summary.isLive(at: Date()) {
                LiveBadge(rate: summary.tokensPerMinute)
            }
        }
    }

    private func activityBreakdown(_ summary: TokenSummary) -> some View {
        HStack(spacing: 10) {
            ForEach(CodingTool.allCases) { tool in
                let tokens = summary.byTool[tool]?.tokens ?? 0
                HStack(spacing: 4) {
                    Circle()
                        .fill(tool == .claudeCode ? Color(brand.accent) : Color(brand.signal))
                        .frame(width: 5, height: 5)
                    Text(tool == .claudeCode ? "Claude" : "Codex")
                        .foregroundStyle(.secondary)
                    Text(UsageFormatter.tokens(tokens))
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            Text(UsageFormatter.dollars(summary.today.cost))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .help("Estimated list API value; subscriptions are not billed this amount.")
        }
        .font(.system(size: 10))
    }

    @ViewBuilder
    private var vibecomSection: some View {
        if let standing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(brand.accent))
                    Text("VIBECOM")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.35)
                        .foregroundStyle(.tertiary)
                    Text("@\(standing.username)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if standing.streakDays > 0 {
                        Label("\(standing.streakDays)d", systemImage: "flame.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help("\(standing.streakDays)-day Vibecom streak")
                    }
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BUILDER RANK")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(.tertiary)
                        Text(standing.rank.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    standingMetric("7 DAYS", position: standing.weekly.position)
                    standingMetric("ALL TIME", position: standing.allTime.position)
                }

                if let nextName = standing.rank.nextName, standing.rank.tokensToNext > 0 {
                    HStack(spacing: 7) {
                        UsageBar(fraction: standing.rank.progress)
                        Text("\(UsageFormatter.tokens(standing.rank.tokensToNext)) to \(nextName)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vibecom rank")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Run `vibecom login` to show weekly and all-time standing.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func standingMetric(_ label: String, position: Int?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(.tertiary)
            Text(position.map { "#\($0)" } ?? "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(minWidth: 46, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.lowercased()) rank \(position.map(String.init) ?? "not ranked")")
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
                    .font(.system(size: 11, weight: .medium))
                Text("Read locally from Claude Code and Codex.")
                    .font(.system(size: 9))
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
                .font(.system(size: 21, weight: .semibold, design: .rounded))
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
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Tokens per minute over the last five minutes")
    }
}
