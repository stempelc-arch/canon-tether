import Foundation

/// Keeps the Mac awake while enabled, using the standard `ProcessInfo` activity API
/// (the same mechanism behind `caffeinate`) rather than raw IOKit assertions.
final class SleepPreventer: ObservableObject {
    @Published private(set) var isPreventingSleep = false

    private var activityToken: NSObjectProtocol?

    func toggle() {
        isPreventingSleep ? disable() : enable()
    }

    private func enable() {
        guard activityToken == nil else { return }
        // .background keeps the assertion honored under App Nap once the app
        // isn't frontmost (e.g. user tabs away mid-shoot) — without it macOS can
        // throttle the process and silently drop the sleep assertion.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated, .background],
            reason: "Tethered shooting session"
        )
        isPreventingSleep = true
    }

    private func disable() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        isPreventingSleep = false
    }
}
