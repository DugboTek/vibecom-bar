import Foundation
import Testing

@testable import VibecomBarCore

/// vibecom's design tokens are authored in oklch, so the app converts them
/// rather than keeping a second, drifting set of hex values.
@Suite("Brand colour conversion")
struct OKLCHTests {
    private func expect(
        _ color: OKLCH, isCloseTo expected: (Double, Double, Double),
        tolerance: Double = 0.01, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rgb = color.sRGB
        #expect(abs(rgb.red - expected.0) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(rgb.green - expected.1) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(rgb.blue - expected.2) < tolerance, sourceLocation: sourceLocation)
    }

    @Test("converts the reference value for white")
    func white() {
        expect(OKLCH(lightness: 1, chroma: 0, hue: 0), isCloseTo: (1, 1, 1))
    }

    @Test("converts the reference value for black")
    func black() {
        expect(OKLCH(lightness: 0, chroma: 0, hue: 0), isCloseTo: (0, 0, 0))
    }

    @Test("converts the reference value for sRGB red")
    func red() {
        expect(OKLCH(lightness: 0.6280, chroma: 0.2577, hue: 29.23), isCloseTo: (1, 0, 0))
    }

    @Test("converts the reference value for sRGB green")
    func green() {
        expect(OKLCH(lightness: 0.8664, chroma: 0.2948, hue: 142.5), isCloseTo: (0, 1, 0))
    }

    @Test("converts the reference value for sRGB blue")
    func blue() {
        expect(OKLCH(lightness: 0.4520, chroma: 0.3132, hue: 264.05), isCloseTo: (0, 0, 1))
    }

    @Test("keeps a colour outside the sRGB gamut inside the displayable range")
    func clampsOutOfGamut() {
        let rgb = OKLCH(lightness: 0.9, chroma: 0.4, hue: 140).sRGB

        #expect(rgb.red >= 0 && rgb.red <= 1)
        #expect(rgb.green >= 0 && rgb.green <= 1)
        #expect(rgb.blue >= 0 && rgb.blue <= 1)
    }

    @Test("carries vibecom's accent and signal tokens verbatim")
    func brandTokens() {
        #expect(BrandPalette.dark.accent == OKLCH(lightness: 0.72, chroma: 0.16, hue: 236))
        #expect(BrandPalette.dark.signal == OKLCH(lightness: 0.88, chroma: 0.18, hue: 112))
        #expect(BrandPalette.light.accent == OKLCH(lightness: 0.5, chroma: 0.18, hue: 239))
    }

    @Test("colours a usage bar by how close the window is to its limit")
    func usageColour() {
        #expect(BrandPalette.dark.color(forUsage: 0.2) == BrandPalette.dark.positive)
        #expect(BrandPalette.dark.color(forUsage: 0.85) == BrandPalette.dark.signal)
        #expect(BrandPalette.dark.color(forUsage: 0.97) == BrandPalette.dark.negative)
    }
}
