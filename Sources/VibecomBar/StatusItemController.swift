import AppKit
import SwiftUI
import VibecomBarCore

/// Owns the menu bar item directly, through AppKit.
///
/// SwiftUI's `MenuBarExtra` is a scene, and macOS ends that scene — quitting
/// the app — whenever it decides the item should not be shown. Once that state
/// stuck for this bundle id, every launch died about a second in, which looked
/// like the app crashing and left its sign-in prompts half-finished. An
/// `NSStatusItem` has no such lifecycle: if the item is hidden the app keeps
/// running, and it can put the item back.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Snapshot.isRequested else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "vibecom"
        item.isVisible = true
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("vibecom bar")
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: RootView(model: model))

        model.start()
        trackTitle()
    }

    /// Redraws the menu bar label whenever what it shows changes.
    private func trackTitle() {
        withObservationTracking {
            updateButton()
        } onChange: {
            Task { @MainActor [weak self] in self?.trackTitle() }
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let symbol = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "vibecom bar")
        symbol?.isTemplate = true
        button.image = symbol

        let text = model.menuBarText
        button.attributedTitle = NSAttributedString(
            string: text.isEmpty ? "" : " \(text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            ])
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
