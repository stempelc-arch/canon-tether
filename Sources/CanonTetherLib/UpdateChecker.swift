import Foundation
import CanonTetherCore

/// Checks whether a newer release has been published, and if so offers a link to it.
///
/// Deliberately *not* a self-updating framework (Sparkle and friends): this app is distributed
/// unsigned through GitHub releases, where a silent auto-installer would be both harder to trust
/// and harder to build — it needs a signing identity to verify what it downloads. A check that
/// tells the photographer a new version exists and opens the release page keeps the same practical
/// benefit with no new dependency and nothing writing to /Applications behind their back.
@MainActor
final class UpdateChecker: ObservableObject {
    static let enabledKey = "checkForUpdates"

    /// The newer version's tag, once one is found. Nil means up to date or not yet checked.
    @Published private(set) var availableVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var isChecking = false
    /// Set when an explicit, user-initiated check fails, so the Preferences button can say so
    /// rather than looking like it did nothing. Launch checks stay silent.
    @Published private(set) var lastCheckFailed = false

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/stempelc-arch/canon-tether/releases/latest")!

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The running build's version, from the bundle. Falls back to a dev sentinel that can never
    /// look outdated, so `swift run` builds don't nag.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "999.0"
    }

    /// Called on launch. Silent about failures — an offline shoot shouldn't produce an error.
    func checkInBackground() async {
        guard Self.isEnabled else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        isChecking = true
        lastCheckFailed = false
        defer { isChecking = false }

        var request = URLRequest(url: Self.latestReleaseAPI)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                if userInitiated { lastCheckFailed = true }
                return
            }
            if SemanticVersion.isNewer(tag, than: Self.currentVersion) {
                availableVersion = tag
                releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            } else {
                availableVersion = nil
                releaseURL = nil
            }
        } catch {
            if userInitiated { lastCheckFailed = true }
        }
    }
}
