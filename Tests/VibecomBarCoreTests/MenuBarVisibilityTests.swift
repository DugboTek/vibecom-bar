import Foundation
import Testing

@testable import VibecomBarCore

/// macOS remembers a hidden menu bar item and quits the app on every launch
/// that follows, which makes the app impossible to open again.
@Suite("Menu bar visibility")
struct MenuBarVisibilityTests {
    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "vibecom-bar-tests-\(UUID().uuidString)")!
        return suite
    }

    @Test("puts the icon back when macOS has it marked hidden")
    func restoresHiddenItem() {
        let store = defaults()
        store.set(false, forKey: "NSStatusItem VisibleCC Item-0")

        MenuBarVisibility.restore(in: store)

        #expect(store.bool(forKey: "NSStatusItem VisibleCC Item-0"))
        #expect(store.bool(forKey: "NSStatusItem Visible Item-0"))
    }

    @Test("leaves an already visible item alone")
    func keepsVisibleItem() {
        let store = defaults()
        store.set(true, forKey: "NSStatusItem VisibleCC Item-0")

        MenuBarVisibility.restore(in: store)

        #expect(store.bool(forKey: "NSStatusItem VisibleCC Item-0"))
    }
}
