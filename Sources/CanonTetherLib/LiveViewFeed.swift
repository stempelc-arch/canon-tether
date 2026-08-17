import AppKit
import Combine

/// Holds nothing but the current live-view frame.
///
/// Separate from `CameraViewModel` on purpose. Frames arrive several times a second, and every
/// `@Published` change invalidates *all* views observing that object — with the frame on the view
/// model, each one re-evaluated the toolbar, the inspector, the filmstrip (re-running its
/// "good shots only" filter across the entire session) and the client review window, none of
/// which had changed. Scoping the frame to its own object means only the preview canvas, which
/// genuinely needs the new pixels, redraws.
@MainActor
final class LiveViewFeed: ObservableObject {
    @Published private(set) var image: NSImage?

    func update(_ image: NSImage?) {
        self.image = image
    }

    func clear() {
        image = nil
    }
}
