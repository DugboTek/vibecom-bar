import AppKit
import SwiftUI

/// `VibecomBar --snapshot <accounts|add|settings> <out.png> [--dark] [--tokens]`
/// renders a page the way the menu bar window sizes it, then exits. It uses
/// sample accounts, so it never reads the keychain or prompts for a password;
/// `--tokens` also counts this Mac's real transcripts, which are plain files.
@MainActor
enum Snapshot {
    static let isRequested = CommandLine.arguments.contains("--snapshot")

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 2 else { return }
        let page = arguments[index + 1]
        let output = URL(fileURLWithPath: arguments[index + 2])
        let dark = arguments.contains("--dark")
        let countTokens = arguments.contains("--tokens")
        let wait = Double(ProcessInfo.processInfo.environment["VIBECOM_SNAPSHOT_WAIT"] ?? "0.5") ?? 0.5

        // Runs once the app is up, so async work (the token count) proceeds on
        // the main actor exactly as it does in the real menu.
        Task { @MainActor in
            let model = AppModel()
            model.page = page == "add" ? .addAccount : page == "settings" ? .settings : .accounts
            model.loadPreviewAccounts()
            if countTokens { model.startTokenFeed() }

            let host = NSHostingView(
                rootView: RootView(model: model).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 372, height: 10), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.contentView = host

            let deadline = Date().addingTimeInterval(wait)
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
                if countTokens, model.tokens != nil, Date() > deadline.addingTimeInterval(-wait + 0.5) { break }
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
            } while Date() < deadline
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(50))
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
            }

            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output)
            print("snapshot \(page): \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
            exit(0)
        }
    }
}
