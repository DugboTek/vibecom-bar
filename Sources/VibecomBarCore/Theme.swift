import Foundation

/// A colour in oklch, the space vibecom's tokens are authored in.
public struct OKLCH: Equatable, Sendable {
    public let lightness: Double
    public let chroma: Double
    public let hue: Double
    public let alpha: Double

    public init(lightness: Double, chroma: Double, hue: Double, alpha: Double = 1) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
        self.alpha = alpha
    }

    public func opacity(_ alpha: Double) -> OKLCH {
        OKLCH(lightness: lightness, chroma: chroma, hue: hue, alpha: alpha)
    }

    /// oklch → oklab → linear sRGB → sRGB, per the CSS Color 4 definition.
    public var sRGB: (red: Double, green: Double, blue: Double) {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        let linearRed = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let linearGreen = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let linearBlue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return (encode(linearRed), encode(linearGreen), encode(linearBlue))
    }

    private func encode(_ channel: Double) -> Double {
        let value =
            channel <= 0.0031308
            ? 12.92 * channel
            : 1.055 * pow(abs(channel), 1 / 2.4) * (channel < 0 ? -1 : 1) - 0.055
        return min(max(value, 0), 1)
    }
}

/// The vibecom palette, copied from the site's `--ui-*` tokens.
public struct BrandPalette: Sendable {
    public let canvas: OKLCH
    public let surface: OKLCH
    public let foreground: OKLCH
    public let muted: OKLCH
    public let line: OKLCH
    public let accent: OKLCH
    public let signal: OKLCH
    public let positive: OKLCH
    public let negative: OKLCH

    public static let dark = BrandPalette(
        canvas: OKLCH(lightness: 0.145, chroma: 0.014, hue: 252),
        surface: OKLCH(lightness: 0.19, chroma: 0.016, hue: 252),
        foreground: OKLCH(lightness: 0.95, chroma: 0.008, hue: 230),
        muted: OKLCH(lightness: 0.69, chroma: 0.018, hue: 245),
        line: OKLCH(lightness: 1, chroma: 0, hue: 0, alpha: 0.09),
        accent: OKLCH(lightness: 0.72, chroma: 0.16, hue: 236),
        signal: OKLCH(lightness: 0.88, chroma: 0.18, hue: 112),
        positive: OKLCH(lightness: 0.8, chroma: 0.17, hue: 155),
        negative: OKLCH(lightness: 0.72, chroma: 0.18, hue: 20)
    )

    public static let light = BrandPalette(
        canvas: OKLCH(lightness: 0.985, chroma: 0.007, hue: 230),
        surface: OKLCH(lightness: 0.95, chroma: 0.012, hue: 232),
        foreground: OKLCH(lightness: 0.22, chroma: 0.024, hue: 248),
        muted: OKLCH(lightness: 0.48, chroma: 0.025, hue: 245),
        line: OKLCH(lightness: 0.22, chroma: 0.024, hue: 248, alpha: 0.13),
        accent: OKLCH(lightness: 0.5, chroma: 0.18, hue: 239),
        signal: OKLCH(lightness: 0.67, chroma: 0.17, hue: 112),
        positive: OKLCH(lightness: 0.5, chroma: 0.14, hue: 155),
        negative: OKLCH(lightness: 0.52, chroma: 0.2, hue: 22)
    )

    /// Green while there is room, lime as the limit approaches, red at the edge.
    public func color(forUsage fraction: Double) -> OKLCH {
        switch fraction {
        case ..<0.8: positive
        case ..<0.95: signal
        default: negative
        }
    }
}
