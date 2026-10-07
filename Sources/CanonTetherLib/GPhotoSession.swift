import Foundation
import Darwin
import ImageIO
import CoreGraphics
import CanonTetherCore

/// The single on-disk location captures are downloaded to, shared by the session (which writes
/// them) and the view model (which lists them for the review window).
enum CaptureLocation {
    static let userDefaultsKey = "captureDirectoryPath"

    static let defaultDirectory = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CanonTether")

    /// The folder captures download to. Honors a user-chosen path from Preferences, falling back to
    /// ~/Pictures/CanonTether. Read once per session (at `GPhotoSession` init), so changing it in
    /// Preferences applies to the next launch.
    static var directory: URL {
        // Symlinks resolved so URL identity is stable: a chosen folder whose path traverses a
        // symlink (/var vs /private/var — the classic) would otherwise give seeded-gallery URLs
        // and live-capture URLs different string identities, silently breaking every == and Set
        // comparison (flags, selection, trash, analysis lookups).
        if let path = UserDefaults.standard.string(forKey: userDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return defaultDirectory.resolvingSymlinksInPath()
    }

    /// File extensions the app treats as reviewable captures.
    static let imageExtensions: Set<String> = ["cr2", "cr3", "jpg", "jpeg", "png", "heic", "tiff", "tif"]

    /// Suffix marking a focus-stack subfolder. A bracket's source frames are *not* individual
    /// photographs — nobody wants twelve near-identical rack-focus frames filling the filmstrip —
    /// so they live in their own folder per capture and only the merged result is shown.
    static let stackFolderSuffix = " Focus Stack"
    /// An HDR bracket's frames are grouped exactly like a focus stack's, and for the same reason:
    /// three exposures of one subject are one photograph, not three, and listing them buries the
    /// real shots. Only the suffix and the merged file's name differ.
    static let hdrFolderSuffix = " HDR"

    static let groupFolderSuffixes = [stackFolderSuffix, hdrFolderSuffix, timelapseFolderSuffix]

    static let timelapseFolderSuffix = " Timelapse"

    static func timelapseFolderName(for date: Date) -> String {
        DateFormatter.captureFilenameFormatter.string(from: date) + timelapseFolderSuffix
    }

    static func hdrFolderName(for date: Date) -> String {
        DateFormatter.captureFilenameFormatter.string(from: date) + hdrFolderSuffix
    }

    /// Name of the subfolder for a bracket shot at `date`, e.g. "20260911-143302 Focus Stack".
    /// Shares the capture filename stamp so a stack sorts next to the frames around it.
    static func stackFolderName(for date: Date) -> String {
        DateFormatter.captureFilenameFormatter.string(from: date) + stackFolderSuffix
    }

    static func isStackFolder(_ url: URL) -> Bool {
        groupFolderSuffixes.contains { url.lastPathComponent.hasSuffix($0) }
    }

    /// Filename of the merged image inside a stack folder, derived from the folder's own stamp.
    static func mergedFileName(inStackFolder folder: URL) -> String {
        let name = folder.lastPathComponent
        if name.hasSuffix(hdrFolderSuffix) {
            return name.replacingOccurrences(of: hdrFolderSuffix, with: "") + "-hdr.tif"
        }
        return name.replacingOccurrences(of: stackFolderSuffix, with: "") + "-stack.tif"
    }

    /// The merged TIFF inside a stack folder, if it has been rendered yet. This is the one file
    /// from a bracket that belongs in the gallery.
    static func mergedImage(inStackFolder folder: URL) -> URL? {
        let url = folder.appendingPathComponent(mergedFileName(inStackFolder: folder))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// A focus rack that stopped partway, carrying how many nudges did land. See `nudgeFocus`.
struct FocusDriveInterrupted: LocalizedError {
    let completed: Int
    let underlying: Error

    var isCancellation: Bool { underlying is CancellationError }

    var errorDescription: String? {
        isCancellation ? nil : underlying.localizedDescription
    }
}

enum GPhotoError: LocalizedError {
    case binaryNotFound
    case noCameraDetected
    case commandFailed(String)
    /// The camera needs changing before this can work. Carries the whole message, because unlike a
    /// gphoto2 failure there is nothing technical worth showing the photographer — only what to do.
    case needsCameraChange(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "gphoto2 not found. Install it with: brew install libgphoto2 gphoto2"
        case .noCameraDetected:
            return "No camera detected. Check the USB/network connection."
        case .needsCameraChange(let message):
            return message
        case .commandFailed(let output):
            return "gphoto2 command failed:\n\(output)"
        }
    }
}

/// Owns a single persistent `gphoto2 --shell` process, so the camera's wired-LAN pairing dance
/// (menu navigation + on-camera confirmation) only has to happen once per session instead of once
/// per photo. A one-shot `Process` per command looks like a brand new client to the camera every
/// time, which is what was forcing a full re-pair before every shot.
///
/// As an `actor`, all camera I/O is naturally serialized — no manual locking beyond the output
/// buffer, which is still touched from the pipe's background read callback.
actor GPhotoSession {
    /// gphoto2 embedded in the app bundle by scripts/bundle-gphoto2.sh — the shipped configuration,
    /// so installs need no Homebrew. Nil in development builds (`swift run`), which fall back to
    /// the Homebrew paths below.
    nonisolated private static let bundledRoot: URL? = {
        let root = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/gphoto2")
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/gphoto2").path) else {
            return nil
        }
        // The plugin directories must be present too, not just the binary. `environment(forBinary:)`
        // sets CAMLIBS/IOLIBS, which *override* libgphoto2's compiled-in defaults — so a bundle
        // missing its drivers would use the bundled binary, find no camera drivers, and never fall
        // back to a working Homebrew install, leaving the app stuck on "Waiting for camera…".
        for directory in ["camlibs", "iolibs"] {
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(directory).path)
            guard contents?.contains(where: { $0.hasSuffix(".so") }) == true else { return nil }
        }
        return root
    }()

    private static let candidatePaths = [
        bundledRoot?.appendingPathComponent("bin/gphoto2").path,
        "/usr/local/bin/gphoto2",   // Homebrew on Intel
        "/opt/homebrew/bin/gphoto2" // Homebrew on Apple Silicon
    ].compactMap { $0 }

    /// Whether a usable gphoto2 exists (bundled or Homebrew) — gates the first-run setup prompt.
    nonisolated static var isInstalled: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The bundled gphoto2 finds its dlopen()ed camera/IO driver plugins via these env vars; a
    /// Homebrew gphoto2 needs nothing (its plugin paths are compiled in).
    private static func environment(forBinary binary: String) -> [String: String]? {
        guard let bundledRoot, binary.hasPrefix(bundledRoot.path) else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["CAMLIBS"] = bundledRoot.appendingPathComponent("camlibs").path
        env["IOLIBS"] = bundledRoot.appendingPathComponent("iolibs").path
        return env
    }
    private static let cameraWaitInterval: UInt64 = 1_000_000_000
    private static let connectRetryAttempts = 60
    /// Consecutive reachability-probe refusals before assuming the camera is re-pairing and
    /// dropping back to fresh-pairing (probe-free) connect behavior.
    private static let probeFailureLimit = 5
    /// Seconds of no camera on the link before the status line stops saying "waiting" and starts
    /// suggesting what to check.
    private static let waitingHintDelay = 30
    private static let connectRetryDelay: UInt64 = 1_000_000_000
    /// Ceiling for the refusal back-off.
    ///
    /// Kept short on purpose. A *refused* connection is harmless — the camera's TCP stack answers
    /// with a reset and no session is ever established — so it is not the accept-then-abandon
    /// pattern that aborts pairing, and there is nothing to be gentle about. What backing off far
    /// does cost is the pairing window: the camera only completes the handshake while an attempt
    /// is actually in flight, so retrying every eight seconds meant mostly *not* knocking during
    /// the moment it became ready, which read as the app hanging while the camera waited.
    private static let maxConnectRetryDelay: UInt64 = 2_000_000_000
    /// Refusals before telling the photographer what (if anything) they need to do.
    private static let refusalsBeforeGuidance = 5
    // Kept tight: this is the granularity at which every shell command's completion is noticed,
    // including capture and download, so it's pure added latency on top of the camera's own work.
    private static let pollInterval: UInt64 = 20_000_000
    private static let readyTimeout: TimeInterval = 100 // covers the ~90s on-camera confirmation window

