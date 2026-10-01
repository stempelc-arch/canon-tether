import SwiftUI
import AppKit

/// Owns the focus-stacking window.
///
/// This was a `.sheet` first, and that was wrong: a sheet cannot be resized and is sized by its
/// content, so it sat as a small panel in front of a large main window — no use at all for the one
/// thing it exists for, which is *looking closely at focus*. A real window can be resized, zoomed,
/// moved to a second display and taken full-screen. Same reasoning as `ReviewWindowController`,
/// which is why it follows the same shape (a plain AppKit controller rather than a SwiftUI scene,
/// so it works on the macOS 12 deployment target and can be driven from a toolbar button).
@MainActor
final class FocusStackWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresented = false
    private var window: NSWindow?
    /// Held so closing can restore live view even when SwiftUI's `onDisappear` doesn't fire — the
    /// window is reused (`isReleasedWhenClosed = false`), so its hosted view isn't reliably torn
    /// down on close. `windowWillClose` always fires.
    private weak var viewModel: CameraViewModel?

    private static let identifier = NSUserInterfaceItemIdentifier("focusStack")

    func toggle(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        if let window, window.isVisible {
            window.close()
            return
        }
        let win: NSWindow
        if let window {
            win = window
        } else {
            let root = FocusStackPanel(
                model: viewModel.focusStack,
                viewModel: viewModel,
                onClose: { [weak self] in self?.window?.close() }
            )
            win = NSWindow(contentViewController: NSHostingController(rootView: root))
            win.title = "Focus Stacking"
            win.identifier = Self.identifier
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false   // reused across open/close
            win.delegate = self
            // Opens large. The live view is the point of this window, and a default that needs
            // resizing before it's usable is a default that's wrong.
            win.setContentSize(NSSize(width: 1180, height: 820))
            win.center()
            window = win
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Live view starts with the window, not with the first rack: every control in the panel
        // drives focus, and focus drive only works while live view is running.
        viewModel.focusStack.enterBracketingMode(liveViewIsOn: viewModel.isLiveViewOn)
        isPresented = true
    }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
        // Idempotent: also called from the panel's `onDisappear` where that fires.
        viewModel?.focusStack.exitBracketingMode()
    }
}
