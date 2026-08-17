import SwiftUI
import CanonTetherLib

/// Kills the gphoto2 shell on quit. Without this the child is reparented to launchd with its
/// PTP/IP session still open — the camera stays claimed by a ghost process, and neither a
/// relaunch of this app nor any other software can connect until it's manually killed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ChildProcessRegistry.shared.terminateAll()
    }
}

@main
struct CanonTetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // We talk to `gphoto2 --shell` over a pipe. When the camera drops the PTP/IP link the
        // shell process exits, and any write to that now-readerless pipe raises SIGPIPE — whose
        // default action silently kills our app (a signal, so `try?` can't catch it). Ignore it
        // process-wide so those writes fail as ordinary EPIPE errors we can recover from instead.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