    // Distinct from SleepPreventer's user-facing toggle (which keeps the whole Mac awake): this
    // exempts just this process's own timers from App Nap for the app's lifetime, regardless of
    // whether the user wants their Mac to sleep. Without it, live testing showed the reconnect
    // loop's ~1s `Task.sleep` polling occasionally stretching to 10s+ once the app lost focus —
    // invisible to CPU profiling (a throttled sleep still looks like correctly-idle, just delayed),
    // and exactly the case a tethered camera app can't afford: reconnecting while unfocused.
    private let appNapAssertion: NSObjectProtocol = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Maintaining tethered camera connection"
    )

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private let buffer = OutputBuffer()
    private var isConnected = false
    private var progressContinuation: AsyncStream<String>.Continuation?
    private var captureDirectory = CaptureLocation.directory
    private var captureContinuation: AsyncStream<URL>.Continuation?
    private var tetherTask: Task<Void, Never>?
    /// A time-suffixed value ("Ns"/"Nms") always blocks for the *exact* full duration regardless of
    /// when an event lands (confirmed in gphoto2's own man page: "--wait-event=5s will take exactly
    /// 5 seconds") — that fixed window, not transfer speed, was the dominant source of the
    /// camera-shutter download delay: the log showed every camera-triggered frame taking a
    /// consistent ~2-2.9s at the old "2s", matching the window almost exactly. It's also the
    /// worst-case added latency before an app-shutter trigger — which shares this same shell via
    /// the command lock — can acquire it. A bare count ("1", wait for N events instead of time)
    /// looked better on paper but crashed the shell outright in testing ("Camera session closed
    /// unexpectedly") — not safe with this camera/gphoto2 version, so stick to duration-based and
    /// just make the duration small instead.
    private static let tetherWaitWindow = "50ms"

    /// The relaxed listening window, used once shooting goes quiet.
    ///
    /// The short window above interrogates the camera about twelve times a second, and *that* is
    /// what makes the body report "busy" and lock its own dials — there is never an idle moment in
    /// which it can accept input. A long window is not slower listening: `wait-event-and-download`
    /// downloads a frame the instant the event arrives either way, and only the app's notification
    /// waits for the window to close. So the cost is up to a second before a body-shutter shot
    /// appears in the gallery, and the gain is a camera that is usable in the photographer's own
    /// hands without them having to ask the app for permission.
    private static let idleTetherWaitWindow = "1s"
    /// How long after a frame arrives to keep using the short, responsive window, so bursts and
    /// app-triggered shots stay snappy.
    private static let activeShootingWindow: TimeInterval = 8

    private var lastFrameAt = Date.distantPast

    /// Short and responsive while shooting, long and unobtrusive when not.
    private var tetherWindow: String {
        Date().timeIntervalSince(lastFrameAt) < Self.activeShootingWindow
            ? Self.tetherWaitWindow : Self.idleTetherWaitWindow
    }

    // Serializes shell commands. Swift actors are re-entrant across `await` (and `sendCommand`
    // awaits while polling), so without this the background tether watcher and an app-shutter
    // capture could interleave their writes/reads on the one shell. Every `sendCommand` holds it.
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private var isEstablishing = false

    /// Fair FIFO acquisition. The `!commandWaiters.isEmpty` half matters as much as the busy flag:
    /// without it, a caller that re-acquires immediately after releasing — which is exactly what
    /// the live view loop does — barges ahead of an already-woken waiter every time, and starves
    /// it indefinitely. That made the shutter unusable while live view was running: the capture
    /// queued and never got a turn.
    private func acquireCommandLock() async {
        if commandBusy || !commandWaiters.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commandWaiters.append(continuation)
            }
            // Resumed by `releaseCommandLock`, which hands ownership over directly rather than
            // dropping the lock — so there's deliberately no re-check of `commandBusy` here.
        }
        commandBusy = true
    }

    private func releaseCommandLock() {
        if commandWaiters.isEmpty {
            commandBusy = false
        } else {
            // Direct handoff: stay busy so a barging caller can't slip in ahead of the queue.
            commandWaiters.removeFirst().resume()
        }
    }

    /// Curated, user-facing status lines (connecting, waiting for the camera, reconnecting) for the
    /// UI to show. Diagnostics go to the log file instead — see `log` vs `status`.
    nonisolated func progressStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    private func setContinuation(_ continuation: AsyncStream<String>.Continuation) {
        progressContinuation = continuation
    }

    /// Emits the local file URL of every downloaded frame — whether triggered by the app shutter or
    /// the camera's own shutter — so the UI treats both identically.
    nonisolated func captureStream() -> AsyncStream<URL> {
        AsyncStream { continuation in
            Task { await self.setCaptureContinuation(continuation) }
        }
    }

    private func setCaptureContinuation(_ continuation: AsyncStream<URL>.Continuation) {
        captureContinuation = continuation
    }

    private var connectedContinuation: AsyncStream<Bool>.Continuation?

    /// Emits `true` when the camera link comes up and `false` when it drops, so the UI can show an
    /// accurate connection state (the 1DX II resets its wired-LAN link every couple of minutes).
    nonisolated func connectionStream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { await self.setConnectedContinuation(continuation) }
        }
    }

    private func setConnectedContinuation(_ continuation: AsyncStream<Bool>.Continuation) {
        connectedContinuation = continuation
        // The registration Task races the first connect: a fast connect can markConnected(true)
        // before this runs, and that event would be lost — the UI would show disconnected until
        // the next transition. Seed the stream with the current state so no listener starts stale.
        continuation.yield(isConnected)
    }

    /// Single choke point for the connection flag so every up/down transition is broadcast.
    private func markConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        if connected { hasEverConnected = true }
        connectedContinuation?.yield(connected)
    }

    /// Set the first time this session ever completes a real connection. Gates `isReachable`'s
    /// probe-then-disconnect: live packet capture caught it landing mid-camera's own SSDP/mDNS
    /// pairing negotiation (byebye → 3x probe → alive, ~5-8s uninterrupted) and immediately
    /// FIN-closing — the camera reacted by leaving both multicast groups and abandoning its own
    /// announce sequence after just one probe instead of the normal three, every single time. A
    /// *real* client staying connected through the protocol (what openShell does) is fine even
    /// during that window — the July capture shows a real connection landing mid-announce-burst
    /// with no disruption — so only skip straight to a real attempt (no throwaway probe first)
    /// until this session has proven the camera is already paired and probing is safe.
    private var hasEverConnected = false

    /// Internal diagnostics: console plus ~/Library/Logs/CanonTether.log. Deliberately never
    /// reaches the UI — gphoto2's send/recv chatter is for debugging the wired-LAN drops, not for
    /// the photographer to read mid-shoot. The status pill gets only what `status` publishes.
    private func log(_ message: String) {
        #if DEBUG
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        print("[\(timestamp)] \(message)")
        #endif
        FileHandle.appendLog(message)
    }

    /// A short, plain-language line for the status pill. Logged as well, so the file still shows
    /// what the photographer was told and when, alongside the surrounding detail.
    private func status(_ message: String) {
        log(message)
        progressContinuation?.yield(message)
    }

    private func binaryPath() throws -> String {
        guard let path = Self.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw GPhotoError.binaryNotFound
        }
        return path
    }

    /// A directly-attached USB camera's gphoto2 port string (e.g. "usb:020,004"), if any.
    private func usbCameraPort(_ binary: String) -> String? {
        guard let output = try? runOneShot(binary, ["--auto-detect"]) else { return nil }
        let lines = output.split(separator: "\n").dropFirst(2)
        guard let cameraLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let port = cameraLine.split(separator: " ").last,
              port.hasPrefix("usb:") else {
            // Unexpected output shapes (libusb warnings, banners) would otherwise yield a garbage
            // token passed straight to --port, burning the full readyTimeout against it.
            return nil
        }
        return String(port)
    }

    /// Canon MAC-address OUI prefixes used to positively identify the camera in the ARP table.
    private static let canonOUIs = ["9c:32:ce"]

    /// Lines look like: "? (169.254.189.16) at 9c:32:ce:51:70:1c on en0 ifscope [ethernet]". No
    /// interface name in the pattern: the camera adapter's interface varies by Mac (en0 built-in
    /// Ethernet vs. en8 on a USB-Ethernet dongle, see CLAUDE.md), so it's identified by Canon MAC
    /// OUI / link-local address instead, not by which interface it happens to land on.
    private static let arpEntryPattern = try! NSRegularExpression(
        pattern: #"\((\d{1,3}(?:\.\d{1,3}){3})\) at ([0-9a-f:]+) on \w+"#,
        options: .caseInsensitive)

    /// Remembers where the camera answered last time, so a camera that doesn't announce itself can
    /// still be found on the next session (see `solicitCamera`).
    static let lastKnownIPKey = "lastKnownCameraIP"

    /// Where the camera is. Reads the ARP table, and if that's empty *solicits* a reply first.
    ///
    /// Discovery used to be purely passive, which was a real bug: the ARP table only holds hosts
    /// this Mac has actually exchanged packets with, so a camera that comes up without announcing
    /// itself (no gratuitous ARP — observed live 2026-08-17, the body sat answering pings for nine
    /// minutes while the app reported "waiting for camera") is invisible forever, and the app never
    /// even attempts a connection. A single ICMP echo makes the kernel resolve the address, which
    /// populates ARP and hands the normal path something to work with.
    ///
    /// ICMP is safe during pairing in a way a TCP probe is not: the disruption documented in
    /// CLAUDE.md is specifically a connect-then-close on port 15740. A ping was verified live
    /// against a mid-pairing camera — it answered, kept pairing, and connected immediately after.
    private func cameraIP() async -> String? {
        if let known = networkCameraIP() { return known }
        solicitCamera()
        let found = networkCameraIP()
        // Discovery used to log nothing at all, which made a 19.5-hour fruitless wait
        // indistinguishable from an absent camera: the log showed only "waiting for camera" with
        // no record of what was tried or what the ARP table held. Rate-limited so a long wait
        // stays readable.
        discoveryLogCycle += 1
        if found == nil {
            discoveryFailureStreak += 1
            if discoveryLogCycle % Self.discoveryLogEvery == 0 {
                log("discovery: no camera for \(discoveryFailureStreak) cycles — arp=\(arpSummary()), solicited=\(lastSolicited.joined(separator: ","))")
            }
            // Self-heal. Quitting and reopening the app is the one thing observed to fix a wedged
            // reconnect (a 19.5-hour fruitless wait that a fresh process resolved in 10 seconds),
            // so rather than require that, periodically restore the state a relaunch would have:
            // no stale shell, no assumption that probing is safe, and a fresh solicit rhythm.
            if discoveryFailureStreak % Self.selfHealAfter == 0 {
                log("discovery: resetting session state after \(discoveryFailureStreak) failed cycles")
                closeShell()
                hasEverConnected = false
                solicitCycle = 0
                buffer.clear()
            }
        } else {
            discoveryFailureStreak = 0
        }
        return found
    }

    /// What to tell the photographer when the camera isn't accepting connections.
    ///
    /// This used to say "press Start pairing devices" unconditionally, which is **wrong** for the
    /// common case and actively harmful: a camera that has paired with this Mac before only needs
    /// to be left alone to reconnect, and starting a fresh pairing puts it into a
    /// register-a-new-device state that the app's resume attempts can't satisfy — observed today
    /// wedging a working setup for several minutes. Only a camera we have no record of pairing
    /// with needs that instruction; pairing itself is camera-driven by Canon's design, so the
    /// advice matters.
    private func pairingGuidance() -> String {
        UserDefaults.standard.string(forKey: Self.lastKnownIPKey) == nil
            ? "Camera needs pairing — press “Start pairing devices” on the camera"
            : "Reconnecting to the camera — no action needed on the camera"
    }

    private var discoveryFailureStreak = 0
    /// Sweep neighbours every cycle past this point — the remembered address clearly isn't it.
    private static let desperateAfter = 30
    /// Cycles of total failure before restoring the state a relaunch would give us.
    private static let selfHealAfter = 120

    private var discoveryLogCycle = 0
    private var lastSolicited: [String] = []
    /// Roughly once a minute at the ~2s loop cadence.
    private static let discoveryLogEvery = 30

    /// A compact view of what the ARP table actually holds, for the discovery log — the missing
    /// piece when diagnosing "the app can't see a camera that is plainly there".
    private func arpSummary() -> String {
        guard let output = try? runOneShot("/usr/sbin/arp", ["-an"]) else { return "arp-failed" }
        let lines = output.split(separator: "\n")
        let complete = lines.filter { !$0.contains("incomplete") && $0.contains(" at ") }
        let canon = complete.filter { line in
            Self.canonOUIs.contains { line.lowercased().contains($0) }
        }
        return "\(lines.count) entries/\(complete.count) resolved/\(canon.count) canon"
    }

    /// Pings candidate addresses so an unannounced camera shows up in the ARP table. Cheap and
    /// bounded: the remembered address every time, and a few neighbours of this Mac's own
    /// link-local address occasionally, since manual setup puts the camera right next to us.
    private func solicitCamera() {
        var candidates: [String] = []
        if let remembered = UserDefaults.standard.string(forKey: Self.lastKnownIPKey) {
            candidates.append(remembered)
        }
        solicitCycle += 1
        // Sweep the neighbourhood occasionally, and *every* cycle once the remembered address has
        // clearly stopped working — a camera that came back on a different self-assigned address
        // is otherwise invisible forever, because the one address we keep pinging is dead and
        // nothing else ever populates ARP for a body that doesn't announce itself.
        if solicitCycle % Self.neighbourSweepEvery == 0 || discoveryFailureStreak > Self.desperateAfter {
            candidates.append(contentsOf: neighbourCandidates())
        }
        let targets = Array(candidates.prefix(Self.maxSolicitsPerCycle))
        lastSolicited = targets.isEmpty ? ["none"] : targets
        for ip in targets {
            // -W is milliseconds to wait for a reply, -t seconds before ping gives up entirely:
            // both tight, because this runs inside the once-a-second discovery loop.
            _ = try? runOneShot("/sbin/ping", ["-c", "1", "-W", "300", "-t", "1", ip], timeout: 2)
        }
    }

    /// Addresses either side of this Mac's own link-local address — where `CameraNetworkSuggestion`
    /// tells the photographer to put the camera during manual setup, so it's where an
    /// un-remembered camera most likely is.
    private func neighbourCandidates() -> [String] {
        guard let own = NetworkInterfaceScanner.linkLocalInterfaces().first?.ipAddress else { return [] }
        let octets = own.split(separator: ".")
        guard octets.count == 4, let last = Int(octets[3]) else { return [] }
        let prefix = octets[0...2].joined(separator: ".")
        return [1, -1, 2, -2]
            .map { last + $0 }
            .filter { (1...254).contains($0) }
            .map { "\(prefix).\($0)" }
    }

    /// Consecutive fast refusals, driving the connect back-off.
    private var consecutiveRefusals = 0
    private var solicitCycle = 0
    private static let neighbourSweepEvery = 5
    private static let maxSolicitsPerCycle = 5

    /// The camera's current IP, from the ARP table. Uses `arp -an` (numeric) rather than `arp -a`:
    /// the latter does reverse-DNS on every entry and takes ~15s here, which was starving the whole
    /// discovery/reconnect loop; the numeric form returns in milliseconds. Since numeric output
    /// drops the "cwc…" hostname, the camera is identified by its Canon MAC OUI, with a link-local
    /// (169.254.x) peer as the fallback (EOS Utility wired-LAN self-assigns one).
    ///
    /// Bonjour is deliberately *not* used here, despite the camera advertising `_ptp._tcp` (as
    /// `ICPO-WFTEOSSystemService<serial>`) — tested 2026-08-17 against the live camera: browsing
    /// finds the service fine, but **resolving it to an address always times out**
    /// (`NSNetServicesTimeoutError`, and `dns-sd -L` gets nothing either). The body announces its
    /// PTR record but won't answer the follow-up SRV/A queries, so mDNS can report that a camera
    /// exists and never say where. Don't rebuild this expecting a faster discovery path.
    private func networkCameraIP() -> String? {
        guard let arpOutput = try? runOneShot("/usr/sbin/arp", ["-an"]) else { return nil }
        // Only interfaces where *this Mac* has a link-local address of its own. The camera is a
        // neighbour on the cable, so it can only be on one of those.
        //
        // Without this filter the fallback took the first `169.254.x` address in the whole ARP
        // table, and on a Mac with Wi-Fi up that is somebody else's AirDrop peer: observed the app
        // trying to reach 169.254.57.52 on **en1 (Wi-Fi)** for four minutes while the camera sat
        // answering pings in 0.3 ms at 169.254.76.171 on **en0 (Ethernet)**. Every log line looked
        // healthy — "found camera at …, connecting…" — because discovery was certain and wrong.
        // Interfaces on which this Mac has a link-local address. When the camera's link is down
        // this is empty — which is itself the answer, and must not be treated as "no filter".
        let localInterfaces = linkLocalInterfaces()
        let pattern = Self.arpEntryPattern
        var candidates: [String] = []
        for line in arpOutput.split(separator: "\n") {
            let lineString = String(line)
            let nsLine = lineString as NSString
            guard let match = pattern.firstMatch(in: lineString, range: NSRange(location: 0, length: nsLine.length)) else {
                continue
            }
            let ip = nsLine.substring(with: match.range(at: 1))
            let mac = nsLine.substring(with: match.range(at: 2)).lowercased()
            let interface = Self.arpInterface(in: lineString)
            if let interface, !localInterfaces.isEmpty, !localInterfaces.contains(interface) { continue }
            if Self.canonOUIs.contains(where: { mac.hasPrefix($0) }) {
                return ip // unambiguously the Canon body, whatever else is on the network
            }
            if ip.hasPrefix("169.254.") { candidates.append(ip) }
        }
        // The address this camera was last reached at, if it is answering now. A remembered
        // address beats any heuristic: it is the one host known to have been the camera.
        if let remembered = UserDefaults.standard.string(forKey: Self.lastKnownIPKey),
           candidates.contains(remembered) || localInterfaces.isEmpty,
           isAnswering(remembered) {
            return remembered
        }

        // **No blanket fallback.** Returning "the first link-local address we can see" is what kept
        // sending the app to a Wi-Fi peer: on a Mac with Wi-Fi up, link-local addresses belong to
        // AirDrop and friends, and one of them answered ICMP perfectly happily while the camera was
        // not yet on the network. Three separate bogus addresses were tried across one afternoon,
        // each costing a 100-second connect timeout.
        //
        // If this Mac has no link-local address of its own, the wired link to the camera is not up,
        // and there is nothing on that network to find — say so and wait, rather than spending
        // minutes proving that somebody's laptop is not a camera.
        guard !localInterfaces.isEmpty else { return nil }
        for ip in candidates where isAnswering(ip) { return ip }
        return nil
    }

    /// Interfaces on which this Mac holds a 169.254 address.
    private func linkLocalInterfaces() -> Set<String> {
        guard let output = try? runOneShot("/sbin/ifconfig", []) else { return [] }
        var found: Set<String> = []
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if !text.hasPrefix("\t"), !text.hasPrefix(" "), let name = text.split(separator: ":").first {
                current = String(name)
            } else if text.contains("inet 169.254."), let current {
                found.insert(current)
            }
        }
        return found
    }

    /// Whether an address replies to a single ping. Deliberately ICMP, never a TCP probe.
    private func isAnswering(_ ip: String) -> Bool {
        guard let output = try? runOneShot("/sbin/ping", ["-c", "1", "-W", "400", "-t", "1", ip], timeout: 2)
        else { return false }
        return output.contains("bytes from")
    }

    /// The interface an `arp -an` line names: `? (169.254.76.171) at 0:1:2:3:4:5 on en0 [ethernet]`.
    static func arpInterface(in line: String) -> String? {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: "on"), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    private func runOneShot(_ executablePath: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let env = Self.environment(forBinary: executablePath) { process.environment = env }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Registered like the shell is: a `gphoto2 --auto-detect` wedged in a USB ioctl at quit
        // time would otherwise be reparented to launchd still holding its claim on the camera —
        // the same ghost-process problem the registry exists to prevent.
        ChildProcessRegistry.shared.register(process)
        // Drain both pipes on background threads concurrently with waiting for exit —
        // reading only after waitUntilExit() deadlocks if the child writes more than the
        // pipe buffer before exiting, since it would then block on a full pipe nothing is
        // reading while this thread blocks in waitUntilExit().
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        let results = NSMutableArray(array: [Data(), Data()])
        let readGroup = DispatchGroup()
        // .userInitiated, not .utility: this backs networkCameraIP()'s ARP lookup, called on every
        // reconnect retry — a .utility thread can sit unscheduled under load well past what these
        // short-lived reads should take (see isReachable's matching note on the same theory).
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            results[0] = outHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            results[1] = errHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        // `gphoto2 --auto-detect` occasionally stalls scanning the USB bus (seen stalling this
        // synchronous call, and with it the whole ARP-based reconnect loop that calls it inline,
        // for 30-80s+) — kill the child past `timeout` so a slow probe can't starve reconnect
        // polling that's supposed to run about once a second.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // SIGTERM can be ignored by a child wedged in an uninterruptible USB ioctl, which would
        // block waitUntilExit() — and this whole actor — forever. Escalate to SIGKILL.
        let killer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 3, execute: killer)
        process.waitUntilExit()
        watchdog.cancel()
        killer.cancel()
        readGroup.wait()
        let outData = results[0] as! Data
        let errData = results[1] as! Data
        let output = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        guard process.terminationStatus == 0 else {
            throw GPhotoError.commandFailed(output)
        }
        return output
    }

    // MARK: - Persistent shell session

    /// Spawns `gphoto2 --shell` against `port` and waits for a `summary` response to confirm
    /// the camera actually answered (including waiting out the on-camera confirmation prompt).
    private func openShell(port: String) async -> Bool {
        // No hardcoded fallback path: if gphoto2 disappears mid-session (brew uninstall) the retry
        // loop would otherwise spin silently against a nonexistent binary forever.
        guard let binary = try? binaryPath() else {
            status("gphoto2 not found — install it with: brew install libgphoto2 gphoto2")
            return false
        }
        do {
            // Staging is what the shell actually needs; it must exist before gphoto2 launches or
            // the process can't start. It lives in Caches, so it's always writable — the capture
            // folder is checked separately at import time, where a failure can be reported without
            // costing the connection.
            try FileManager.default.createDirectory(at: Self.stagingDirectory, withIntermediateDirectories: true)
        } catch {
            status("Can't create the download staging folder — check disk space")
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--port", port, "--shell"]
        if let env = Self.environment(forBinary: binary) { proc.environment = env }
        // The interactive shell doesn't reliably honor --filename's full-path/pattern argument
        // the way the one-shot CLI does — downloads land as bare camera-side names (e.g.
        // capt0000.cr2) in the process's cwd. That cwd is fixed for the life of the process, so it
        // points at a *staging* folder rather than the capture folder: `importDownloaded` moves
        // each file into whichever project is current, which is what lets the photographer switch
        // projects without the connection being torn down and re-paired.
        proc.currentDirectoryURL = Self.stagingDirectory

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stdout

        let buffer = buffer
        buffer.clear()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty data means EOF (the process's stdout closed) — GCD will keep firing this
            // handler forever otherwise, spinning a CPU core at 100% reading nothing.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            buffer.append(text)
        }

        do {
            try proc.run()
        } catch {
            return false
        }

        process = proc
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading
        ChildProcessRegistry.shared.register(proc)
        try? stdinHandle?.write(contentsOf: "summary\n".data(using: .utf8)!)

        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while Date() < deadline {
            let snapshot = buffer.snapshot()
            if snapshot.contains("Manufacturer:") {
                buffer.clear()
                await optimizeCaptureTarget()
                return true
            }
            if snapshot.contains("Connection refused") || snapshot.contains("Timeout") || snapshot.contains("ERROR") {
                logConnectFailure("error reported", snapshot)
                closeShell()
                return false
            }
            if !proc.isRunning {
                logConnectFailure("gphoto2 exited", snapshot)
                closeShell()
                return false
            }
            if Task.isCancelled {
                closeShell()
                return false
            }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        logConnectFailure("no response within \(Int(Self.readyTimeout))s", buffer.snapshot())
        closeShell()
        return false
    }

    /// Records *why* a connection attempt failed. Without this a failed connect is a black box —
    /// the shell's own output was previously read for markers and then thrown away, so the log
    /// showed an endless list of attempts with no indication whether the camera refused, answered
    /// with an error, or accepted and went quiet. Rate-limited so a long retry run can't flood the
    /// file; the first few carry the full text, which is where the diagnosis lives.
    /// Set when the camera actively refused the PTP/IP port. That refusal is conclusive: the body
    /// is up and answering at the IP level but its PTP service isn't listening, which on this
    /// camera means it is working through its own pairing. Probing it further is both pointless
    /// and harmful — a connect-then-abandon is precisely what aborts that negotiation (see
    /// CLAUDE.md) — so one refusal is enough to switch to patient, probe-free attempts.
    private var lastConnectRefused = false

    private func logConnectFailure(_ reason: String, _ snapshot: String) {
        if snapshot.contains("Connection refused") { lastConnectRefused = true }
        connectFailureLogCount += 1
        if connectFailureLogCount <= Self.verboseConnectFailures {
            log("connect failed (\(reason)): \(snapshot.suffix(400).debugDescription)")
        } else if connectFailureLogCount % 20 == 0 {
            log("connect failed (\(reason)) — \(connectFailureLogCount) failures so far")
        }
    }

    private var connectFailureLogCount = 0
    private static let verboseConnectFailures = 5
    /// Any command waiting longer than this for the shell is worth recording — it means something
    /// else is monopolising the camera.
    private static let slowLockWarning: TimeInterval = 1
    /// Characters of a camera response worth keeping in the log.
    private static let maxLoggedResponse = 240

    private static let captureTargetPath = "/main/settings/capturetarget"
    // Names vary by body/firmware; match loosely rather than pin one exact string.
    private static let directTransferTargets = ["Internal RAM", "RAM", "Computer"]

    /// With `capturetarget` on "Memory card", the camera writes the file to the card first and
    /// gphoto2 downloads it from there afterward — an extra round trip on top of the transfer
    /// itself. Direct-to-RAM skips that. Best-effort and silent on failure: some bodies/modes
    /// don't expose this property at all, which shouldn't block the connection.
    private func optimizeCaptureTarget() async {
        guard let output = try? await sendCommand(
            "get-config \(Self.captureTargetPath)",
            doneMarkers: ["END", "*** Error", "ERROR"],
            timeout: 10
        ), let setting = CameraSetting.parse(from: output, path: Self.captureTargetPath) else {
            log("capturetarget: not exposed by this camera/mode")
            return
        }
        guard let fast = setting.choices.first(where: { choice in
            Self.directTransferTargets.contains { choice.localizedCaseInsensitiveContains($0) }
        }) else {
            log("capturetarget: no direct-transfer choice among \(setting.choices), leaving at \(setting.current)")
            return
        }
        guard setting.current != fast else {
            log("capturetarget: already \(fast)")
            return
        }
        log("capturetarget: switching from \(setting.current) to \(fast) for faster tethered transfer")
        let result = try? await sendCommand(
            "set-config \(Self.captureTargetPath)=\(fast)",
            doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
            timeout: 10
        )
        if let result, result.contains("*** Error") || result.contains("ERROR") {
            log("capturetarget: set failed:\n\(result)")
        }
    }

    private func closeShell() {
        if let stdinHandle {
            // Only ask the shell to exit if it's still alive — writing "exit" to a shell that
            // already died (e.g. after the camera reset the link) hits a readerless pipe. SIGPIPE
            // is ignored process-wide, but skip the doomed write anyway; terminate() handles it.
            if process?.isRunning == true {
                try? stdinHandle.write(contentsOf: "exit\n".data(using: .utf8)!)
            }
            try? stdinHandle.close()
        }
        // Detach the pipe callback *before* terminating: the dying shell's final flush (error
        // text like "Connection reset") would otherwise land in the shared buffer after the next
        // openShell's clear() and be mistaken for the new shell's output — seen tearing down a
        // perfectly good new connection whose handshake poll matched the stale "ERROR" text.
        stdoutHandle?.readabilityHandler = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
        if let dying = process {
            dying.terminate()
            // Reaped off-thread so the self-healing reconnect path doesn't accumulate zombies,
            // without blocking the actor waiting for the child to die.
            DispatchQueue.global(qos: .utility).async { dying.waitUntilExit() }
        }
        process = nil
        stdinHandle = nil
        markConnected(false)
    }


    // A dedicated keep-alive ping used to live here, disabled behind a note suspecting it *caused*
    // the drops it was meant to prevent (the link survived a 90s idle with zero traffic in a manual
    // test, but died within one keep-alive cycle in both app-driven tests). It's gone rather than
    // left commented out: `startTetherWatch` polls `wait-event-and-download` continuously the whole
    // time the session is up, so the link never sees anything close to the camera's ~90s idle
    // timeout anyway. There is no idle state left for a keep-alive to protect.

    /// Standard PTP/IP port, per gphoto2's `ptpip:` driver default.
    private static let ptpipPort: UInt16 = 15740

    /// A cheap TCP reachability probe against the PTP/IP port, used before committing to a full
    /// `gphoto2 --shell` handshake. An ARP entry can outlive the camera's actual pairing under that
    /// address (it re-paired under a new self-assigned IP, but the old entry hasn't aged out yet) —
    /// connecting to a dead address doesn't fail fast, it just hangs until openShell's own ~100s
    /// readyTimeout gives up. A live TCP handshake here in a couple seconds is a strong signal the
    /// full attempt is worth making; failing it means don't bother waiting the full 100s to find out.
    ///
    /// Raw BSD socket + `poll()` rather than Network.framework: a non-blocking `connect()` returns
    /// immediately with `EINPROGRESS` regardless of whether the kernel's own ARP resolution for a
    /// dead destination has finished, so `poll()`'s timeout is a hard, OS-level deadline — unlike
    /// `NWConnection`, whose higher-level state machine was observed (against a genuinely stale
    /// link-local address) taking 15-25s to report failure despite an identical 2s target, seemingly
    /// queued behind in-flight kernel ARP retries that cancelling the connection object didn't abort.
    /// Closing the raw socket on any exit path does cleanly abandon the attempt at the kernel level.
    private func isReachable(_ ip: String, timeout: TimeInterval = 2) async -> Bool {
        let port = Self.ptpipPort
        // .userInitiated, not .utility: this gates user-visible reconnect speed, and a .utility
        // thread can sit unscheduled under system load well past poll()'s own 2s deadline once it
        // finally runs — observed live as intermittent ~12s stalls on top of an otherwise ~2s cadence.
        return await Task.detached(priority: .userInitiated) {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return false }
            defer { close(sock) }

            let flags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

            let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectResult == 0 { return true } // connected immediately
            guard errno == EINPROGRESS else { return false }

            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeout * 1000))
            guard pollResult > 0, Int32(pfd.revents) & Int32(POLLOUT) != 0 else { return false }

            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
            return soError == 0
        }.value
    }

    /// Ensures a live, camera-confirmed shell session exists, waiting indefinitely for the
    /// camera to appear on the network/USB while the user works through its pairing menu.
    private func ensureConnected() async throws {
        if isConnected, let process, process.isRunning {
            return
        }
        // Coalesce concurrent connect attempts (an app capture and the tether watcher can both
        // notice the session is down at once) so we never spawn two gphoto2 shells at the camera.
        while isEstablishing {
            try? await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
            if isConnected, let process, process.isRunning { return }
        }
        // Re-check after the wait: the establisher may have finished successfully in the window
        // since this waiter's last in-loop check — proceeding would open a second gphoto2 shell
        // against an already-connected camera and orphan the first one.
        if isConnected, let process, process.isRunning { return }
        isEstablishing = true
        defer { isEstablishing = false }

        let binary = try binaryPath()
        var waited = 0
        while true {
            // Network is the primary path here, and `cameraIP()` (a Bonjour cache read, falling
            // back to ARP) is fast, so check it every second — a camera that reappears after a
            // reset is grabbed promptly.
            if var ip = await cameraIP() {
                log("found camera at \(ip), connecting...")
                status("Connecting to camera…")
                var probeFailures = 0
                for attempt in 1...Self.connectRetryAttempts {
                    // Only probe-then-disconnect once this session has proven the camera is already
                    // paired (see hasEverConnected's doc comment) — during a fresh pairing this
                    // throwaway check disrupts the camera's own in-progress negotiation.
                    // `lastConnectRefused`: one refusal already tells us the camera is pairing, so
                    // don't spend five more probes discovering that — especially since each probe
                    // risks aborting the very negotiation we're waiting on.
                    if hasEverConnected, !lastConnectRefused {
                        guard await isReachable(ip) else {
                            // A dead/stale address: don't sink the full ~100s readyTimeout into a
                            // gphoto2 handshake attempt that will never get an answer. Re-resolve ARP
                            // and try again promptly instead.
                            probeFailures += 1
                            if probeFailures >= Self.probeFailureLimit {
                                // A camera that keeps refusing 15740 at an address ARP still vouches
                                // for is almost certainly re-pairing, not merely stale — and the
                                // probes themselves disrupt that negotiation. Drop back to
                                // fresh-pairing behavior: no more probes, real patient attempts only.
                                log("probe refused \(probeFailures)x — assuming camera is re-pairing, switching to patient connect attempts")
                                // Tell the photographer, not just the log: pairing can only be
                                // completed from the camera's own screen (Canon's design), so an app
                                // that silently says "Connecting…" here leaves them watching a
                                // spinner for a step only they can take.
                                status(pairingGuidance())
                                hasEverConnected = false
                                continue
                            }
                            log("ptpip:\(ip) not answering — re-checking for a fresher address")
                            guard let freshIP = await cameraIP() else { break }
                            ip = freshIP
                            try? await Task.sleep(nanoseconds: Self.connectRetryDelay)
                            continue
                        }
                        probeFailures = 0
                    }
                    log("attempt \(attempt)/\(Self.connectRetryAttempts): connecting to ptpip:\(ip)")
                    if await openShell(port: "ptpip:\(ip)") {
                        consecutiveRefusals = 0
                        lastConnectRefused = false
                        // Remember where it answered: next session can solicit this address
                        // directly rather than waiting for an announcement that may never come.
                        UserDefaults.standard.set(ip, forKey: Self.lastKnownIPKey)
                        markConnected(true)
                        status("Connected")
                        return
                    }
                    // A failed attempt against a link-local address that's since gone stale (the
                    // camera re-paired under a new self-assigned IP mid-attempt) doesn't error out —
                    // it just hangs until openShell's own ~100s readyTimeout gives up. Re-resolve ARP
                    // before the next attempt so a fresh IP is picked up immediately instead of
                    // burning that same ~100s timeout again against an address that will never answer.
                    guard let freshIP = await cameraIP() else { break }
                    if freshIP != ip {
                        log("camera moved to \(freshIP) mid-retry — reconnecting there instead")
                        ip = freshIP
                        consecutiveRefusals = 0
                        continue
                    }
                    // Back off when the camera is refusing outright (a failure that returns in ~2s
                    // rather than hanging): that's a body whose PTP service isn't up yet, usually
                    // because it's still working through its own pairing. Retrying 30 times a
                    // minute doesn't make it ready sooner, and this camera is demonstrably touchy
                    // about connection churn during pairing (see CLAUDE.md). Ramp 1s → 8s and stay
                    // there, so we still catch it promptly once it does start listening.
                    consecutiveRefusals += 1
                    // Say what's happening once it's clearly not a momentary blip. The camera is
                    // reachable but refusing its PTP port, which means it's working through
                    // pairing — and what the photographer should do about that depends entirely on
                    // whether this Mac has paired with it before.
                    if consecutiveRefusals == Self.refusalsBeforeGuidance {
                        status(pairingGuidance())
                    }
                    let backoff = min(Self.connectRetryDelay << min(consecutiveRefusals / 3, 3),
                                      Self.maxConnectRetryDelay)
                    try? await Task.sleep(nanoseconds: backoff)
                }
            } else {
                // No camera on the network. `gphoto2 --auto-detect` (the USB probe) is slow, so run
                // it only occasionally instead of every second — otherwise it stalls this loop and
                // delays noticing the network camera come back.
                if waited % 10 == 0, let usbPort = usbCameraPort(binary), await openShell(port: usbPort) {
                    markConnected(true)
                    status("Connected")
                    return
                }
                // The pill only needs the state; the running second count stays in the log.
                // After a while, say *what to check* rather than repeating "waiting" forever — a
                // camera that never appears is nearly always powered off, on the wrong connection
                // profile, or on a dead cable, and none of that is visible from in here.
                if waited == 0 {
                    status("Waiting for camera…")
                } else if waited == Self.waitingHintDelay {
                    status("Waiting for camera — check it's powered on and set to the wired-LAN profile")
                }
                if waited % 5 == 0 {
                    log("waiting for camera to appear (\(waited)s)...")
                }
            }
            // `try?` on the sleeps above swallows CancellationError, so a cancelled task would
            // otherwise degenerate into a hot spin — zero-length sleeps hammering networkCameraIP()
            // (one spawned `arp` process per iteration) at 100% of a thread, forever.
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: Self.cameraWaitInterval)
            waited += 1
        }
    }

    /// Sends a command to the already-open shell session and waits for it to finish. `quiet`
    /// suppresses the verbose send/recv logging for the high-frequency tether poll so it doesn't
    /// flood the log file.
    /// Runs a batch of commands under a single lock acquisition.
    ///
    /// Reading the camera's settings is five separate `get-config`s, and one-lock-per-command made
    /// each of them queue behind a full tether listening window — so a settings read cost about
    /// five seconds and the inspector lagged the camera's own dials by six. Taking the lock once
    /// for the batch turns that into one wait plus five fast commands, and holds the camera for a
    /// single contiguous window instead of interleaving with the tether watch five times.
    private func withCommandLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireCommandLock()
        defer { releaseCommandLock() }
        return try await body()
    }

    private func sendCommand(_ command: String, doneMarkers: [String], timeout: TimeInterval, quiet: Bool = false) async throws -> String {
        // Timed, because the lock is acquired *before* anything is logged: a command starved here
        // leaves no trace at all, which is precisely how a shutter press blocked behind the live
        // view loop looked like "the app ignored me" with an empty log.
        let lockWaitStart = Date()
        return try await withCommandLock {
            let lockWait = Date().timeIntervalSince(lockWaitStart)
            if lockWait > Self.slowLockWarning {
                log("command lock: \(command) waited \(String(format: "%.1f", lockWait))s")
            }
            return try await sendCommandLocked(command, doneMarkers: doneMarkers, timeout: timeout, quiet: quiet)
        }
    }

    /// The command lock must already be held — `acquireCommandLock` is not reentrant.
    private func sendCommandLocked(_ command: String, doneMarkers: [String], timeout: TimeInterval, quiet: Bool = false) async throws -> String {
        guard let stdinHandle, let process, process.isRunning else {
            throw GPhotoError.noCameraDetected
        }
        buffer.clear()
        if !quiet { log("sending: \(command)") }
        try? stdinHandle.write(contentsOf: (command + "\n").data(using: .utf8)!)

        let deadline = Date().addingTimeInterval(timeout)
        var lastLoggedSnapshot = ""
        var answeredOverwritePrompts = 0
        while Date() < deadline {
            let snapshot = buffer.snapshot()
            if snapshot != lastLoggedSnapshot {
                // Log only the newly-arrived suffix, not the whole accumulated buffer — re-logging
                // the full snapshot on every change made a long command's output superlinear in the
                // log file (a big contributor to unbounded log growth).
                if !quiet {
                    let delta = snapshot.hasPrefix(lastLoggedSnapshot)
                        ? String(snapshot.dropFirst(lastLoggedSnapshot.count))
                        : snapshot
                    // Capped: a single `get-config` reply can run to a couple of thousand
                    // characters of choice list, and the diagnostic value is all in the first
                    // line or two.
                    let trimmed = delta.count > Self.maxLoggedResponse
                        ? String(delta.prefix(Self.maxLoggedResponse)) + "…(+\(delta.count - Self.maxLoggedResponse) chars)"
                        : delta
                    log("recv: \(trimmed.debugDescription)")
                }
                lastLoggedSnapshot = snapshot
            }
            // The interactive shell sometimes asks to overwrite its own intermediate download
            // filename ("File captNNNN.cr2 exists. Overwrite? [y|n]") even with --force-overwrite,
            // since that flag only covers the final destination file, not this internal prompt.
            // A RAW+JPEG capture can prompt once per file, so answer every prompt, not just the
            // first — an unanswered second prompt hangs the command into the timeout and a full
            // shell teardown.
            let promptCount = snapshot.components(separatedBy: "[y|n]").count - 1
            if promptCount > answeredOverwritePrompts {
                answeredOverwritePrompts = promptCount
                log("answering overwrite prompt: y")
                try? stdinHandle.write(contentsOf: "y\n".data(using: .utf8)!)
            }
            if doneMarkers.contains(where: { snapshot.contains($0) }) {
                buffer.clear()
                return snapshot
            }
            if !process.isRunning {
                markConnected(false)
                throw GPhotoError.commandFailed("Camera session closed unexpectedly:\n\(snapshot)")
            }
            // Deliberately NOT cancellable here. The command is already written to the shell, so
            // bailing out mid-flight abandons the camera's reply, which then lands in the *next*
            // command's buffer: a stale "Saving file as capture_preview.jpg" gets imported as a
            // real capture, and a stale prompt satisfies the next command's done-marker early,
            // leaving the shell permanently one response out of phase. The deadline below bounds
            // this loop anyway, and the live view loop checks for cancellation between ticks.
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        // A timeout likely means the session is desynced (e.g. the camera's pairing was reset
        // from its own menu mid-session) — force a fresh connect on the next attempt rather than
        // silently reusing a session that will just keep timing out.
        let finalSnapshot = buffer.snapshot()
        closeShell()
        throw GPhotoError.commandFailed("Timed out waiting for camera response. Received so far: \(finalSnapshot.debugDescription)")
    }

    // MARK: - Public API

    func connect() async throws {
        // Nothing else sweeps at startup, so a frame stranded by a crash or force-quit mid-stream
        // would otherwise sit in the capture folder indefinitely.
        cleanUpPreviewFiles()
        try await ensureConnected()
        // Settle anything a previous bracket left owing before the photographer starts shooting —
        // a camera silently left on JPEG is only discovered when the files turn out wrong.
        await restorePendingImageFormat()
        startTetherWatch()
    }

    /// Points captures at a different project folder while running. The shell's working directory —
    /// where gphoto2 drops downloads — is fixed when the shell launches, so a live session is torn
    /// down here; the tether watch loop then relaunches it against the new folder within a second
    /// (or the next `connect()` does, if the camera wasn't attached). No files move: this only
    /// changes where *future* shots land, and the caller reloads the gallery from the new folder.
    /// Switches projects. **Does not touch the camera connection.**
    ///
    /// It used to tear the shell down, because gphoto2 downloads into its working directory and
    /// that's fixed when the process launches. The note saying a live switch "costs a reconnect"
    /// was written when reconnects looked cheap; they aren't — on this body one can mean pairing
    /// again from the camera's own screen, which is not an acceptable price for choosing a folder
    /// mid-shoot. Downloads now land in a fixed staging folder and `importDownloaded` moves each
    /// one into whatever project is current, so switching is instant and the camera never notices.
    func setCaptureDirectory(_ url: URL) {
        guard url != captureDirectory else { return }
        captureDirectory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Where gphoto2 is told to drop files. Fixed for the life of the process so the shell's
    /// working directory never has to change — see `setCaptureDirectory`. Kept out of the capture
    /// folder so a half-written download or a stray preview frame is never visible to the
    /// photographer as if it were a shot.
    /// Where sweeps and focus maps go: out of the photographer's project, into Caches.
    ///
    /// A sweep photographs ~96 frames to measure depth, and a bracket merges a dozen or two of a
    /// *separate* set. Writing those sweeps beside the photographs put 1,798 files and 240 MB into
    /// one shooting folder across a day's testing — the app appearing to "capture far more pictures
    /// than it merges", which is exactly what it looked like. They are diagnostics, not photographs.
    public static let diagnosticsDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CanonTether/focus scans")
    }()

    /// Sweeps to keep. They exist so a bad result can be replayed offline instead of costing
    /// another camera run, which is worth real disk — but not unboundedly.
    public static let retainedScans = 8

    /// Drops all but the newest `retainedScans` sweeps.
    public static func pruneDiagnostics() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: diagnosticsDirectory,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let byDate = entries.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in byDate.dropFirst(retainedScans) { try? fm.removeItem(at: url) }
    }

    private static let stagingDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CanonTether/incoming")
    }()

    // MARK: - Tethered capture (both shutters share this download path)

    /// Continuously downloads any frames the camera produces on its own — physical shutter,
    /// self-timer, remote — so body-triggered and app-triggered shots arrive in the app the same
    /// way. Started once after the first connect; the loop no-ops while disconnected and resumes
    /// after a reconnect. Its steady `wait-event` traffic also keeps the PTP/IP link from idling out.
    private func startTetherWatch() {
        guard tetherTask == nil else { return }
        tetherTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tetherTick()
                // This gap adds directly to shutter-to-image latency the same way the wait window
                // does (a shot fired during it has to wait out the rest before the next poll even
                // starts), so it's kept just large enough to stop back-to-back real events from
                // turning into a tight loop — not a fixed rate-limit for its own sake.
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// Suppresses the tether watch while a bracket is running. It is pure contention there: the
    /// bracket fires the shutter and downloads each frame itself, so the watcher can only compete
    /// for the command lock. Measured, that competition cost ~6 s of every 7.8 s bracket cycle
    /// (`command lock: wait-event-and-download 50ms waited 6.6s` against every step).
    private var tetherPauseDepth = 0

    func withTetherPaused<T>(_ operation: () async throws -> T) async rethrows -> T {
        tetherPauseDepth += 1
        defer { tetherPauseDepth = max(0, tetherPauseDepth - 1) }
        return try await operation()
    }

    /// Suspends the tether watch for as long as the focus-stacking window is open.
    ///
    /// Not just for the bracket. With the watch running, every live-view frame queues behind its
    /// listening window: measured after a bracket, `capture-preview waited 1.0s` on every frame and
    /// the feed crawled at roughly one frame every 2.3 s — alive, but slow enough to look frozen,
    /// which is exactly how it was reported. Nothing is lost by suspending it: the panel drives the
    /// shutter itself, so there are no body-shutter frames to miss.
    func beginExclusiveSession() { tetherPauseDepth += 1 }
    func endExclusiveSession() { tetherPauseDepth = max(0, tetherPauseDepth - 1) }

    private func tetherTick() async {
        guard tetherPauseDepth == 0 else { return }
        // If the session is down (idle reset, etc.), transparently bring it back so physical-
        // shutter capture resumes on its own. The watcher is the app's self-healing driver.
        guard isConnected, let process, process.isRunning else {
            log("tether watch: session down — reconnecting")
            try? await ensureConnected()
            return
        }
        let start = Date()
        do {
            let output = try await sendCommand(
                "wait-event-and-download \(tetherWindow)",
                doneMarkers: ["gphoto2:", "*** Error"],
                timeout: 8,
                quiet: true
            )
            let files = CaptureOutput.savedFilenames(in: output)
            // Frames arriving means the photographer is shooting, so stay in the short, responsive
            // window for a while; going quiet relaxes it again and hands the body back.
            if !files.isEmpty { lastFrameAt = Date() }
            for name in files { importDownloaded(name) }
            let elapsed = Date().timeIntervalSince(start)
            // Log only when something happened or the poll ran long (so a quiet session stays quiet,
            // but a misbehaving/blocking wait-event is immediately visible).
            if !files.isEmpty {
                log("tether: downloaded \(files.count) camera-shutter frame(s) in \(String(format: "%.1f", elapsed))s")
            } else if elapsed > Double(4) {
                log("tether: wait-event ran \(String(format: "%.1f", elapsed))s with no frames")
            }
        } catch {
            // sendCommand tore down the shell on timeout/disconnect; reconnect and carry on.
            log("tether watch: poll failed (\(error.localizedDescription)) — reconnecting")
            try? await ensureConnected()
        }
    }

    /// Moves a freshly downloaded camera file (e.g. "capt0000.cr2") out of the shell's cwd to a
    /// stable, sortable, collision-free name and notifies listeners via `captureStream`.
    @discardableResult
    /// Copies a capture to every backup drive, off the capture path.
    ///
    /// Detached on purpose. The copies are blocking file IO onto drives that may be slow, sleeping
    /// or absent, and this runs inside the session actor, which the tether watch and every camera
    /// command also need — waiting on a USB drive here would stall the next frame. The shot is
    /// already safe in the project folder by the time this starts, so the backup is allowed to take
    /// its time and to fail without touching the shoot.
    private func mirrorToBackups(_ file: URL) {
        let destinations = BackupSettings.load()
        guard !destinations.isEmpty else { return }
        let project = captureDirectory
        Task.detached(priority: .utility) { [weak self] in
            let outcomes = await CaptureBackup.mirror(file, inProjectAt: project, to: destinations)
            await self?.reportBackup(outcomes, for: file)
        }
    }

    /// Logs every result and surfaces only what the photographer has to act on.
    private func reportBackup(_ outcomes: [CaptureBackup.Outcome], for file: URL) {
        for outcome in outcomes {
            switch outcome.result {
            case .copied(let bytes):
                log("backup: \(file.lastPathComponent) -> \(outcome.destination.label) (\(bytes) bytes)")
            case .skipped(let reason):
                log("backup: \(outcome.destination.label) skipped — \(reason == .notMounted ? "not mounted" : "already there")")
            case .failed(let message):
                log("backup: \(outcome.destination.label) FAILED — \(message)")
            }
        }
        // Only once per run of trouble: a drive that is unplugged is unplugged for every frame, and
        // repeating the same warning on every shot buries the status pill in noise.
        if let warning = CaptureBackup.warning(for: outcomes) {
            if warning != lastBackupWarning {
                lastBackupWarning = warning
                status(warning)
            }
        } else {
            lastBackupWarning = nil
        }
    }

    /// The last warning shown, so a drive that stays unplugged doesn't re-warn per frame.
    private var lastBackupWarning: String?

    private func importDownloaded(_ downloadedName: String) -> URL? {
        // A live-view frame must never enter the gallery. This is reachable on an ordinary path:
        // pressing the shutter during live view cancels a `capture-preview` mid-flight, so the
        // camera's "Saving file as capture_preview.jpg" reply lands in the *next* command's
        // buffer, and the tether watch would then import a low-resolution preview as if it were
        // the shot — in front of a client. Deleted rather than merely skipped, since the cancelled
        // tick's own cleanup never ran.
        guard !downloadedName.hasPrefix(Self.previewFilenamePrefix) else {
            log("ignoring stray live-view frame \(downloadedName)")
            try? FileManager.default.removeItem(at: Self.stagingDirectory.appendingPathComponent(downloadedName))
            return nil
        }
        // Source is the staging folder gphoto2 downloads into; destination is whichever project is
        // current at this instant — which is what makes switching projects free.
        let downloadedURL = Self.stagingDirectory.appendingPathComponent(downloadedName)
        guard FileManager.default.fileExists(atPath: downloadedURL.path) else { return nil }
        // While a focus bracket is running every frame belongs to that bracket, so they land in the
        // bracket's own subfolder instead of the project root. That includes a frame fired from the
        // body's own shutter mid-bracket — grouping it with the bracket is the right call, since a
        // shot taken at one of the bracket's focus positions is part of that stack.
        let destinationDirectory = stackGroupDirectory ?? captureDirectory
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let stamp = DateFormatter.captureFilenameFormatter.string(from: Date())
        var finalURL = destinationDirectory.appendingPathComponent(stamp + "." + downloadedURL.pathExtension)
        // A burst can land two frames within the same one-second stamp — disambiguate. A focus
        // bracket does this constantly: it can fire several frames inside one second.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = destinationDirectory.appendingPathComponent(
                stamp + "-" + UUID().uuidString.prefix(4) + "." + downloadedURL.pathExtension)
        }
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: finalURL)
        } catch {
            // The shot is safe in staging — say so rather than letting it look like the frame was
            // lost. This is where an unwritable capture folder (unplugged drive, permissions) now
            // surfaces, since the connection no longer depends on that folder being reachable.
            log("couldn't move \(downloadedName) into \(destinationDirectory.path): \(error.localizedDescription)")
            status("Can't write to the capture folder — the shot is held; choose another folder in Preferences")
            return nil
        }
        log("downloaded \(finalURL.lastPathComponent)")
        mirrorToBackups(finalURL)
        // Bracket frames are deliberately not published to the gallery: the merged TIFF is what the
        // photographer reviews, and it is registered separately once the merge finishes. They are
        // still returned to the caller, which is how the bracket collects its own frames.
        if stackGroupDirectory == nil { captureContinuation?.yield(finalURL) }
        return finalURL
    }

    // MARK: - Live view

    /// Filenames gphoto2 gives preview frames. They land in the shell's cwd (the staging folder)
    /// because the interactive shell ignores `--filename`, so they're deleted the moment they're
    /// read — and filtered out of the gallery listing besides, in case a crash strands one.
    static let previewFilenamePrefix = "capture_preview"

    /// Target seconds per live-view frame (~8 fps). Deliberately well below what the link can
    /// sustain — see the pacing note in `startLiveView`.
    private static let liveViewFrameInterval: TimeInterval = 0.125
    /// Consecutive preview errors before live view gives up. The body reports an unspecified
    /// error for a few frames before its session dies outright, so stopping early is the
    /// difference between a dropped feed and a dropped camera connection.
    private static let liveViewErrorLimit = 3

    private var liveViewContinuation: AsyncStream<Data>.Continuation?
    private var liveViewTask: Task<Void, Never>?

    /// JPEG frames from the camera's live view, as fast as the link round-trips them. Empty while
    /// live view is off.
    ///
    /// `bufferingNewest(1)` is essential, not a tuning detail: with the default unbounded buffer,
    /// frames arriving faster than the UI can decode them queue up forever and the picture falls
    /// progressively further behind reality — the feed stays smooth while becoming unusably
    /// laggy, which is exactly what was observed at ~18 fps. For a live feed a stale frame has no
    /// value at all; only the newest one does, so older frames are dropped rather than shown late.
    nonisolated func liveViewStream() -> AsyncStream<Data> {
        AsyncStream(Data.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.setLiveViewContinuation(continuation) }
        }
    }

    private func setLiveViewContinuation(_ continuation: AsyncStream<Data>.Continuation) {
        liveViewContinuation = continuation
    }

    /// Begins pulling preview frames. Deliberately leaves the tether watch running: frames and
    /// camera-shutter downloads interleave over the one shell (the command lock serializes them),
    /// which costs frame rate but means a shot fired while composing is still captured.
    /// Emits false when live view stops of its own accord (the camera stopped supplying frames),
    /// so the UI doesn't sit showing a frozen frame under a lit "live" button — and so the
    /// settings poll drops back to its idle cadence.
    nonisolated func liveViewActiveStream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { await self.setLiveViewActiveContinuation(continuation) }
        }
    }

    private func setLiveViewActiveContinuation(_ continuation: AsyncStream<Bool>.Continuation) {
        liveViewActiveContinuation = continuation
    }

    private var liveViewActiveContinuation: AsyncStream<Bool>.Continuation?

    static let cancelAutofocusPath = "/main/actions/cancelautofocus"
    static let viewfinderPath = "/main/actions/viewfinder"
    static let uiLockPath = "/main/actions/uilock"

    /// Takes the camera out of live view and gives its own controls back.
    ///
    /// Stopping our preview loop is not the same as ending live view. The body stays in live-view
    /// mode — mirror up, optical viewfinder blacked out — and libgphoto2's Canon driver engages the
    /// camera's **UI lock** when it enters live view, so the buttons are dead too. Neither is undone
    /// by cancelling a loop on this side, which is why the camera kept feeling "partially held"
    /// after quitting live view.
    ///
    /// Order matters: leave live view first, then unlock, then clear any release state.
    func releaseCameraToPhotographer() async {
        await withCommandLock {
            _ = try? await sendCommandLocked("set-config \(Self.viewfinderPath)=0",
                                             doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                                             timeout: 10, quiet: true)
            _ = try? await sendCommandLocked("set-config \(Self.uiLockPath)=0",
                                             doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                                             timeout: 10, quiet: true)
            await cancelAutofocusLocked()
        }
        log("camera handed back: live view off, UI unlocked, autofocus cancelled")
    }

    /// Focuses the camera with a **shutter half-press**, then lets go.
    ///
    /// Not `autofocusdrive`. That action engages autofocus and *holds* it — there is a matching
    /// `cancelautofocus` for a reason — and firing it without the cancel left the camera driving AF
    /// indefinitely: unresponsive to the app and to its own controls until the session was killed.
    /// A half-press is the same thing a photographer does, and `Release Half` unambiguously ends it.
    func autofocusNow() async throws {
        let choices = try await releaseChoices()
        func choice(_ needle: String) -> String? {
            choices.first { $0.lowercased() == needle } ?? choices.first { $0.lowercased().contains(needle) }
        }
        guard let pressHalf = choice("press half af") ?? choice("press half"),
              let releaseHalf = choice("release half") ?? choice("release") else {
            throw GPhotoError.commandFailed("This camera doesn't offer a half-press to focus with.")
        }

        try await withCommandLock {
            _ = try? await sendCommandLocked("set-config \(Self.remoteReleasePath)=\(pressHalf)",
                                             doneMarkers: ["gphoto2:", "*** Error", "ERROR"], timeout: 20)
            // Long enough for the lens to hunt and settle.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            _ = try? await sendCommandLocked("set-config \(Self.remoteReleasePath)=\(releaseHalf)",
                                             doneMarkers: ["gphoto2:", "*** Error", "ERROR"], timeout: 20)
            // Belt and braces: whatever happened above, leave no autofocus running behind us.
            await cancelAutofocusLocked()
        }
        log("autofocus: half-press complete")
    }

    /// Cancels any autofocus the camera may still be driving. Cheap, and safe to call at any time.
    func cancelAutofocusLocked() async {
        _ = try? await sendCommandLocked("set-config \(Self.cancelAutofocusPath)=1",
                                         doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                                         timeout: 10, quiet: true)
    }

    /// Releases anything the app may be holding on the camera: a part-pressed shutter, a running
    /// autofocus. Called when the focus-stacking session ends, so closing the panel always hands
    /// the camera back in a usable state.
    func releaseCameraControls() async {
        let choices = (try? await releaseChoices()) ?? []
        await withCommandLock {
            if let none = choices.first(where: { $0.lowercased() == "none" }) {
                _ = try? await sendCommandLocked("set-config \(Self.remoteReleasePath)=\(none)",
                                                 doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                                                 timeout: 10, quiet: true)
            }
            await cancelAutofocusLocked()
        }
        await releaseCameraToPhotographer()
    }

    /// The body's `eosremoterelease` choice list, cached.
    private func releaseChoices() async throws -> [String] {
        if let cached = cachedReleaseChoices { return cached }
        let output = try await getConfig(Self.remoteReleasePath)
        let choices = CameraSetting.parse(from: output, path: Self.remoteReleasePath)?.choices ?? []
        cachedReleaseChoices = choices
        return choices
    }

    private var cachedReleaseChoices: [String]?

    /// `releaseChoices` for callers already holding the command lock.
    private func releaseChoicesLocked() async throws -> [String] {
        if let cached = cachedReleaseChoices { return cached }
        let output = try await sendCommandLocked("get-config \(Self.remoteReleasePath)",
                                                 doneMarkers: ["END", "*** Error", "ERROR"], timeout: 15)
        let choices = CameraSetting.parse(from: output, path: Self.remoteReleasePath)?.choices ?? []
        cachedReleaseChoices = choices
        return choices
    }

    /// Whether the preview loop is actually running right now.    /// Whether the preview loop is actually running right now.
    ///
    /// The app's own `isLiveViewOn` is a *request*, not a fact: the loop stops itself when the
    /// camera refuses frames, and the session stops it around a bracket. Anything that needs to
    /// know whether a feed truly exists has to ask here.
    var liveViewIsRunning: Bool { liveViewTask != nil }

    func startLiveView() {
        guard liveViewTask == nil else { return }
        // Reset both counters: without this the error count survives an auto-stop, so the next
        // start dies on its first imperfect frame and live view is effectively unusable for the
        // rest of the session.
        liveViewErrors = 0
        disconnectedTicks = 0
        log("live view: starting")
        liveViewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                let delivered = await self.liveViewTick()
                if !delivered {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                // Pace the feed rather than pulling flat out. Measured live, an unthrottled loop
                // ran ~18 fps and the body gave up after ~2,500 frames: `capture-preview` started
                // returning "Unspecified error" and the whole PTP/IP session collapsed seconds
                // later. It also starved everything else — ordinary settings reads were waiting
                // 3s for the shell. Composing doesn't need 18 fps, and a session that survives is
                // worth far more than a smoother feed.
                let elapsed = Date().timeIntervalSince(started)
                let remaining = Self.liveViewFrameInterval - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }
    }

    func stopLiveView() {
        guard let task = liveViewTask else { return }
        task.cancel()
        liveViewTask = nil
        liveViewPauseDepth = 0
        log("live view: stopped")
        liveViewActiveContinuation?.yield(false)
        // Sweep *after* the cancelled tick has finished. Cancelling doesn't stop a frame already
        // in flight, so sweeping immediately runs before gphoto2 writes the file and leaves one
        // behind on every stop — which the shutter does on every shot taken from live view.
        Task { [weak self] in
            _ = await task.value
            guard let self else { return }
            await self.cleanUpPreviewFiles()
            // Cancelling the loop only stops *us* asking for frames. The camera is still in live
            // view with its UI locked until it is told otherwise.
            await self.releaseCameraToPhotographer()
        }
    }

    /// Pulls one preview frame. Returns false if nothing was delivered, so the caller can back off
    /// instead of spinning against a camera that isn't producing frames.
    private func liveViewTick() async -> Bool {
        guard liveViewPauseDepth == 0 else { return false }
        guard isConnected, let process, process.isRunning else {
            // Don't spin at 2 Hz forever against a camera that's gone: give a reconnect a fair
            // window, then stop and say so rather than leaving a dead feed lit up.
            disconnectedTicks += 1
            if disconnectedTicks >= Self.liveViewDisconnectLimit {
                log("live view: stopping — camera link down")
                status("Live view stopped — camera disconnected")
                stopLiveView()
            }
            return false
        }
        disconnectedTicks = 0
        let started = Date()
        do {
            let output = try await sendCommand(
                "capture-preview",
                doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                timeout: 10,
                quiet: true
            )
            guard let name = CaptureOutput.savedFilenames(in: output).last else {
                // No frame. Log the raw response the first time so an unexpected output shape (a
                // different "saved as" wording, or the body refusing live view in its current
                // mode) is diagnosable from the log rather than silently showing nothing.
                if !loggedEmptyPreview {
                    loggedEmptyPreview = true
                    log("live view: no frame parsed from response: \(output.debugDescription)")
                }
                liveViewErrors += 1
                if liveViewErrors >= Self.liveViewErrorLimit {
                    // Bail out rather than keep asking. Observed live: the body returns
                    // "Unspecified error" for a few frames and then drops the entire PTP/IP
                    // session — losing the feed is recoverable, losing the camera link means
                    // re-pairing from the camera's own screen.
                    log("live view: stopping after \(liveViewErrors) consecutive errors")
                    status("Live view stopped — the camera stopped providing frames")
                    stopLiveView()
                }
                return false
            }
            liveViewErrors = 0
            let url = Self.stagingDirectory.appendingPathComponent(name)
            // Always remove it: a preview frame is not a capture, and leaving it behind makes the
            // next frame hit gphoto2's overwrite prompt. Staging keeps it out of the photographer's
            // folder in the first place.
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
            liveViewFrameCount += 1
            // One line per second of streaming, not per frame — enough to measure the rate the
            // link actually sustains without flooding the log.
            if liveViewFrameCount % 30 == 0 {
                log("live view: \(liveViewFrameCount) frames, last took \(Int(Date().timeIntervalSince(started) * 1000))ms")
            }
            liveViewContinuation?.yield(data)
            return true
        } catch {
            // gphoto2 may already have written the frame before the command failed (a timeout,
            // or the link dropping mid-frame), and the delete below only gets installed once a
            // filename is parsed — so sweep, or every such failure strands a file.
            log("live view: frame failed (\(error.localizedDescription))")
            cleanUpPreviewFiles()
            return false
        }
    }

    private var liveViewFrameCount = 0
    private var liveViewErrors = 0
    private var disconnectedTicks = 0
    /// Consecutive ticks with the link down before live view gives up (~15s at the 500ms
    /// disconnected retry).
    private static let liveViewDisconnectLimit = 30
    /// Nesting depth of `withLiveViewPaused`. A counter rather than a flag: overlapping pauses are
    /// reachable (the busy watchdog releases the UI gate without cancelling the work behind it, so
    /// a second settings change can start while the first is still applying), and with a plain
    /// Bool the inner one's cleanup would resume the frame loop while the outer command was still
    /// in flight — reinstating the very interference the pause exists to prevent.
    private var liveViewPauseDepth = 0

    /// Runs `operation` with the live view frame loop held off. A body streaming preview frames
    /// doesn't reliably apply exposure changes sent in the gaps between them — the command goes
    /// out and nothing happens — so settings changes get a quiet shell instead of competing with
    /// a frame every 125ms. The feed resumes by itself afterwards.
    private func withLiveViewPaused<T>(_ operation: () async throws -> T) async rethrows -> T {
        guard liveViewTask != nil else { return try await operation() }
        liveViewPauseDepth += 1
        defer { liveViewPauseDepth = max(0, liveViewPauseDepth - 1) }
        return try await operation()
    }
    private var loggedEmptyPreview = false

    /// Sweeps any preview frames stranded in the capture folder (a crash mid-stream), so they can't
    /// turn up in the gallery as if they were shots.
    private func cleanUpPreviewFiles() {
        // Sweeps staging, where previews now land. The capture folder is swept too, for frames
        // stranded there by a build that predates staging.
        for directory in [Self.stagingDirectory, captureDirectory] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix(Self.previewFilenamePrefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// The camera properties the settings panel exposes, in display order. gphoto2 reports the
    /// aperture/shutter/whitebalance choices the camera actually offers in its current shooting
    /// mode, so read-only or unavailable ones surface gracefully via `CameraSetting.readOnly`.
    private static let settingPaths = [
        "/main/imgsettings/iso",
        "/main/capturesettings/shutterspeed",
        "/main/capturesettings/aperture",
        "/main/imgsettings/whitebalance",
        "/main/imgsettings/imageformat"
    ]

    /// Runs a camera operation and, if it fails because the PTP/IP link dropped (the 1DX II resets
    /// the connection after ~90s idle — "Connection reset by peer"), tears down the dead shell,
    /// reconnects, and retries once. Reconnect reuses `ensureConnected`, so it transparently waits
    /// out any on-camera re-confirmation instead of surfacing a hard error to the user.
    private func withReconnect<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureConnected()
        do {
            return try await operation()
        } catch {
            guard isDisconnectError(error) else { throw error }
            log("link dropped — reconnecting and retrying")
            status("Reconnecting…")
            closeShell()
            try await ensureConnected()
            return try await operation()
        }
    }

    /// Distinguishes a dropped/desynced session (worth an automatic reconnect) from a genuine
    /// command error like an invalid config value, which should surface to the user unchanged.
    private func isDisconnectError(_ error: Error) -> Bool {
        guard case let GPhotoError.commandFailed(message) = error else {
            return true // e.g. noCameraDetected — the session is already gone
        }
        let markers = ["Connection reset", "session closed", "Timed out waiting",
                       "I/O problem", "Connection refused", "Broken pipe"]
        return markers.contains { message.contains($0) }
    }

    /// Reads a camera config value (e.g. "/main/imgsettings/imageformat"). Returns the raw
    /// `get-config` output, which includes the current value and, for enum-type properties,
    /// the list of valid choices. Waits for the trailing `END` marker so the choice list — which
    /// gphoto2 prints *after* the `Current:` line — is fully captured.
    func getConfig(_ name: String) async throws -> String {
        try await withReconnect { try await self.getConfigOnce(name) }
    }

    private func getConfigOnce(_ name: String) async throws -> String {
        try await sendCommand(
            "get-config \(name)",
            doneMarkers: ["END", "*** Error", "ERROR"],
            timeout: 15
        )
    }

    /// The exposure triangle — the settings a photographer actually turns while judging a live
    /// view, and so the ones worth re-reading often. Kept separate from the full list because
    /// polling all five during live view costs frames for values (white balance, image format)
    /// that essentially never change mid-composition.
    static let exposurePaths = [
        "/main/imgsettings/iso",
        "/main/capturesettings/shutterspeed",
        "/main/capturesettings/aperture"
    ]

    /// Reads camera settings over the open shell session — all of them, or just `paths`.
    func fetchSettings(paths: [String]? = nil) async throws -> [CameraSetting] {
        let targets = paths ?? Self.settingPaths
        return try await withReconnect { try await self.fetchSettingsOnce(targets) }
    }

    private func fetchSettingsOnce(_ paths: [String]) async throws -> [CameraSetting] {
        // One lock for the whole read — see `withCommandLock`. Reading each property under its own
        // acquisition made the inspector lag the camera's dials by seconds.
        try await withCommandLock {
            var results: [CameraSetting] = []
            for path in paths {
                // Quiet: this runs every 1.5s and each response carries the camera's entire list of
                // valid values. Logging it grew the file ~2.3 MB/hour, so it rotated every couple
                // of hours and took the connect/discovery lines — the only ones that ever diagnose
                // anything — with it. Twice today that destroyed the history mid-investigation.
                let output = try await sendCommandLocked(
                    "get-config \(path)",
                    doneMarkers: ["END", "*** Error", "ERROR"],
                    timeout: 15,
                    quiet: true
                )
                // A property the camera doesn't expose in its current mode yields no `Current:`
                // line (parse returns nil); skip it rather than failing the whole fetch.
                if let setting = CameraSetting.parse(from: output, path: path) {
                    results.append(setting)
                }
            }
            return results
        }
    }

    /// Applies a new value to a single setting, then re-reads it so the caller gets the camera's
    /// authoritative post-change state (the camera may snap the value to its nearest valid step).
    func updateSetting(_ path: String, to value: String) async throws -> CameraSetting? {
        try await withLiveViewPaused {
            try await withReconnect {
                try await self.setConfigOnce(path, value)
                let output = try await self.sendCommand(
                    "get-config \(path)",
                    doneMarkers: ["END", "*** Error", "ERROR"],
                    timeout: 15
                )
                return CameraSetting.parse(from: output, path: path)
            }
        }
    }

    func setConfig(_ name: String, _ value: String) async throws {
        try await withReconnect { try await self.setConfigOnce(name, value) }
    }

    private func setConfigOnce(_ name: String, _ value: String) async throws {
        let output = try await sendCommand(
            "set-config \(name)=\(value)",
            doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
            timeout: 15
        )
        if output.contains("*** Error") || output.contains("ERROR") {
            throw GPhotoError.commandFailed(output)
        }
    }

    /// Triggers a capture from the app shutter. The resulting frame is downloaded by the tether
    /// watch loop and delivered via `captureStream`, so the app shutter and the camera's own
    /// shutter follow the exact same download path — no duplicate, no divergence.
    func capture() async throws {
        _ = try await withReconnect { try await self.triggerCaptureOnce() }
    }

    /// Same shot, but the resulting files come back to the caller as well as going out on
    /// `captureStream`. Focus stacking needs to know *which* frames are its own — a bracket that
    /// merely watched the capture stream would also scoop up a shot fired from the body's shutter
    /// mid-bracket, and merge a frame that belongs to a different picture.
    @discardableResult
    func captureReturningURLs() async throws -> [URL] {
        try await withReconnect { try await self.triggerCaptureOnce() }
    }

    @discardableResult
    private func triggerCaptureOnce() async throws -> [URL] {
        // An app-triggered shot means shooting is under way: tighten the listening window so the
        // frames around it come through promptly.
        lastFrameAt = Date()
        for attempt in 1...3 {
            // `capture-image-and-download` is the command proven working on this body; route its
            // result through the shared import path so it lands via `captureStream` exactly like a
            // camera-shutter frame the watcher downloads. Completion is the shell prompt returning
            // (like the tether poll), NOT the first "Saving file as" — with the body set to
            // RAW+JPEG the second file's save line arrives after the first, and returning early
            // let the next command's buffer clear() destroy it, stranding the file under its
            // camera-side name outside the gallery.
            let output = try await sendCommand(
                "capture-image-and-download --force-overwrite",
                doneMarkers: ["gphoto2:", "ERROR", "*** Error"],
                timeout: 60
            )
            let names = CaptureOutput.savedFilenames(in: output)
            if !names.isEmpty {
                return names.compactMap { importDownloaded($0) }
            }
            // The camera is momentarily busy finishing another frame (often right after a physical-
            // shutter shot): "-110 I/O in progress" / "Could not capture". Back off and retry.
            if output.contains("I/O in progress") || output.contains("Could not capture") {
                log("camera busy (attempt \(attempt)/3) — retrying shortly")
                status("Camera busy — retrying…")
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            throw GPhotoError.commandFailed(output)
        }
        throw GPhotoError.commandFailed("Camera stayed busy; the shot wasn't taken. Try again.")
    }

    // MARK: - Focus stacking

    /// Canon's vendor action for nudging the focus motor. There is no absolute-position property to
    /// go with it: this is the only focus control PTP gives us on this body.
    static let focusDrivePath = "/main/actions/manualfocusdrive"

    /// While non-nil, downloaded frames land here instead of the project root and are not published
    /// to the gallery — see `importDownloaded`. Set only for the duration of a focus bracket.
    private var stackGroupDirectory: URL?

    /// Cached capability. Only a definite answer is cached — an `.unknown` probe (busy camera,
    /// dropped link) is deliberately *not* remembered, or one unlucky moment would disable focus
    /// stacking for the rest of the session.
    private var cachedFocusDrive: FocusDriveCapability?

    /// Asks the body whether it can drive focus, through the session's existing shell. Nothing new
    /// is opened and no probe touches the network — the pairing footgun documented in CLAUDE.md is
    /// about opening and closing TCP connections, and this is an ordinary command on the shell that
    /// is already up.
    func focusDriveCapability(forceRefresh: Bool = false) async -> FocusDriveCapability {
        if !forceRefresh, let cached = cachedFocusDrive { return cached }
        let result: FocusDriveCapability
        do {
            let output = try await getConfig(Self.focusDrivePath)
            if output.contains("*** Error") || output.contains("not found") {
                result = .unsupported
            } else if let setting = CameraSetting.parse(from: output, path: Self.focusDrivePath) {
                if !FocusStep.isDrivable(choices: setting.choices) {
                    result = .presentButNotDrivable
                } else if let focusMode = try? await focusModeSetting(),
                          focusMode.readOnly, focusMode.current.lowercased().contains("manual") {
                    // Read-only *and* manual means the switch on the barrel is on MF: the body
                    // can't drive the motor and can't change its own mode either. The body merely
                    // *being* in manual focus is not a problem — it's the state stacking needs.
                    result = .lensSwitchInManualFocus(lens: try? await lensName())
                } else {
                    result = .available(choices: setting.choices)
                }
            } else {
                // Parsed nothing usable — the property is listed but unavailable in this mode.
                result = .presentButNotDrivable
            }
        } catch {
            result = .unknown(reason: error.localizedDescription)
        }
        log("focus drive capability: \(result)")
        await logConfigList()
        if case .unknown = result {} else { cachedFocusDrive = result }
        return result
    }

    /// Canon's live-view magnification. Judging focus on a fit-to-window preview is guesswork —
    /// this is the same 5×/10× the body offers on its own screen, and it is what makes marking the
    /// ends of a range accurate rather than approximate.
    static let zoomPath = "/main/actions/eoszoom"

    /// Magnifications the body accepts. 1 is fit-to-frame; 5 and 10 are the punch-ins.
    static let zoomFactors = [1, 5, 10]

    func setLiveViewZoom(_ factor: Int) async throws {
        try await setConfig(Self.zoomPath, String(factor))
        log("live view zoom: \(factor)x")
    }

    static let focusModePath = "/main/capturesettings/focusmode"
    static let lensNamePath = "/main/status/lensname"

    private func focusModeSetting() async throws -> CameraSetting? {
        let output = try await getConfig(Self.focusModePath)
        let setting = CameraSetting.parse(from: output, path: Self.focusModePath)
        if let setting {
            log("focus mode: \(setting.current) (readonly: \(setting.readOnly), choices: \(setting.choices))")
        }
        return setting
    }

    /// Nesting depth of `withManualFocus`, and the mode to put back when it unwinds.
    private var manualFocusDepth = 0
    private var focusModeToRestore: String?

    /// Runs `body` with the **body** in manual focus, restoring the previous mode afterwards.
    ///
    /// This is the single most important thing in focus stacking on this camera, and it fixes two
    /// failures that look unrelated:
    ///
    /// - `manualfocusdrive` is *accepted and acknowledged* while the body is in an AF mode, and the
    ///   lens does not move. Only in manual focus does the command actually drive the motor. This is
    ///   what EOS Utility does for its own near/far focus buttons.
    /// - In an AF mode every `capture-image-and-download` autofocuses first. That fails outright
    ///   when focus has been deliberately racked off the subject ("Canon EOS Auto-Focus failed,
    ///   could not capture"), and when it *succeeds* it is worse: it refocuses, silently destroying
    ///   the position the bracket just stepped to.
    ///
    /// Restoring matters as much as setting: leaving the body in manual after a bracket would break
    /// ordinary shooting with no clue as to why.
    func withManualFocus<T>(_ body: () async throws -> T) async throws -> T {
        if manualFocusDepth == 0 {
            if let setting = try? await focusModeSetting(),
               !setting.readOnly,
               !setting.current.lowercased().contains("manual"),
               let manual = setting.choices.first(where: { $0.lowercased().contains("manual") }) {
                focusModeToRestore = setting.current
                try? await setConfig(Self.focusModePath, manual)
                log("focus mode: switched to \(manual) for focus stacking (was \(setting.current))")
            } else {
                focusModeToRestore = nil
            }
        }
        manualFocusDepth += 1
        defer {
            manualFocusDepth -= 1
            if manualFocusDepth == 0, let restore = focusModeToRestore {
                focusModeToRestore = nil
                // Detached from the caller's cancellation: a cancelled bracket must still put the
                // camera back the way it was found.
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.setConfig(Self.focusModePath, restore)
                    await self.log("focus mode: restored to \(restore)")
                }
            }
        }
        return try await body()
    }

    private func lensName() async throws -> String? {
        let output = try await getConfig(Self.lensNamePath)
        let name = CameraSetting.parse(from: output, path: Self.lensNamePath)?.current
        if let name { log("lens: \(name)") }
        return name?.isEmpty == false ? name : nil
    }

    static let imageFormatPath = "/main/imgsettings/imageformat"

    /// Format the app switched away from and has not yet confirmed putting back. Survives quitting,
    /// so an unfinished restore is picked up on the next connection instead of being lost with the
    /// process that owed it.
    static let pendingFormatRestoreKey = "pendingImageFormatRestore"

    /// Finishes any restore a previous bracket (or a previous *run* of the app) left owing.
    ///
    /// Called on connect. Only acts when the camera is genuinely still on the format the app
    /// switched it to — if the photographer has since set something themselves, that is their
    /// choice and their setting wins.
    func restorePendingImageFormat() async {
        guard let owed = UserDefaults.standard.string(forKey: Self.pendingFormatRestoreKey) else { return }
        guard let setting = try? await imageFormatSetting() else { return }
        guard setting.current != owed else {
            UserDefaults.standard.removeObject(forKey: Self.pendingFormatRestoreKey)
            return
        }
        guard Self.jpegChoice(in: setting.choices) == setting.current else {
            // Not on the JPEG setting we left it on — the photographer has changed it since.
            log("image format: dropping owed restore to \(owed); camera is on \(setting.current)")
            UserDefaults.standard.removeObject(forKey: Self.pendingFormatRestoreKey)
            return
        }
        log("image format: finishing an unfinished restore to \(owed)")
        await restoreImageFormat(owed)
    }

    /// Nesting depth and the format to put back, mirroring `withManualFocus`.
    private var imageFormatDepth = 0
    private var imageFormatToRestore: String?

    /// Runs `body` with the camera shooting JPEG, restoring the previous format afterwards.
    ///
    /// Worth it for brackets specifically: a stack is a dozen-plus frames, the RAW download is about
    /// two seconds of the ~3 s cycle, and the merge is clamped to sRGB by ImageIO's decode anyway —
    /// so RAW costs real time per frame and buys the merged result almost nothing. Single shots are
    /// untouched; this is scoped to the bracket.
    ///
    /// Choice matching has to be defensive. libgphoto2 only partly decodes this body's format list:
    /// `["L", "0xff", "RAW", "RAW + 0x50", "RAW + 0x60", "RAW + 0x20", "mRAW", …]`, where `L` is
    /// Large JPEG and several entries are raw hex codes it has no name for. So: take a known-good
    /// JPEG spelling if one is offered, else the plain `L`, and never guess at a hex code.
    func withJPEGCapture<T>(_ body: () async throws -> T) async throws -> T {
        if imageFormatDepth == 0 {
            if let setting = try? await imageFormatSetting(),
               !setting.readOnly,
               let jpeg = Self.jpegChoice(in: setting.choices),
               setting.current != jpeg {
                imageFormatToRestore = setting.current
                // Persisted before the switch, not just held in memory. A restore can fail (the
                // body answers PTP Device Busy while writing the last frame), the app can be quit,
                // the link can drop — and any of those silently leaves the photographer's camera on
                // JPEG. It happened: a bracket switched RAW → L, the restore failed, and every
                // capture for the next two hours was a JPEG with nothing to say so.
                UserDefaults.standard.set(setting.current, forKey: Self.pendingFormatRestoreKey)
                try? await setConfig(Self.imageFormatPath, jpeg)
                log("image format: switched to \(jpeg) for the bracket (was \(setting.current))")
            } else {
                imageFormatToRestore = nil
            }
        }
        imageFormatDepth += 1
        defer {
            imageFormatDepth -= 1
            if imageFormatDepth == 0, let restore = imageFormatToRestore {
                imageFormatToRestore = nil
                // Detached so a cancelled or failed bracket still puts the camera back: leaving a
                // photographer's body silently on JPEG after a stack would be a genuinely costly
                // surprise on the next real shot.
                Task { [weak self] in
                    guard let self else { return }
                    await self.restoreImageFormat(restore)
                }
            }
        }
        return try await body()
    }

    /// Puts the image format back, retrying on a busy camera.
    ///
    /// Observed failing for real: immediately after a bracket the body answers
    /// `0x2019 PTP Device Busy` — it is still writing the last frame — and a single best-effort
    /// attempt silently gave up, **leaving the photographer's camera on JPEG**. That is the exact
    /// expensive surprise this restore exists to prevent, so it retries, verifies, and says so
    /// loudly in the status bar if it still can't.
    private func restoreImageFormat(_ format: String) async {
        for attempt in 1...5 {
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            do {
                try await setConfig(Self.imageFormatPath, format)
                // Trust the read-back, not the write: the failing case returned an error *and* the
                // camera kept its old value, so only a confirmed value proves anything.
                if let now = try? await imageFormatSetting(), now.current == format {
                    log("image format: restored to \(format)")
                    UserDefaults.standard.removeObject(forKey: Self.pendingFormatRestoreKey)
                    return
                }
            } catch {
                log("image format: restore attempt \(attempt) failed (\(error.localizedDescription))")
            }
        }
        log("image format: COULD NOT restore to \(format) — camera left on JPEG")
        status("Couldn't set the camera back to \(format) — it's still on JPEG. Change it on the body.")
    }

    /// The JPEG-only entry in a Canon image-format choice list, or nil if none is recognisable.
    static func jpegChoice(in choices: [String]) -> String? {
        func find(_ predicate: (String) -> Bool) -> String? { choices.first { predicate($0.lowercased()) } }
        // A named JPEG entry, on builds that decode them ("Large Fine JPEG").
        if let named = find({ $0.contains("jpeg") && !$0.contains("raw") }) { return named }
        // This body: a bare size letter means JPEG at that size. Large first.
        for size in ["l", "m", "s", "s1", "s2", "s3"] {
            if let exact = choices.first(where: { $0.lowercased() == size }) { return exact }
        }
        return nil
    }

    // MARK: - HDR bracket

    struct HDRBracketResult {
        let folder: URL
        let frames: [URL]
        /// Index of the metered frame, which the merge anchors to.
        let referenceIndex: Int
    }

    /// Rejects a shutter setting the exposure maths cannot work with, before anything is shot.
    ///
    /// **Bulb is the case that matters.** On Bulb the body reports a shutter of "bulb", which is not
    /// a duration, so every offset a bracket asks for resolves to nothing and the whole sequence
    /// ends before the first frame — with a message about the *scene* not needing a bracket, which
    /// is both wrong and unactionable. Observed exactly that: the button appeared to do nothing.
    private func requireTimedShutter(_ setting: CameraSetting) throws {
        guard ExposureGrid.stops(of: setting.current, path: ExposureGrid.shutterPath) == nil else { return }
        throw GPhotoError.needsCameraChange(
            "The camera's shutter is set to \(setting.current). Bracketing needs a timed shutter "
            + "speed — set one on the camera (take it off Bulb) and try again.")
    }

    // MARK: - Timelapse

    struct TimelapseFrame {
        let url: URL
        let exposure: Double        // relative, from EXIF
        let brightness: Double      // measured, linear
    }

    struct TimelapseResult {
        let folder: URL
        let frames: [TimelapseFrame]
    }

    /// Shoots a timelapse, holding exposure as the light changes.
    ///
    /// Exposure is ramped in the body's own 1/3-stop clicks and the steps are removed afterwards;
    /// see `ExposureRamp` for why that beats the bulb-timer approach on this camera. Each frame is
    /// metered as it lands, so the ramp follows the light rather than a clock.
    func captureTimelapse(intervalSeconds: Double,
                          frameCount: Int,
                          highestISO: Double,
                          status: @escaping @Sendable (String) -> Void) async throws -> TimelapseResult {
        try await withTetherPaused {
            try await withRAWCapture {
                try await captureTimelapseInner(intervalSeconds: intervalSeconds,
                                                frameCount: frameCount,
                                                highestISO: highestISO,
                                                status: status)
            }
        }
    }

    private func captureTimelapseInner(intervalSeconds: Double,
                                       frameCount: Int,
                                       highestISO: Double,
                                       status: @escaping @Sendable (String) -> Void) async throws -> TimelapseResult {
        let shutterOutput = try await getConfig(ExposureGrid.shutterPath)
        let isoOutput = try await getConfig(ExposureGrid.isoPath)
        guard let shutterSetting = CameraSetting.parse(from: shutterOutput, path: ExposureGrid.shutterPath),
              let isoSetting = CameraSetting.parse(from: isoOutput, path: ExposureGrid.isoPath),
              !shutterSetting.readOnly, !isoSetting.readOnly else {
            throw GPhotoError.commandFailed("The camera won't let shutter and ISO be set — take it off a fully automatic mode.")
        }
        try requireTimedShutter(shutterSetting)
        // The shutter may never outlast the interval; leave room for the download too.
        let ladder = ExposureLadder(shutterChoices: shutterSetting.choices,
                                    isoChoices: isoSetting.choices,
                                    longestShutter: Swift.max(intervalSeconds - 2, 0.5),
                                    highestISO: highestISO)
        var current = ExposureLadder.Settings(shutter: shutterSetting.current, iso: isoSetting.current)

        let folder = captureDirectory.appendingPathComponent(CaptureLocation.timelapseFolderName(for: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        stackGroupDirectory = folder
        defer { stackGroupDirectory = nil }

        let release = try await releaseValues()
        var ramp = ExposureRamp()
        var frames: [TimelapseFrame] = []
        var target: Double?
        let startedAt = Date()

        do {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                // Fire on the interval's grid rather than sleeping a fixed gap after each frame:
                // metering and downloading take a variable amount of time, and a fixed gap makes
                // the sequence drift and the motion in it uneven.
                let due = startedAt.addingTimeInterval(Double(index) * intervalSeconds)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

                status("Timelapse \(index + 1) of \(frameCount) — \(current.shutter), ISO \(current.iso)")
                try await withCommandLock { try await releaseShutterLocked(release) }
                let arrived = try await withCommandLock {
                    await drainDownloadsLocked(expected: 1,
                                               exposureSeconds: ExposureGrid.seconds(from: current.shutter) ?? 0)
                }
                guard let url = arrived.first else {
                    log("timelapse: frame \(index + 1) didn't arrive — carrying on")
                    continue
                }

                let measured = await Task.detached(priority: .userInitiated) {
                    (brightness: HDRRenderer.rampBrightness(of: url),
                     exposure: HDRRenderer.relativeExposure(of: url))
                }.value
                guard let brightness = measured.brightness, brightness > 0 else { continue }
                frames.append(TimelapseFrame(url: url,
                                             exposure: measured.exposure ?? 1,
                                             brightness: brightness))

                // The first usable frame sets what "correctly exposed" means for this sequence.
                // Anchoring to the photographer's own starting exposure beats any fixed target:
                // they framed and metered it, and the ramp's job is to keep that look, not to
                // impose one.
                if target == nil { target = brightness }
                guard let target else { continue }
                ramp.record(stopsFromTarget: log2(brightness / target))
                let adjustment = ramp.nextAdjustment()
                guard adjustment != 0 else { continue }
                guard let next = ladder.settings(from: current, changingBy: adjustment) else {
                    log("timelapse: out of exposure range — holding at \(current.shutter), ISO \(current.iso)")
                    status("Exposure range reached — holding")
                    continue
                }
                try await withCommandLock {
                    try await setConfigLocked(ExposureGrid.shutterPath, next.shutter)
                    _ = await confirmShutterLocked(next.shutter)
                    if next.iso != current.iso {
                        try await setConfigLocked(ExposureGrid.isoPath, next.iso)
                    }
                }
                log(String(format: "timelapse: frame %d — %+.2f stops -> %@ ISO %@",
                           index + 1, adjustment, next.shutter, next.iso))
                current = next
            }
        } catch {
            await restoreShutter(shutterSetting.current)
            try? await setConfig(ExposureGrid.isoPath, isoSetting.current)
            throw error
        }
        await restoreShutter(shutterSetting.current)
        try? await setConfig(ExposureGrid.isoPath, isoSetting.current)

        log("timelapse: \(frames.count) frames, \(ramp.adjustments) exposure changes")
        return TimelapseResult(folder: folder, frames: frames)
    }

    /// Shoots exposures until the scene is covered, deciding the count and spacing from what each
    /// frame actually records.
    ///
    /// A fixed ±2 or ±4 is a guess about a scene nobody has looked at: it wastes frames on an evenly
    /// lit subject and falls short of a window in a dark room. This shoots the metered exposure,
    /// measures what it lost at each end, and walks outward until nothing important is still
    /// clipping or still in the noise.
    func captureAutoHDRBracket(status: @escaping @Sendable (String) -> Void) async throws -> HDRBracketResult {
        try await withTetherPaused {
            try await withRAWCapture {
                try await captureAutoHDRBracketInner(status: status)
            }
        }
    }

    private func captureAutoHDRBracketInner(status: @escaping @Sendable (String) -> Void) async throws -> HDRBracketResult {
        let output = try await getConfig(ExposureGrid.shutterPath)
        guard let setting = CameraSetting.parse(from: output, path: ExposureGrid.shutterPath),
              !setting.readOnly else {
            throw GPhotoError.commandFailed("The camera won't let the shutter speed be set — take it off a fully automatic mode.")
        }
        try requireTimedShutter(setting)
        let metered = setting.current
        let folder = captureDirectory.appendingPathComponent(CaptureLocation.hdrFolderName(for: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        stackGroupDirectory = folder
        defer { stackGroupDirectory = nil }

        let release = try await releaseValues()
        var shot: [(offset: Int, coverage: HDRAutoBracket.Coverage)] = []
        var urlsByOffset: [Int: URL] = [:]
        var lastCoverage = HDRAutoBracket.Coverage(clipped: 0, crushed: 0)

        do {
            while let offset = HDRAutoBracket.next(after: shot) {
                try Task.checkCancellation()
                // Out of the body's range is a reason to stop, not to fail: the frames already in
                // hand are a real bracket, just a narrower one than the scene wanted.
                guard let speed = HDRPlan.shutter(stopsFrom: metered, stops: offset, in: setting.choices) else {
                    log("hdr auto: \(offset >= 0 ? "+" : "")\(offset) stops is past this body's shutter range — stopping")
                    status("Shutter range reached — bracketing with what fits")
                    break
                }
                status("HDR \(shot.count + 1) — \(speed) (\(offset >= 0 ? "+" : "")\(offset) stops)")
                try await withCommandLock {
                    try await setConfigLocked(ExposureGrid.shutterPath, speed)
                    guard await confirmShutterLocked(speed) else {
                        throw GPhotoError.commandFailed("The camera didn't take \(speed).")
                    }
                    try await releaseShutterLocked(release)
                }
                let seconds = ExposureGrid.seconds(from: speed) ?? 0
                let arrived = try await withCommandLock {
                    await drainDownloadsLocked(expected: 1, exposureSeconds: seconds)
                }
                guard let url = arrived.first else {
                    throw GPhotoError.commandFailed(
                        "The \(speed) exposure didn't arrive from the camera.")
                }
                urlsByOffset[offset] = url

                // Measured off the actor: it is a decode, and the session is what every other
                // camera command needs.
                let coverage = await Task.detached(priority: .userInitiated) {
                    HDRRenderer.coverage(of: url)
                }.value ?? HDRAutoBracket.Coverage(clipped: 0, crushed: 0)
                lastCoverage = coverage
                shot.append((offset, coverage))
                log(String(format: "hdr auto: %+d stops — clipped %.3f%%, crushed %.1f%%",
                           offset, coverage.clipped * 100, coverage.crushed * 100))
            }
        } catch {
            await restoreShutter(metered)
            throw error
        }
        await restoreShutter(metered)

        guard shot.count >= 2 else {
            // Distinguish "one exposure was enough" from "nothing was shot at all" — the second is
            // a setup problem and saying the scene was easy sends the photographer looking in the
            // wrong place entirely.
            throw GPhotoError.needsCameraChange(shot.isEmpty
                ? "No exposures were taken — the camera wouldn't accept the shutter speeds this bracket needs."
                : "This scene fits in a single exposure — no bracket was needed.")
        }
        let offsets = shot.map(\.offset).sorted()
        log("hdr auto: \(HDRAutoBracket.summary(offsets: offsets))")
        if let warning = HDRAutoBracket.warning(offsets: offsets, last: lastCoverage) {
            log("hdr auto: \(warning)")
            status(warning)
        }
        // Darkest first, and the metered frame is what the merge anchors to.
        let ordered = offsets.compactMap { urlsByOffset[$0] }
        let reference = offsets.firstIndex(of: 0) ?? offsets.count / 2
        return HDRBracketResult(folder: folder, frames: ordered, referenceIndex: reference)
    }

    /// Waits until the body reports the shutter speed actually asked for.
    ///
    /// Polls rather than sleeping a fixed time, because how long a change takes depends on how far
    /// it is: four stops is slower than two, and any constant is wrong for one of them.
    private func confirmShutterLocked(_ speed: String) async -> Bool {
        for attempt in 0..<Self.shutterConfirmAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: Self.shutterConfirmInterval)
            } else {
                // Give it one settle before the first read; asking immediately just wastes a
                // round trip on the common case.
                try? await Task.sleep(nanoseconds: Self.shutterConfirmInterval)
            }
            guard let output = try? await sendCommandLocked(
                    "get-config \(ExposureGrid.shutterPath)",
                    doneMarkers: ["END", "*** Error", "ERROR"],
                    timeout: 15, quiet: true),
                  let setting = CameraSetting.parse(from: output, path: ExposureGrid.shutterPath)
            else { continue }
            if setting.current == speed { return true }
        }
        log("hdr: shutter did not reach \(speed)")
        return false
    }

    /// Grace beyond the exposure itself, for the camera to write and hand the file over.
    static let downloadSlack: Double = 2.5

    static let shutterConfirmAttempts = 10
    static let shutterConfirmInterval: UInt64 = 200_000_000

    /// Puts the shutter back where the photographer left it.
    ///
    /// Retried and read back, for the reason `restoreImageFormat` is: the body answers PTP Device
    /// Busy while it is still writing the last frame, and a single best-effort attempt leaves the
    /// camera on the bracket's last speed — which on this body is two or four stops from what was
    /// metered, and the next shot is ruined with nothing to say why.
    private func restoreShutter(_ speed: String) async {
        for attempt in 1...5 {
            try? await setConfig(ExposureGrid.shutterPath, speed)
            if let output = try? await getConfig(ExposureGrid.shutterPath),
               let setting = CameraSetting.parse(from: output, path: ExposureGrid.shutterPath),
               setting.current == speed {
                log("hdr: shutter restored to \(speed)")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
        }
        log("hdr: WARNING could not restore the shutter to \(speed)")
        self.status("Couldn't put the shutter back to \(speed) — check the camera")
    }

    /// The plain RAW entry, for an HDR bracket.
    ///
    /// Same defensiveness as `jpegChoice` and for the same reason — libgphoto2 only partly decodes
    /// this body's list, which contains bare hex codes it has no name for. Take the unadorned "RAW",
    /// never a `RAW + 0x50` combination (that shoots RAW *and* a JPEG, doubling the download for a
    /// file the merge ignores) and never a hex code.
    static func rawChoice(in choices: [String]) -> String? {
        if let plain = choices.first(where: { $0.lowercased() == "raw" }) { return plain }
        // A named variant on builds that decode them, but still not a RAW+JPEG pair.
        return choices.first {
            let lower = $0.lowercased()
            return lower.contains("raw") && !lower.contains("+") && !lower.hasPrefix("m") && !lower.hasPrefix("s")
        }
    }

    /// Runs `body` with the camera shooting RAW, restoring the previous format afterwards.
    ///
    /// The mirror image of `withJPEGCapture`, and the reasoning inverts too: a focus stack is a
    /// dozen-plus frames whose merge is clamped to sRGB anyway, so RAW costs time and buys nothing —
    /// but an HDR bracket is three frames whose whole purpose is dynamic range, and RAW is where
    /// that range lives. Measured on a CR2 from this body, `CIRAWFilter` in a linear space returns
    /// values up to 1.97 where ImageIO's decode clips at 1.0 and gives only 8 bits per component.
    func withRAWCapture<T>(_ body: () async throws -> T) async throws -> T {
        if imageFormatDepth == 0 {
            if let setting = try? await imageFormatSetting(),
               !setting.readOnly,
               let raw = Self.rawChoice(in: setting.choices),
               setting.current != raw {
                imageFormatToRestore = setting.current
                // Persisted before the switch, for the reason spelled out in `withJPEGCapture`:
                // a restore that fails silently leaves the photographer's body on the wrong format.
                UserDefaults.standard.set(setting.current, forKey: Self.pendingFormatRestoreKey)
                try? await setConfig(Self.imageFormatPath, raw)
                log("image format: switched to \(raw) for the HDR bracket (was \(setting.current))")
            } else {
                imageFormatToRestore = nil
            }
        }
        imageFormatDepth += 1
        defer {
            imageFormatDepth -= 1
            if imageFormatDepth == 0, let restore = imageFormatToRestore {
                imageFormatToRestore = nil
                Task { [weak self] in
                    guard let self else { return }
                    await self.restoreImageFormat(restore)
                }
            }
        }
        return try await body()
    }

    private func imageFormatSetting() async throws -> CameraSetting? {
        let output = try await getConfig(Self.imageFormatPath)
        let setting = CameraSetting.parse(from: output, path: Self.imageFormatPath)
        if let setting {
            log("image format: \(setting.current) (choices: \(setting.choices))")
        }
        return setting
    }

    static let remoteReleasePath = "/main/actions/eosremoterelease"

    /// Fires the shutter **without autofocus**, and downloads the frame.
    ///
    /// `capture-image-and-download` autofocuses first on this body, which breaks focus stacking in
    /// two different ways depending on whether the AF succeeds. When it fails — which it does once
    /// focus has been racked off the subject — the capture is refused outright ("Canon EOS
    /// Auto-Focus failed, could not capture"). When it *succeeds* it is worse and quieter: it pulls
    /// focus back onto the subject, undoing the nudge, so every frame of the bracket is taken at the
    /// same focus and the merge has nothing to choose between. Measured on a real 9-frame bracket in
    /// that state, consecutive frames differed by 0.3% — sensor noise.
    ///
    /// `eosremoterelease` releases the shutter directly, leaving focus exactly where the bracket put
    /// it. The frame is then collected with an explicit `wait-event-and-download` in the same lock,
    /// rather than being left to the tether watch, so the bracket knows which files are its own.
    /// Fires the shutter and returns immediately, leaving the frame on the camera.
    ///
    /// A bracket does not need each file in hand before it can move focus — the camera buffers.
    /// Waiting made every frame pay for its own download in series with the focus move (~0.6 s of a
    /// ~1.8 s frame); firing and draining afterwards overlaps the transfer with the next move.
    private func releaseShutterLocked(_ release: [String]) async throws {
        for value in release {
            _ = try await sendCommandLocked(
                "set-config \(Self.remoteReleasePath)=\(value)",
                doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                timeout: 20
            )
        }
    }

    /// Collects frames the camera is holding, until `expected` have arrived or it goes quiet.
    /// - Parameter exposureSeconds: how long the shutter was open. The wait must outlast the
    ///   exposure itself: a frame cannot arrive before it has finished being taken, and counting
    ///   "quiet" rounds from the moment of release abandons every long exposure.
    ///
    ///   This bit hard. An automatic HDR bracket reached its +4 frame at 1.6 s, waited its three
    ///   empty 600 ms rounds — 1.8 s, barely past the exposure — gave up, and the frame then landed
    ///   in the tether watch two seconds later. The bracket stopped exactly where the scene needed
    ///   it to keep going, so the shadows it was extending for stayed crushed.
    private func drainDownloadsLocked(expected: Int, exposureSeconds: Double = 0) async -> [URL] {
        var collected: [URL] = []
        var quietRounds = 0
        let patientUntil = Date().addingTimeInterval(exposureSeconds + Self.downloadSlack)
        let deadline = Date().addingTimeInterval(Self.downloadTimeout * 2 + exposureSeconds)
        while collected.count < expected, Date() < deadline {
            guard let output = try? await sendCommandLocked(
                "wait-event-and-download 600ms",
                doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                timeout: 40,
                quiet: true
            ) else { break }
            let names = CaptureOutput.savedFilenames(in: output)
            if names.isEmpty {
                // Silence before the exposure can possibly have finished means nothing at all.
                if Date() < patientUntil { continue }
                quietRounds += 1
                // The camera has nothing more to give; a longer wait only delays the result.
                if quietRounds >= 3 { break }
                continue
            }
            quietRounds = 0
            collected.append(contentsOf: names.compactMap { importDownloaded($0) })
        }
        return collected
    }

    private func captureWithoutAutofocusOnce() async throws -> [URL] {
        lastFrameAt = Date()
        let release = try await releaseValues()
        let output: String = try await withCommandLock {
            for value in release {
                _ = try await sendCommandLocked(
                    "set-config \(Self.remoteReleasePath)=\(value)",
                    doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                    timeout: 20
                )
            }
            return try await waitForDownloadLocked()
        }
        if output.contains("Auto-Focus failed") {
            throw GPhotoError.commandFailed(output)
        }
        let names = CaptureOutput.savedFilenames(in: output)
        guard !names.isEmpty else {
            throw GPhotoError.commandFailed("The camera didn't return a frame:\n\(output)")
        }
        return names.compactMap { importDownloaded($0) }
    }

    /// Waits for the frame in short windows rather than one long one.
    ///
    /// `wait-event-and-download 6s` runs for **the whole six seconds** even though the file lands
    /// after about two — it collects events until its window expires. Measured, that made a bracket
    /// cycle 8.3 s per frame with roughly 4 s of it spent waiting on a file already downloaded.
    /// Polling in short windows returns as soon as the frame arrives, at the cost of one cheap
    /// command per window — and we already hold the lock, so there is no contention to pay for.
    private func waitForDownloadLocked() async throws -> String {
        let deadline = Date().addingTimeInterval(Self.downloadTimeout)
        var last = ""
        while Date() < deadline {
            let output = try await sendCommandLocked(
                "wait-event-and-download \(Self.downloadPollWindow)",
                doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                timeout: 20,
                quiet: true
            )
            last = output
            if !CaptureOutput.savedFilenames(in: output).isEmpty { return output }
            if output.contains("Auto-Focus failed") || output.contains("*** Error") { return output }
        }
        return last
    }

    /// Long enough for a 22 MB RAW over PTP/IP with room to spare; the poll returns early anyway.
    private static let downloadTimeout: TimeInterval = 20
    /// Shorter window returns the frame sooner; the cost is one extra cheap command per 200 ms of
    /// waiting, and we already hold the lock.
    private static let downloadPollWindow = "200ms"

    /// The `eosremoterelease` value(s) that fire the shutter **without** autofocus.
    ///
    /// Order matters, and got this wrong once: matching "press full" loosely picked `Press Full AF`
    /// — the autofocus variant — out of this body's list `["None", "Press Half AF", "Press Full AF",
    /// "Press Half MF", "Press Full MF", "Release Half", "Release Full", "Release"]`. Avoiding AF is
    /// the entire reason this path exists, so the MF variants are matched first and explicitly, and
    /// an AF variant is only ever a logged last resort.
    private func releaseValues() async throws -> [String] {
        if let cached = cachedReleaseValues { return cached }
        let output = try await getConfig(Self.remoteReleasePath)
        let choices = CameraSetting.parse(from: output, path: Self.remoteReleasePath)?.choices ?? []
        log("remote release choices: \(choices)")
        let values = Self.releaseSequence(from: choices)
        return values
    }

    /// Picks the press-and-release commands for one shot, from whatever the body advertises.
    /// Pure and `static` so it can be exercised without a camera.
    static func releaseSequence(from choices: [String]) -> [String] {
        func first(_ predicate: (String) -> Bool) -> String? {
            choices.first { predicate($0.lowercased()) }
        }

        // A **complete** release, not just "Release Full".
        //
        // On Canon, `Release Full` only takes the shutter button from fully-pressed back to
        // half-pressed — it does not let go. Firing `Press Full MF` → `Release Full` therefore
        // leaves the button logically half-down after every frame, with metering and the camera's
        // busy state still engaged. Over a thirteen-frame burst that ended with
        // `live view: stopping — camera link down`: the PTP session itself died and the camera had
        // to be reconnected by hand. The half-release is what finally lets go.
        let releaseFull = first { $0 == "release full" } ?? first { $0.contains("release") && $0.contains("full") }
        let releaseHalf = first { $0 == "release half" } ?? first { $0.contains("release") && $0.contains("half") }
        let plainRelease = first { $0 == "release" }
        let releaseSequence = [releaseFull, releaseHalf].compactMap { $0 }.isEmpty
            ? [plainRelease].compactMap { $0 }
            : [releaseFull, releaseHalf].compactMap { $0 }
        let releaseValue = releaseSequence.first

        let values: [String]
        if let immediate = first({ $0 == "immediate" }) {
            values = [immediate]
        } else if let pressMF = first({ $0.contains("full") && $0.contains("mf") }), releaseValue != nil {
            values = [pressMF] + releaseSequence
        } else if let pressFull = first({ $0 == "press full" }), releaseValue != nil {
            values = [pressFull] + releaseSequence
        } else if let pressAny = first({ $0.contains("full") && !$0.contains("half") }), releaseValue != nil {
            values = [pressAny] + releaseSequence
        } else {
            values = ["Immediate"]
        }
        return values
    }

    private var cachedReleaseValues: [String]?

    /// A coarse luma fingerprint, used **only** to tell "the image is identical" from "the image
    /// changed". Not a focus measure — that is `previewSharpness`, and conflating the two caused a
    /// detector that called every frame stalled. Here the question is genuinely whether any pixels
    /// moved, which is exactly what this answers.
    static func previewFingerprint(of jpeg: Data) -> [Float]? {
        // Via `ImageThumbnail`: a JPEG's embedded 160×120 EXIF thumbnail is returned for any
        // requested size otherwise, which would silently decide these comparisons for us.
        guard let image = ImageThumbnail.load(data: jpeg, maxPixel: 128) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return (0..<(w * h)).map { i in
            (0.2126 * Float(bytes[i * 4]) + 0.7152 * Float(bytes[i * 4 + 1])
                + 0.0722 * Float(bytes[i * 4 + 2])) / 255
        }
    }

    static func fingerprintDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var total: Float = 0
        for i in 0..<a.count { total += abs(a[i] - b[i]) }
        return total / Float(a.count)
    }

    /// Below this the two previews are the same picture plus noise — nothing in the frame moved.
    static let identicalFrameThreshold: Float = 0.004

    /// Per-tile sharpness of a preview frame, for building a `FocusDepthMap`.
    ///
    /// The scan needs to know *where each part of the frame* comes into focus, not how sharp the
    /// frame is overall — see `FocusDepthMap` for why a single curve cannot answer that.
    static func previewTileSharpness(of jpeg: Data) -> [Double]? {
        guard let image = ImageThumbnail.load(data: jpeg, maxPixel: 640) else { return nil }
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Luma normalised to [0,1], matching FocusAnalyzer: dividing a 0–255 gradient by a 0–255
        // mean² makes every tile score ~1e-4, and then no threshold means anything.
        var luma = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luma[i] = (0.2126 * Double(bytes[i * 4]) + 0.7152 * Double(bytes[i * 4 + 1])
                       + 0.0722 * Double(bytes[i * 4 + 2])) / 255
        }
        let grid = FocusDepthMap.grid
        var energy = [Double](repeating: 0, count: grid * grid)
        var sum = [Double](repeating: 0, count: grid * grid)
        var count = [Double](repeating: 0, count: grid * grid)
        for y in 1..<(h - 1) {
            let ty = Swift.min(y * grid / h, grid - 1)
            for x in 1..<(w - 1) {
                let tx = Swift.min(x * grid / w, grid - 1)
                let cell = ty * grid + tx
                let gx = luma[y * w + x + 1] - luma[y * w + x - 1]
                let gy = luma[(y + 1) * w + x] - luma[(y - 1) * w + x]
                energy[cell] += gx * gx + gy * gy
                sum[cell] += luma[y * w + x]
                count[cell] += 1
            }
        }
        return (0..<(grid * grid)).map { cell in
            guard count[cell] > 0 else { return 0 }
            let mean = sum[cell] / count[cell]
            return (energy[cell] / count[cell]) / (mean * mean + 4.0e-3)
        }
    }

    /// Sharpness of a preview frame, using the same analyzer the focus badge and scan use.
    ///
    /// 640 px, not a thumbnail: defocus lives in high frequencies, and a small decode throws away
    /// exactly the signal being measured. Returns nil if the frame can't be read, which callers
    /// treat as "can't tell" rather than "didn't move" — see `FocusMovement`.
    static func previewSharpness(of jpeg: Data) -> Double? {
        // See `ImageThumbnail`. Critical here: defocus is high-frequency, so measuring a 160×120
        // EXIF thumbnail instead of the 640 px asked for throws away the entire signal.
        guard let image = ImageThumbnail.load(data: jpeg, maxPixel: 640) else { return nil }
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let sharpness = FocusAnalyzer.measure(ScopeFrame(width: w, height: h, bytes: bytes)).sharpness
        return sharpness.isFinite ? sharpness : nil
    }

    /// Racks focus and reports how far the lens **actually** moved, stopping at the end of travel.
    ///
    /// Used for interactive racking, where an uncounted end stop is worst: the photographer marks a
    /// range against a cursor that has drifted from the lens, and the resulting bracket starts in
    /// the wrong place. Costs a preview every few steps, which at racking speeds is unnoticeable.
    /// Re-arms live view between frames of a bracket.
    ///
    /// Focus drive only works while live view is up, and **taking a still drops it** — so something
    /// has to bring it back between frames. This pulls a preview and throws the image away, which
    /// is wasteful but is the only method that has proven reliable on this body.
    ///
    /// `set-config /main/actions/viewfinder=1` was tried instead, to avoid shipping a JPEG nobody
    /// looks at (~3.4 s a frame at the time). It appeared to work and then poisoned live view:
    /// `capture-preview` began returning `*** Error (-1: 'Unspecified error')`, the feed hit its
    /// three-error limit and shut down, and it would not restart — the camera and gphoto2 end up
    /// disagreeing about whether live view is running. Do not reintroduce it without a way to prove
    /// the feed still recovers afterwards.
    @discardableResult
    private func armLiveViewLocked() async -> Bool {
        // Retries until a frame actually comes back.
        //
        // One attempt was not enough and failed silently: right after a shot the camera is busy
        // writing and refuses `capture-preview`, so live view stayed down — and focus drive does
        // nothing at all without it. The bracket then nudged happily between every frame and the
        // lens never moved, producing eleven identical exposures that look like a working stack
        // until they are measured.
        for attempt in 1...Self.liveViewArmAttempts {
            if await fetchPreviewLocked() != nil {
                if attempt > 1 { log("bracket: live view took \(attempt) attempts to come back") }
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        log("bracket: live view would not come back — focus cannot be driven")
        return false
    }

    /// Attempts to get a preview back between frames of a bracket. Enough to cover the camera
    /// finishing a write; beyond that something is actually wrong and the caller should be told.
    static let liveViewArmAttempts = 8

    /// `verify: false` skips the preview-and-compare entirely — much faster, at the cost of not
    /// noticing end-of-travel mid-bracket. That trade is right for a bracket: the static-frame check
    /// at merge time catches a lens that never moved, and it costs nothing per frame.
    func nudgeFocusVerified(_ step: FocusStep, times: Int, settleSeconds: Double, chunk: Int = 3,
                            verify: Bool = true)
        async throws -> (moved: Int, stalled: Bool) {
        guard times > 0 else { return (0, false) }
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability,
              let value = FocusStep.choice(for: step, in: choices) else {
            throw FocusDriveInterrupted(
                completed: 0,
                underlying: GPhotoError.commandFailed(
                    capability.explanation ?? "The camera doesn't offer a \(step.label) focus step."))
        }

        // Movement is judged against a baseline carried **across calls**, not within one.
        //
        // A single nudge cannot be judged on its own: near the peak one step changes sharpness
        // about 1%, under any threshold that isn't noise, so a per-call check reported "end of
        // travel" on every ±1 rack and refused to advance the cursor — which is precisely the
        // control used for fine marking. Accumulating until enough steps have gone by in one
        // direction gives the comparison something to see, and a bracket stepping one frame at a
        // time still gets a real end-of-travel verdict after a few frames.
        if stallBaselineStep != step {
            stallBaseline = nil
            stepsSinceBaseline = 0
            stallBaselineStep = step
        }

        var moved = 0
        var stalled = false
        var failure: Error?
        await withTetherPaused {
        await withLiveViewPaused {
            await withCommandLock {
                // Live view first: a still capture drops it, and focus drive does nothing without
                // it. If it will not come back, say so rather than stepping a lens that cannot move.
                if await armLiveViewLocked() == false {
                    failure = GPhotoError.commandFailed(
                        "The camera stopped providing live view mid-bracket, so focus could not be "
                        + "driven. The frames that were taken are all at one focus.")
                    return
                }
                if verify, stallBaseline == nil {
                    stallBaseline = await fetchPreviewLocked().flatMap(Self.previewSharpness)
                }
                while moved < times {
                    let count = min(max(chunk, 1), times - moved)
                    do {
                        for _ in 0..<count {
                            try Task.checkCancellation()
                            try await setConfigLocked(Self.focusDrivePath, value)
                            try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                        }
                    } catch {
                        failure = error
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
                    moved += count
                    stepsSinceBaseline += count

                    guard verify else { continue }
                    let sharpness = await fetchPreviewLocked().flatMap(Self.previewSharpness)
                    guard let sharpness, let baseline = stallBaseline else { continue }
                    if FocusMovement.moved(from: baseline, to: sharpness) {
                        stallBaseline = sharpness
                        stepsSinceBaseline = 0
                    } else if stepsSinceBaseline >= Self.minimumStepsToJudgeStall {
                        stalled = true
                        log("rack: focus stalled — \(stepsSinceBaseline) steps of \(step.label) "
                            + "with no change in sharpness (end of travel)")
                        // The steps that produced nothing are not movement: hand back only what
                        // actually moved, so the caller's cursor stays tied to the lens.
                        moved = max(0, moved - stepsSinceBaseline)
                        return
                    }
                }
            }
        }
        }
        if let failure { throw FocusDriveInterrupted(completed: moved, underlying: failure) }
        return (moved, stalled)
    }

    /// Steps that must pass in one direction with no sharpness change before calling end-of-travel.
    /// One step changes sharpness ~1% near the peak — indistinguishable from noise — so judging a
    /// single nudge produced constant false verdicts on the ±1 racking control.
    static let minimumStepsToJudgeStall = 4

    /// Baseline for the cross-call stall comparison, and the direction it belongs to. Reversing
    /// direction invalidates it: driving back off an end stop moves immediately.
    private var stallBaseline: Double?
    private var stepsSinceBaseline = 0
    private var stallBaselineStep: FocusStep?

    /// Consecutive below-threshold readings that end an envelope walk. Matches
    /// `FocusScanReader.gapTolerance` in spirit: short dips are surfaces within the subject.
    static let envelopeTailSteps = 4

    /// Bound on each leg of the envelope walk, so a textureless scene cannot walk the lens to its
    /// stops. Comfortably larger than any subject depth measured so far.
    static let maxEnvelopeSteps = 60

    /// Safety net on the climb, not a design limit: it should end on a sustained fall in sharpness
    /// or on end of travel, and only hit this if neither ever happens.
    ///
    /// Was 36, which was too low to be a safety net — replaying a recorded focus map showed the
    /// climb stopping 15–30 steps short of the peak whenever it started from the far side, because
    /// the peak was simply further away than the cap allowed. A lens has 90+ steps of travel at
    /// medium magnitude, so the cap has to exceed that to never be the thing that stops the climb.
    static let maxClimb = 110

    /// Below this fraction of the reference reading, a measurement is treated as a different
    /// picture (a dropped magnification) rather than a focus change, and retaken once.
    static let implausibleDropFraction = 0.4

    /// How far below the best reading a chunk may fall and still count as noise rather than the
    /// far side of the peak. Measured on a real subject, adjacent readings vary by 3–4%.
    static let climbNoiseMargin = 0.05

    /// Drives focus to a known offset by **looking**, not by counting.
    ///
    /// Counting nudges is open-loop and drifts: a nudge the camera accepts at an end of travel moves
    /// nothing, and the count runs ahead of the lens for the rest of the session. Measured on a real
    /// run, a sweep that drove out to +147 (past the lens's actual limit) left every later position
    /// wrong by ~60 steps — the bracket was told to shoot −48…44 and actually shot +105…+11, missing
    /// the subject entirely while every number in the log looked right.
    ///
    /// The sweep already photographed the whole range, so each of its frames is a labelled picture
    /// of "what the scene looks like at this offset". Comparing a live preview against them says
    /// where the lens *is*, and the error is then driven out. Correlation is decisive in practice —
    /// 0.99 against the correct frame.
    func seekToOffset(_ target: Int,
                      reference: [(offset: Int, tiles: [Double])],
                      magnitude: Int) async -> Int? {
        guard !reference.isEmpty else { return nil }
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability,
              let toward = FocusStep.choice(for: FocusStep.step(towardCamera: true, magnitude: magnitude), in: choices),
              let away = FocusStep.choice(for: FocusStep.step(towardCamera: false, magnitude: magnitude), in: choices)
        else { return nil }

        var position: Int?
        await withLiveViewPaused {
            await withCommandLock {
                for attempt in 1...Self.seekAttempts {
                    guard let frame = await fetchPreviewLocked(),
                          let tiles = Self.previewTileSharpness(of: frame) else { break }
                    guard let here = Self.bestMatch(tiles, in: reference) else { break }
                    position = here
                    let error = target - here
                    if abs(error) <= Self.seekTolerance {
                        log("seek: at offset \(here), target \(target) — within tolerance after \(attempt) look(s)")
                        return
                    }
                    log("seek: at offset \(here), target \(target) — driving \(error) steps")
                    let value = error < 0 ? toward : away
                    for _ in 0..<min(abs(error), Self.seekMaxStepsPerAttempt) {
                        guard (try? await setConfigLocked(Self.focusDrivePath, value)) != nil else { break }
                        try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        return position
    }

    /// Nearest sweep frame by cosine similarity of tile sharpness.
    static func bestMatch(_ tiles: [Double], in reference: [(offset: Int, tiles: [Double])]) -> Int? {
        var best: (offset: Int, score: Double)?
        for entry in reference where entry.tiles.count == tiles.count {
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0..<tiles.count {
                dot += tiles[i] * entry.tiles[i]
                na += tiles[i] * tiles[i]
                nb += entry.tiles[i] * entry.tiles[i]
            }
            let score = dot / (na.squareRoot() * nb.squareRoot() + 1e-9)
            if best == nil || score > best!.score { best = (entry.offset, score) }
        }
        return best?.offset
    }

    static let seekAttempts = 6
    static let seekTolerance = 2
    static let seekMaxStepsPerAttempt = 80

    /// Records a **focus map**: one preview frame at every single focus step from one end of the
    /// lens's travel to the other, written to disk with its offset in the filename.
    ///
    /// This exists to end a bad development loop. Tuning the scan against the camera meant a full
    /// round trip — rebuild, relaunch, rack, sweep, read the log — for every change, and the scan
    /// has needed several calibrations. A map is captured **once** and then the climb, the peak
    /// finding, the stall detection and the range reader can all be replayed against it offline as
    /// often as needed, on real frames of a real subject rather than synthetic blur.
    ///
    /// Returns the folder written. Frames are named `step_<offset>.jpg`, offsets relative to the
    /// position focus started at, negative toward the camera.
    func recordFocusMap(magnitude: Int, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability,
              let towardValue = FocusStep.choice(for: FocusStep.step(towardCamera: true, magnitude: magnitude),
                                                 in: choices),
              let awayValue = FocusStep.choice(for: FocusStep.step(towardCamera: false, magnitude: magnitude),
                                               in: choices) else {
            throw GPhotoError.commandFailed(capability.explanation ?? "Focus stacking isn't available.")
        }

        let folder = Self.diagnosticsDirectory.appendingPathComponent(
            "Focus Map " + DateFormatter.captureFilenameFormatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var saved = 0
        await withTetherPaused {
            await withLiveViewPaused {
                await withCommandLock {
                    // Un-magnified, like the sweep — a recorded map is only useful for replaying
                    // the real thing if it sees what the real thing sees.
                    try? await setConfigLocked(Self.zoomPath, "1")
                    try? await Task.sleep(nanoseconds: 600_000_000)

                    // Deliberately **no end-of-travel detection** on either leg.
                    //
                    // The first version stopped after 6 steps: it judged "did the lens move" from
                    // the 128 px fingerprint, which is too coarse to see a focus change at all
                    // (defocus is high-frequency — the same mistake that has bitten this file
                    // repeatedly), and it also carried its stall counter from the inward leg into
                    // the outward one, so recording stopped on the first check. A recorder gains
                    // nothing from stopping early: frames taken against an end stop are duplicates,
                    // which cost a second each and are obvious in the map.
                    progress("Running \(Self.focusMapInSteps) steps toward the camera…")
                    for _ in 0..<Self.focusMapInSteps {
                        guard (try? await setConfigLocked(Self.focusDrivePath, towardValue)) != nil else { break }
                        try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)

                    var offset = -Self.focusMapInSteps
                    for step in 0...Self.focusMapOutSteps {
                        progress("Recording frame \(step + 1) of \(Self.focusMapOutSteps + 1)…")
                        if let frame = await fetchPreviewLocked() {
                            let name = String(format: "step_%+04d.jpg", offset)
                            try? frame.write(to: folder.appendingPathComponent(name))
                            liveViewContinuation?.yield(frame)
                            saved += 1
                        }
                        guard step < Self.focusMapOutSteps else { break }
                        guard (try? await setConfigLocked(Self.focusDrivePath, awayValue)) != nil else { break }
                        offset += 1
                        try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                    }
                    log("focus map: \(saved) frames, offsets \(-Self.focusMapInSteps)…\(offset)")

                    progress("Returning focus…")
                    let home = offset
                    if home != 0 {
                        let value = home > 0 ? towardValue : awayValue
                        for _ in 0..<abs(home) {
                            guard (try? await setConfigLocked(Self.focusDrivePath, value)) != nil else { break }
                            try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                        }
                    }
                }
            }
        }
        return folder
    }

    /// Steps run toward the camera before recording starts, and steps recorded on the way back out.
    /// Together they span 90 focus steps centred a little nearer than where focus started, which has
    /// comfortably contained every subject measured so far. ~70 s to record.
    /// Steps between sweep samples. 2 halves the sweep's duration and, measured on a real sweep,
    /// finds exactly the same range — the depth map only needs the *shape* of the focus curve, and
    /// the range gets a margin either side regardless.
    static let scanStride = 2

    /// The sweep is **symmetric** about where autofocus left the lens.
    ///
    /// It used to reach 35 steps nearer and 55 further, which repeatedly clipped the near end:
    /// three consecutive real runs produced a range starting exactly at the sweep's first sample,
    /// meaning the subject carried on past where the scan looked.
    static let scanInSteps = 45
    static let scanOutSteps = 90

    /// Aggregate sharpness must fall below this share of the peak, for this many consecutive
    /// samples, before the sweep calls it done — and never before `scanMinimumSamples`, so a dip on
    /// the way *into* focus cannot end it early.
    static let scanFalloffFraction = 0.7
    static let scanFalloffSamples = 3
    /// Consecutive unchanged samples that mean the lens is against a stop.
    ///
    /// Much larger than `scanFalloffSamples`, and deliberately so: a *defocused* subject also
    /// barely changes between two steps, so a short run of near-identical frames is the normal
    /// look of the blurred end of a sweep, not an end of travel. Three was enough to abort real
    /// sweeps four samples in and report a textured subject as having no usable tiles.
    static let scanEndOfTravelSamples = 8
    static let scanMinimumSamples = 12

    /// Tiles that may still be improving while the sweep calls itself done. Not zero: a couple of
    /// tiles will always flicker upward on noise.
    static let scanImprovingTileFloor = 3

    /// How far the sweep will chase a subject that lies outside its initial window, and in what
    /// increments. Being off-centre must not break the scan: the photographer should be able to
    /// pick a subject at any depth, and the cost of finding it is time rather than failure.
    static let scanExtensionSteps = 30
    static let scanMaxExtraSteps = 120

    /// Seconds (one attempt each) to wait for the camera to start producing previews again after a
    /// bracket. Generous: the alternative is a dead feed the photographer has to fix by hand.
    /// Attempts (1.5 s apart) to get the camera producing previews again. Generous on purpose: this
    /// runs in the background where waiting costs nothing, and the alternative is a photographer who
    /// cannot shoot a second stack without power-cycling the body.
    /// Gap between shutter releases in a bracket.
    static let interFramePause: UInt64 = 350_000_000

    static let liveViewRecoveryAttempts = 60

    /// Polls until the camera will produce a preview again, or gives up.
    ///
    /// After a burst of stills this body refuses `capture-preview` — measured, for **longer than
    /// 12 seconds** after a 13-frame bracket — and the preview loop gives up after three failures.
    /// Every fixed pause tried here was a guess that turned out too short, so this asks the camera
    /// instead of guessing, and it runs *outside* the bracket so the merge is not held up waiting.
    func waitForLiveViewReady() async -> Bool {
        for attempt in 1...Self.liveViewRecoveryAttempts {
            let ready = await withCommandLock { await fetchPreviewLocked() != nil }
            if ready {
                log("live view: camera ready again after \(attempt) attempt(s)")
                return true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        log("live view: camera still not producing frames after \(Self.liveViewRecoveryAttempts) attempts")
        status("The camera stopped providing live view — switch it off and on if it doesn't return")
        return false
    }

    static let focusMapInSteps = 35
    static let focusMapOutSteps = 90

    /// Racks focus hard in each direction, returning a preview after every leg    /// Racks focus hard in each direction, returning a preview after every leg so the caller can
    /// measure what actually happened.
    ///
    /// The first version of this drove only *away* from the camera and compared frames by mean pixel
    /// difference. Both were mistakes. Driving one direction cannot distinguish "the command does
    /// nothing" from "the lens is already against that end stop" — and pixel difference on live-view
    /// JPEGs sits around 0.007 from noise alone, which is the same order as the numbers it was being
    /// asked to judge. So: both directions, big moves, and the caller scores *sharpness*, which a
    /// focus change alters enormously and noise does not.
    func diagnoseFocusDrive(magnitude: Int) async -> [(label: String, frame: Data)] {
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability else { return [] }
        // Coarse steps regardless of the panel's setting: this is a "did anything move at all" test,
        // and a fine step is exactly the one most easily lost in noise.
        let coarse = 3
        guard let near = FocusStep.choice(for: FocusStep.step(towardCamera: true, magnitude: coarse),
                                          in: choices),
              let far = FocusStep.choice(for: FocusStep.step(towardCamera: false, magnitude: coarse),
                                         in: choices) else { return [] }

        var results: [(label: String, frame: Data)] = []
        await withLiveViewPaused {
            await withCommandLock {
                func snapshot(_ label: String) async {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let frame = await fetchPreviewLocked() {
                        results.append((label: label, frame: frame))
                    }
                }
                func drive(_ value: String, times: Int) async {
                    for _ in 0..<times {
                        try? await setConfigLocked(Self.focusDrivePath, value)
                        try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                    }
                }

                await snapshot("start")
                // Toward the camera, in two legs: if the lens was against the far stop, the first
                // leg moves and proves the drive works after all.
                await drive(near, times: 10)
                await snapshot("after 10 toward camera")
                await drive(near, times: 10)
                await snapshot("after 20 toward camera")
                // Back out past the start, again in two legs.
                await drive(far, times: 20)
                await snapshot("back at start")
                await drive(far, times: 10)
                await snapshot("after 10 away from camera")
                // Leave focus where it began.
                await drive(near, times: 10)
            }
        }
        return results
    }

    /// Dumps the camera's entire config tree to the log, once per session.
    ///
    /// This exists to answer questions like "does this body report focus distance live?" with
    /// evidence instead of guesswork. The alternative — running a second `gphoto2` against a camera
    /// this app already holds — risks the pairing dance documented at the top of this file, so the
    /// investigation has to happen through the session that is already open.
    ///
    /// Canon's *captured files* carry `FocusDistanceUpper/Lower` in MakerNotes, but only for lenses
    /// with a distance encoder: measured on this rig (2026-09-11), an EF 85mm f/1.8 USM reports 0
    /// in every frame. So anything built on focus distance has to be optional per lens.
    private var loggedConfigList = false

    func logConfigList() async {
        guard !loggedConfigList else { return }
        loggedConfigList = true
        do {
            let output = try await sendCommand(
                "list-config",
                doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
                timeout: 30
            )
            let paths = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("/main/") }
            log("camera exposes \(paths.count) config paths:")
            for path in paths { log("  config: \(path)") }
            // Call out anything that might carry focus position or distance, so the answer is
            // greppable rather than buried in a hundred lines.
            let interesting = paths.filter {
                let lower = $0.lowercased()
                return lower.contains("focus") || lower.contains("distance")
                    || lower.contains("depth") || lower.contains("lens")
            }
            log("focus/distance-related paths: \(interesting.isEmpty ? "none" : interesting.joined(separator: ", "))")
        } catch {
            log("list-config failed: \(error.localizedDescription)")
        }
    }

    /// Nudges focus once. `choices` comes from the capability probe so the exact string this body
    /// advertises is used rather than a guessed spelling.
    private func driveFocusOnce(_ step: FocusStep, choices: [String]) async throws {
        guard let value = FocusStep.choice(for: step, in: choices) else {
            throw GPhotoError.commandFailed("The camera doesn't offer a \(step.label) focus step.")
        }
        try await setConfig(Self.focusDrivePath, value)
    }

    /// Drives focus by `times` nudges of `step`, waiting `settleSeconds` after each so the motor
    /// has stopped before the next command (or before anything reads the live view). This is the
    /// primitive the ranging UI racks with, and it is the same one the bracket uses — which is what
    /// makes a counted range reproduce exactly when the bracket walks it again.
    ///
    /// Returns how many nudges actually completed, and on failure throws
    /// `FocusDriveInterrupted` carrying that same count. Both matter: the whole ranging model is a
    /// count of nudges, so a rack that dies halfway must still report the half that happened — a
    /// caller that assumed "threw, therefore nothing moved" would leave its cursor permanently out
    /// of step with the lens, and every mark measured afterwards would be silently wrong.
    ///
    /// **The whole rack runs under one lock acquisition.** Measured on the wire, a single
    /// `set-config manualfocusdrive` takes 21 ms — but one-lock-per-nudge made every one of them
    /// queue behind a full tether listening window, so consecutive nudges landed 1.1 s apart and a
    /// five-step rack took five and a half seconds. This is the same batching `fetchSettings`
    /// already needed and for the same reason. Between nudges there is only a short motor pause,
    /// not the full settle: settling matters before something *reads* the result — a capture or a
    /// preview — not between two nudges that are going the same way.
    @discardableResult
    func nudgeFocus(_ step: FocusStep, times: Int, settleSeconds: Double) async throws -> Int {
        try await withTetherPaused {
            try await withManualFocus {
                try await nudgeFocusInner(step, times: times, settleSeconds: settleSeconds)
            }
        }
    }

    @discardableResult
    private func nudgeFocusInner(_ step: FocusStep, times: Int, settleSeconds: Double) async throws -> Int {
        guard times > 0 else { return 0 }
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability,
              let value = FocusStep.choice(for: step, in: choices) else {
            throw FocusDriveInterrupted(
                completed: 0,
                underlying: GPhotoError.commandFailed(
                    capability.explanation ?? "The camera doesn't offer a \(step.label) focus step."))
        }
        var completed = 0
        var failure: Error?
        await withCommandLock {
            for index in 0..<times {
                do {
                    try Task.checkCancellation()
                    try await setConfigLocked(Self.focusDrivePath, value)
                } catch {
                    failure = error
                    return
                }
                completed += 1
                if index < times - 1 {
                    try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                }
            }
        }
        // The settle happens outside the lock: it's the lens catching up, not the camera being
        // busy, so there's no reason to hold everything else off while it does.
        if completed > 0 { try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000)) }
        if let failure { throw FocusDriveInterrupted(completed: completed, underlying: failure) }
        return completed
    }

    /// Pause between consecutive nudges of a batched rack. The command returns in ~21 ms and the
    /// motor needs a moment to act on it; this is not a settle, just enough that steps aren't
    /// stacked faster than the lens can take them.
    /// Pause between consecutive nudges of a batched rack. Measured on the wire, the command itself
    /// returns in ~20 ms; this is the motor's share. 90 ms holds up across every bracket shot so far
    /// and saves ~30 ms per step against the 120 ms it started at.
    private static let focusMotorPause: UInt64 = 90_000_000

    /// Sweeps focus across ±`radius` nudges and returns a preview frame from each stop, paired with
    /// the offset (in nudges, relative to where the sweep started) it was taken at.
    ///
    /// **The entire sweep holds the command lock**, and each frame is captured immediately after
    /// the nudge that produced it. Both are essential. Per-command locking made every step wait a
    /// full tether window, turning a 21-stop sweep into minutes; and reading the *live view feed*
    /// after a nudge — what the first version did — scores a frame that was captured before the
    /// lens moved, because the next preview is still queued behind the lock. That silently produced
    /// a focus curve offset from reality, which is exactly the sort of wrong that looks like
    /// "auto-find doesn't work".
    ///
    /// Frames are also yielded to the live-view stream as they arrive, so the sweep is visible.
    /// Sweeps focus across the lens's travel, returning a preview frame at every step.
    ///
    /// This is the same traversal `recordFocusMap` makes, and deliberately so: the caller builds a
    /// `FocusDepthMap` from these frames, which needs the whole sweep rather than a cleverly-chosen
    /// window. The previous design — climb to a peak, then walk outward until sharpness fell off —
    /// is gone. It was tuned three times and still could not answer the question a stack asks,
    /// because *no* single sharpness curve can: a whole-frame curve never falls off in a deep scene
    /// (measured: no near edge at all across 91 steps), and a small-region curve's width is depth of
    /// field, not subject depth.
    func scanFocus(
        magnitude: Int,
        settleSeconds: Double,
        region: FocusDepthMap.Region? = nil,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> (samples: [(offset: Int, frame: Data)], travelled: Int) {
        let capability = await focusDriveCapability()
        guard case .available(let choices) = capability,
              let towardValue = FocusStep.choice(for: FocusStep.step(towardCamera: true, magnitude: magnitude),
                                                 in: choices),
              let awayValue = FocusStep.choice(for: FocusStep.step(towardCamera: false, magnitude: magnitude),
                                               in: choices) else {
            throw FocusDriveInterrupted(completed: 0,
                                        underlying: GPhotoError.commandFailed("The camera won't drive focus both ways."))
        }

        var samples: [(offset: Int, frame: Data)] = []
        var travelled = 0
        await withTetherPaused {
            await withLiveViewPaused {
                await withCommandLock {
                    // The sweep measures the **un-magnified** frame.
                    //
                    // Magnification was added to boost a weak whole-frame sharpness signal, back
                    // when that was the measurement. It is actively harmful now: the photographer
                    // draws the subject box on the fit-to-frame live view, and those normalised
                    // coordinates are meaningless against a 5× centre crop — the depth map was
                    // measuring a different part of the scene than the box described, which is why
                    // ranges came back too narrow and the ends of the subject stayed soft.
                    // Per-tile analysis does not need the punch-in; each tile is read on its own
                    // terms at whatever scale it is presented.
                    try? await setConfigLocked(Self.zoomPath, "1")
                    try? await Task.sleep(nanoseconds: 600_000_000)

                    let inSteps = Self.scanInSteps, outSteps = Self.scanOutSteps
                    for _ in 0..<inSteps {
                        guard (try? await setConfigLocked(Self.focusDrivePath, towardValue)) != nil else { break }
                        travelled -= 1
                        try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))

                    // A frame every `scanStride` steps, not every step. Replayed against a real
                    // sweep, sampling every other step returned the *identical* range from half the
                    // frames; the expensive part is the preview, not the driving.
                    let stride = Self.scanStride

                    /// Aggregate sharpness over the middle of the frame: a cheap stand-in for
                    /// "is the subject still coming into focus".
                    func aggregate(_ frame: Data) -> Double? {
                        guard let tiles = Self.previewTileSharpness(of: frame) else { return nil }
                        let grid = FocusDepthMap.grid
                        var total = 0.0
                        for row in (grid / 4)..<(grid - grid / 4) {
                            for column in (grid / 4)..<(grid - grid / 4) {
                                total += tiles[row * grid + column]
                            }
                        }
                        return total
                    }

                    /// All the stop rules, in one testable place (`CanonTetherCore`).
                    ///
                    /// They used to live inline here, which meant every calibration could only be
                    /// checked by shooting a real sweep and reading the log — and four separate
                    /// misfires reached the photographer that way.
                    var monitor = FocusSweepMonitor(region: region)
                    /// For spotting an end of travel, where consecutive frames are identical.
                    var lastFingerprint: [Float]?

                    /// Takes one sample here. Returns false once nothing in the frame is still
                    /// improving, which is the only safe signal that the sweep can stop.
                    func sampleHere() async -> Bool {
                        guard let frame = await fetchPreviewLocked() else { return true }
                        samples.append((offset: travelled, frame: frame))
                        liveViewContinuation?.yield(frame)
                        guard let tiles = Self.previewTileSharpness(of: frame) else { return true }

                        // Has the picture changed since the last sample? `nil` when it cannot
                        // be told, which the monitor treats as movement — a false end of travel
                        // truncates the sweep, while a false "moved" costs one sample.
                        let now = Self.previewFingerprint(of: frame)
                        var unchanged: Bool?
                        if let previous = lastFingerprint, let now {
                            unchanged = Self.fingerprintDistance(previous, now) < Self.identicalFrameThreshold
                        }
                        if unchanged != true, let now { lastFingerprint = now }

                        switch monitor.record(offset: travelled, tiles: tiles, unchanged: unchanged) {
                        case .endOfTravel:
                            log("scan: end of travel — stopping after \(samples.count) samples")
                            return false
                        case .measured:
                            log("scan: nothing left improving — stopping after \(samples.count) samples")
                            return false
                        case nil:
                            break
                        }
                        return true
                    }

                    /// Sweeps `steps` further in one direction, sampling as it goes.
                    func sweep(_ value: String, sign: Int, steps: Int) async -> Bool {
                        for step in 0..<steps {
                            if Task.isCancelled { return false }
                            if step % stride == 0 {
                                onProgress(samples.count, 0)
                                if await sampleHere() == false { return false }
                            }
                            guard (try? await setConfigLocked(Self.focusDrivePath, value)) != nil else { return false }
                            travelled += sign
                            try? await Task.sleep(nanoseconds: Self.focusMotorPause)
                        }
                        return true
                    }

                    _ = await sweep(awayValue, sign: 1, steps: outSteps)
                    _ = await sampleHere()

                    // Keep hunting if the subject has not been found yet.
                    //
                    // The window is centred on wherever focus happened to start, so a subject at
                    // some other depth falls outside it — three consecutive real runs produced a
                    // range starting exactly at the sweep's first sample, meaning the subject
                    // carried on past where the scan looked, and the stack that followed left those
                    // surfaces soft. Rather than assume the photographer has focused nearby, extend
                    // in whichever direction the evidence points.
                    // Note this loop does **not** require `keepGoing`. Gating it on that meant an
                    // early stop disabled the very check meant to catch a premature one: a real
                    // sweep ended with nine tiles still pinned at its edge and no extension ever
                    // ran, leaving a 12-step range for a subject that ran much further.
                    var extra = 0
                    // `identicalFrames` having tripped means the lens is against a stop; extending
                    // further only re-photographs the same frame.
                    while extra < Self.scanMaxExtraSteps, !monitor.readings.isEmpty,
                          !monitor.isAtEndOfTravel {
                        let readings = monitor.readings
                        let best = readings.max { $0.value < $1.value }!
                        if monitor.stillImproving || best.offset == readings.last!.offset {
                            // Still climbing at the far end, or parts of the scene still coming
                            // into focus — either way there is more subject out there.
                            log("scan: subject still sharpening, extending outward")
                            _ = await sweep(awayValue, sign: 1, steps: Self.scanExtensionSteps)
                            _ = await sampleHere()
                        } else if best.offset == readings.first!.offset {
                            // The best reading is the very first sample: the subject is nearer than
                            // the sweep began. Go back past the start and carry on inward.
                            log("scan: subject lies nearer than the sweep began, extending inward")
                            let back = travelled - readings.first!.offset
                            if back > 0 { _ = await sweep(towardValue, sign: -1, steps: back) }
                            _ = await sweep(towardValue, sign: -1, steps: Self.scanExtensionSteps)
                            _ = await sampleHere()
                        } else {
                            break   // peak is bracketed on both sides
                        }
                        extra += Self.scanExtensionSteps
                    }

                    // Deliberately **not** returning home.
                    //
                    // The sweep ends at one extreme of the range it just measured, and the bracket
                    // has to start at one end of that range — so walking all the way back to the
                    // start, only to walk out again, is ~90 steps of pure travel. The caller is told
                    // where focus actually ended (`travelled`) and shoots from whichever end is
                    // nearer, in whichever direction that implies. A stack does not care which way
                    // it was shot.
                }
            }
        }
        return (samples, travelled)
    }

    /// One preview frame, assuming the command lock is already held. Split out of `liveViewTick`
    /// so the focus sweep can take frames without going through the live-view loop's error
    /// counting and auto-stop, which are about a *streaming* feed and don't apply here.
    private func fetchPreviewLocked() async -> Data? {
        guard let output = try? await sendCommandLocked(
            "capture-preview",
            doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
            timeout: 10,
            quiet: true
        ) else { return nil }
        guard let name = CaptureOutput.savedFilenames(in: output).last else { return nil }
        let url = Self.stagingDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    /// `setConfig` for callers that already hold the lock.
    private func setConfigLocked(_ name: String, _ value: String) async throws {
        let output = try await sendCommandLocked(
            "set-config \(name)=\(value)",
            doneMarkers: ["gphoto2:", "*** Error", "ERROR"],
            timeout: 15
        )
        if output.contains("*** Error") || output.contains("ERROR") {
            throw GPhotoError.commandFailed(output)
        }
    }

    /// Shoots a focus bracket: capture, nudge, repeat — then walk the focus back to where it
    /// started. Returns the captured files in capture order, which is also focus order, which is
    /// what the merge relies on to chain its alignment between neighbouring frames.
    ///
    /// Live view is started if it isn't already running and stopped again afterwards: Canon's
    /// focus-drive action is a live-view-mode operation, and a bracket shot without it silently
    /// produces N identical frames — the worst possible failure, since it looks like it worked.
    func captureFocusStack(
        _ plan: FocusStackPlan,
        asJPEG: Bool,
        progress: @escaping @Sendable (FocusBracketProgress) -> Void
    ) async throws -> FocusBracketResult {
        // The whole bracket runs in manual focus: one switch for the entire sequence, so the
        // shutter never autofocuses between frames and every nudge actually moves the lens.
        try await withManualFocus {
            guard asJPEG else { return try await captureFocusStackInner(plan, progress: progress) }
            return try await withJPEGCapture {
                try await captureFocusStackInner(plan, progress: progress)
            }
        }
    }

    private func captureFocusStackInner(
        _ plan: FocusStackPlan,
        progress: @escaping @Sendable (FocusBracketProgress) -> Void
    ) async throws -> FocusBracketResult {
        // Still checked up front so a bracket fails immediately and clearly rather than part-way
        // through; the choice strings themselves are resolved inside `nudgeFocus`.
        let capability = await focusDriveCapability()
        guard capability.isAvailable else {
            throw GPhotoError.commandFailed(capability.explanation ?? "Focus stacking isn't available.")
        }

        // Everything this bracket downloads goes into its own folder, named with the same stamp
        // format as a capture so it sorts among them.
        let groupDirectory = captureDirectory
            .appendingPathComponent(CaptureLocation.stackFolderName(for: Date()))
        try? FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        stackGroupDirectory = groupDirectory
        defer { stackGroupDirectory = nil }

        let startedLiveView = liveViewTask == nil
        if startedLiveView {
            startLiveView()
            // Give the body a moment to actually enter live view before the first focus command;
            // driving focus before the mirror is up fails outright on this body.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        progress(FocusBracketProgress(phase: .preparing, framesCaptured: 0))

        var captured: [URL] = []
        var stepsTaken = 0
        var thrown: Error?

        // The live-view *loop* is paused for the bracket — but a preview is still taken after every
        // focus step, and that distinction is load-bearing.
        //
        // **Canon's focus drive only works while live view is actually running.** Pausing the loop
        // outright, with nothing else fetching previews, lets the body drop out of live-view mode,
        // after which `manualfocusdrive` is accepted and acknowledged and moves nothing. That was
        // shipped here and produced a 15-frame bracket where every frame measured 38.0–38.6 with
        // the sharp region in the same tile — while auto-find, which previews at every step, had
        // racked the same lens successfully minutes earlier.
        //
        // So `nudgeFocusVerified` does the stepping: one preview per step keeps live view alive for
        // ~170 ms of cost, against the ~3 s per frame the free-running loop cost fighting for the
        // command lock (measured: frames 4.2 s apart with the loop running, 1.2 s without).
        await withTetherPaused {
        await withLiveViewPaused {
        do {
            let release = try await releaseValues()
            for frame in 1...plan.frameCount {
                try Task.checkCancellation()
                progress(FocusBracketProgress(phase: .capturing(frame: frame, of: plan.frameCount),
                                              framesCaptured: captured.count))
                // Fire, then collect this frame before moving on.
                //
                // Firing everything back to back and draining afterwards was faster on paper and
                // wrong in practice: the camera is busy writing the whole time, which is precisely
                // when it refuses the `capture-preview` that brings live view back — and without
                // live view the focus nudges between frames do nothing. A bracket of identical
                // frames is not a saving.
                // Time each part of a frame separately.
                //
                // A bracket's cost was only ever visible as one number — seconds between frames —
                // which is not enough to act on: shutter, download and the preview that re-arms
                // live view are three different problems with three different fixes, and guessing
                // which one owns the time has misled this feature more than once.
                let frameStarted = Date()
                try await withCommandLock { try await releaseShutterLocked(release) }
                let shutterDone = Date()
                lastFrameAt = Date()
                // Collect whatever the camera is ready to hand over, not exactly one frame.
                //
                // Asking for exactly one made the count drift: a wait that returned nothing left
                // that frame uncounted, while a wait that returned two had the extra ignored. The
                // files all reached the folder — the *accounting* was wrong, and the merge was
                // handed a third of the stack.
                // Ask for **this** frame, not for every frame still outstanding.
                //
                // Passing the whole remaining count meant the drain could never be satisfied: one
                // shot produces one file, so after collecting it the loop kept polling
                // `wait-event-and-download 600ms` until three empty rounds proved nothing more was
                // coming — 1.8s of waiting on every frame of the bracket. The tell was in the
                // timings: frame 20 downloaded in 2.47s and frame 21, where the remaining count
                // happened to be 1, downloaded the identical file in 0.69s.
                //
                // Every filename the drain sees is still kept, so a wait that hands back two frames
                // does not lose one — which is what the previous "exactly one" attempt got wrong
                // and why this reads the count from what arrived rather than from what was asked.
                captured.append(contentsOf: try await withCommandLock {
                    await drainDownloadsLocked(expected: 1)
                })
                let downloadDone = Date()

                guard frame < plan.frameCount else {
                    log(String(format: "bracket: frame %d took %.2fs (shutter %.2f, download %.2f)",
                               frame, downloadDone.timeIntervalSince(frameStarted),
                               shutterDone.timeIntervalSince(frameStarted),
                               downloadDone.timeIntervalSince(shutterDone)))
                    break
                }
                try Task.checkCancellation()
                progress(FocusBracketProgress(phase: .steppingFocus(frame: frame, of: plan.frameCount),
                                              framesCaptured: captured.count))
                let (moved, stalled) = try await nudgeFocusVerified(plan.step,
                                                                    times: plan.stepsPerFrame,
                                                                    settleSeconds: plan.settleSeconds,
                                                                    chunk: plan.stepsPerFrame,
                                                                    verify: false)
                stepsTaken += moved
                log(String(format: "bracket: frame %d took %.2fs (shutter %.2f, download %.2f, focus %.2f)",
                           frame, Date().timeIntervalSince(frameStarted),
                           shutterDone.timeIntervalSince(frameStarted),
                           downloadDone.timeIntervalSince(shutterDone),
                           Date().timeIntervalSince(downloadDone)))
                if stalled {
                    log("bracket: focus reached the end of its travel after \(frame) frames — stopping")
                    status("Focus reached the end of its travel — bracket stopped at \(frame) frames")
                    break
                }
            }

            // Anything the camera is still holding.
            if captured.count < plan.frameCount {
                captured.append(contentsOf: await withCommandLock {
                    await drainDownloadsLocked(expected: plan.frameCount - captured.count)
                })
            }
        } catch {
            thrown = error
        }

        // The return leg runs whatever happened — including cancellation. Leaving the lens parked
        // mid-bracket after an abort is the behaviour that makes a failed attempt expensive.
        if plan.returnToStart && stepsTaken > 0 {
            progress(FocusBracketProgress(phase: .returningFocus, framesCaptured: captured.count))
            _ = try? await nudgeFocusInner(plan.step.reversed,
                                           times: stepsTaken,
                                           settleSeconds: plan.settleSeconds)
        }

        }   // withLiveViewPaused
        }   // withTetherPaused

        // Whatever happened above — finished, failed, cancelled — leave nothing held on the camera.
        await withCommandLock { await cancelAutofocusLocked() }

        if startedLiveView { stopLiveView() }

        if let thrown {
            if thrown is CancellationError {
                progress(FocusBracketProgress(phase: .cancelled, framesCaptured: captured.count))
                // A cancelled bracket still hands back what it shot: a partial stack is often
                // still worth merging, and those frames are already on disk either way.
                return FocusBracketResult(frames: captured, directory: groupDirectory)
            }
            progress(FocusBracketProgress(phase: .cancelled, framesCaptured: captured.count))
            throw thrown
        }
        progress(FocusBracketProgress(phase: .finished, framesCaptured: captured.count))
        return FocusBracketResult(frames: captured, directory: groupDirectory)
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static let captureFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Tracks live gphoto2 child processes so app termination can kill them synchronously. Without
/// this, quitting the app reparents the `gphoto2 --shell` child to launchd with its PTP/IP session
/// still open — the camera stays claimed by a ghost until the orphan is manually killed, and
/// relaunching the app can't connect. Called from `applicationWillTerminate`, which cannot await
/// into the actor, hence a lock-protected registry outside actor isolation.
public final class ChildProcessRegistry: @unchecked Sendable {
    public static let shared = ChildProcessRegistry()
    private let lock = NSLock()
    private var processes: [Process] = []

    func register(_ process: Process) {
        lock.lock()
        processes.removeAll { !$0.isRunning }
        processes.append(process)
        lock.unlock()
    }

    public func terminateAll() {
        lock.lock()
        let live = processes
        processes.removeAll()
        lock.unlock()
        for process in live where process.isRunning {
            process.terminate()
        }
    }
}

/// Thread-safe text accumulator shared between the actor and the background pipe-reading
/// callback, deliberately kept outside `GPhotoSession`'s actor isolation.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock(); text += chunk; lock.unlock()
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }; return text
    }

    func clear() {
        lock.lock(); text = ""; lock.unlock()
    }
}

extension FileHandle {
    private static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/CanonTether.log")

    /// Rotate once the log passes this size: current → .old (replacing the previous .old), so at
    /// most ~2x this ever sits on disk. Without a cap the file grows for the life of the install
    /// (hit 50MB in one week of dev use).
    private static let logRotateBytes: UInt64 = 5_000_000

    /// Serialises every write. Writers reach this from the session actor, the main actor, and
    /// background watchdog tasks; each used to open its own handle and do a non-atomic
    /// seek-then-write, so interleaved writers landed at the same offset and destroyed each
    /// other's lines — in the one file used to diagnose connection problems, precisely when it is
    /// busiest. The same lock makes the size check and rotation atomic: two writers could
    /// otherwise both decide to rotate, and the second would delete the log the first had just
    /// rotated, taking the whole history with it.
    private static let logQueue = DispatchQueue(label: "com.canontether.log")

    static func appendLog(_ message: String) {
        let line = "[\(DateFormatter.logFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logQueue.async {
            let directory = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            // The throwing variants, deliberately: `seekToEndOfFile()`/`write(_:)` raise an
            // ObjC exception on a full disk or I/O error, which Swift cannot catch — logging a
            // line would terminate the app mid-shoot.
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            try? handle.close()
            guard size > logRotateBytes else { return }
            let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
    }
}
