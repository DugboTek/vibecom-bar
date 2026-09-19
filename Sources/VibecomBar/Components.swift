import SwiftUI
import VibecomBarCore

extension Color {
    init(_ token: OKLCH) {
        let rgb = token.sRGB
        self = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: token.alpha)
    }
}

/// The site's tokens, picked to match the system appearance.
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = BrandPalette.dark
}

extension EnvironmentValues {
    var brand: BrandPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

struct Wordmark: View {
    @Environment(\.brand) private var brand

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(brand.accent))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color(brand.signal))
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: 1)
                }
            Text("vibecom bar")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(brand.foreground))
        }
    }
}

struct UsageBar: View {
    @Environment(\.brand) private var brand

    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(brand.foreground).opacity(0.1))
                Capsule()
                    .fill(Color(brand.color(forUsage: fraction)))
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

struct Chip: View {
    @Environment(\.brand) private var brand

    let text: String
    var tint: OKLCH?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(tint ?? brand.muted).opacity(0.15))
            )
            .foregroundStyle(Color(tint ?? brand.muted))
    }
}

/// A flat, quiet button that still reads as tappable in a menu bar window.
struct BarButton: View {
    @Environment(\.brand) private var brand
    @State private var isHovering = false

    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        prominent
                            ? Color(brand.accent).opacity(isHovering ? 0.28 : 0.18)
                            : Color(brand.foreground).opacity(isHovering ? 0.12 : 0.06))
            )
            .foregroundStyle(Color(prominent ? brand.accent : brand.foreground))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
