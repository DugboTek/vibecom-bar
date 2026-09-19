import AppKit
import SwiftUI
import VibecomBarCore

extension Color {
    init(_ token: OKLCH) {
        let rgb = token.sRGB
        self = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: token.alpha)
    }
}

/// vibecom's tokens, picked to match the system appearance. The interface is
/// otherwise built from system colours so it reads as part of macOS.
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = BrandPalette.dark
}

extension EnvironmentValues {
    var brand: BrandPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

enum Style {
    /// System colours for how close a window is to its limit, as Apple's own
    /// meters use them: tint while comfortable, orange when close, red at the edge.
    static func usageColor(_ fraction: Double, accent: Color) -> Color {
        switch fraction {
        case ..<0.8: accent
        case ..<0.95: .orange
        default: .red
        }
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.7)
    static let hairline = Color(nsColor: .separatorColor)
}

struct Wordmark: View {
    @Environment(\.brand) private var brand

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(brand.accent))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color(brand.signal))
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: 1)
                }
            Text("vibecom")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("vibecom bar")
    }
}

/// A grouped container, like the sections in System Settings.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Style.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Style.hairline.opacity(0.6), lineWidth: 0.5)
            )
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct UsageBar: View {
    @Environment(\.brand) private var brand
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Style.usageColor(fraction, accent: Color(brand.accent)))
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A capacity ring, in the manner of the Battery widget.
struct UsageRing: View {
    @Environment(\.brand) private var brand
    let fraction: Double?
    var isActive = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(min(fraction, 1), 0.001))
                    .stroke(
                        Style.usageColor(fraction, accent: Color(brand.accent)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if isActive {
                Circle()
                    .fill(Color(brand.signal))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// Today's tokens by hour, with the current hour picked out.
struct Sparkline: View {
    @Environment(\.brand) private var brand
    let values: [Int]
    let currentHour: Int

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { hour, value in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(
                        hour == currentHour
                            ? Color(brand.accent)
                            : Color(brand.accent).opacity(hour > currentHour ? 0.12 : 0.45)
                    )
                    .frame(height: max(2, 30 * CGFloat(value) / CGFloat(peak)))
                    .help("\(hour):00 — \(UsageFormatter.tokens(value)) tokens")
            }
        }
        .frame(height: 30, alignment: .bottom)
        .accessibilityLabel("Tokens by hour today")
    }
}

/// A pill that shows a small fact without competing with the numbers.
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .foregroundStyle(tint)
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
