import AppKit
import SwiftUI

/// `VibecomBar --snapshot <accounts|add|settings> <out.png> [--dark]` renders a
/// page the way the menu bar window sizes it, then exits. Used to check layout
/// without opening the menu by hand.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 2 else { return }

        _ = NSApplication.shared
        let model = AppModel()
        switch arguments[index + 1] {
        case "add": model.page = .addAccount
        case "settings": model.page = .settings
        default: model.page = .accounts
        }

        let host = NSHostingView(rootView: RootView(model: model))
        host.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 10), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host

        // Let measured heights settle, resizing to fit as a menu bar window does.
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: arguments[index + 2]))
        print("snapshot \(arguments[index + 1]): \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
        exit(0)
    }
}
