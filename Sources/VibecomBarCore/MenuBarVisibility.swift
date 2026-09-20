import Foundation

/// macOS remembers when a menu bar item was removed, and SwiftUI quits an app
/// whose item is hidden. Left alone, that makes the app impossible to open: it
/// quits within a second of every launch. Opening the app is a clear request to
/// see its icon, so the flag is cleared on the way up.
public enum MenuBarVisibility {
    static let keys = [
        "NSStatusItem VisibleCC Item-0", "NSStatusItem Visible Item-0",
        "NSStatusItem Visible vibecom",
    ]

    public static func restore(in defaults: UserDefaults = .standard) {
        for key in keys where !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
        }
    }
}
