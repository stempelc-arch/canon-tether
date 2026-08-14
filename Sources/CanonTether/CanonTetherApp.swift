import SwiftUI
import CanonTetherLib

@main
struct CanonTetherApp: App {
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
