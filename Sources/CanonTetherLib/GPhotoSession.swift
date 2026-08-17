import Foundation
import Darwin
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
}

enum GPhotoError: LocalizedError {
    case binaryNotFound
    case noCameraDetected
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "gphoto2 not found. Install it with: brew install libgphoto2 gphoto2"
        case .noCameraDetected:
            return "No camera detected. Check the USB/network connection."
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
    /// Ceiling for the refusal back-off — long enough to stop hammering a camera that isn't
    /// listening, short enough that the reconnect still feels immediate once it is.
    private static let maxConnectRetryDelay: UInt64 = 8_000_000_000
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
        return networkCameraIP()
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
        if solicitCycle % Self.neighbourSweepEvery == 0 {
            candidates.append(contentsOf: neighbourCandidates())
        }
        for ip in candidates.prefix(Self.maxSolicitsPerCycle) {
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
        let pattern = Self.arpEntryPattern
        var linkLocalFallback: String?
        for line in arpOutput.split(separator: "\n") {
            let lineString = String(line)
            let nsLine = lineString as NSString
            guard let match = pattern.firstMatch(in: lineString, range: NSRange(location: 0, length: nsLine.length)) else {
                continue
            }
            let ip = nsLine.substring(with: match.range(at: 1))
            let mac = nsLine.substring(with: match.range(at: 2)).lowercased()
            if Self.canonOUIs.contains(where: { mac.hasPrefix($0) }) {
                return ip // unambiguously the Canon body
            }
            if ip.hasPrefix("169.254."), linkLocalFallback == nil {
                linkLocalFallback = ip
            }
        }
        return linkLocalFallback
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
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        } catch {
            // An unreachable capture folder (unplugged external drive) would otherwise wedge the
            // connect loop in a silent infinite retry with the pill stuck on "Connecting…".
            status("Capture folder unavailable — choose a new one in Preferences")
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--port", port, "--shell"]
        if let env = Self.environment(forBinary: binary) { proc.environment = env }
        // The interactive shell doesn't reliably honor --filename's full-path/pattern argument
        // the way the one-shot CLI does — downloads land as bare camera-side names (e.g.
        // capt0000.cr2) in the process's cwd, so pin that cwd to our target folder instead.
        proc.currentDirectoryURL = captureDirectory

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
    private func logConnectFailure(_ reason: String, _ snapshot: String) {
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
                    if hasEverConnected {
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
                                status("Camera is re-pairing — press “Start pairing devices” on the camera")
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
                    log("recv: \(delta.debugDescription)")
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
        startTetherWatch()
    }

    /// Points captures at a different project folder while running. The shell's working directory —
    /// where gphoto2 drops downloads — is fixed when the shell launches, so a live session is torn
    /// down here; the tether watch loop then relaunches it against the new folder within a second
    /// (or the next `connect()` does, if the camera wasn't attached). No files move: this only
    /// changes where *future* shots land, and the caller reloads the gallery from the new folder.
    func setCaptureDirectory(_ url: URL) {
        guard url != captureDirectory else { return }
        // Sweep the outgoing folder first: once `captureDirectory` moves, any preview frame left
        // in the old project is unreachable — later sweeps only look at the new folder, and an
        // in-flight tick's cleanup would target the wrong directory entirely.
        cleanUpPreviewFiles()
        captureDirectory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if process != nil { closeShell() }
    }

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

    /// While true the app sends the camera nothing at all, so the body stops reporting "busy" and
    /// its own dials and menus become usable again. The lock isn't a Canon policy about tethering
    /// — it's simply that this app polls `wait-event-and-download` roughly every 80ms and reads
    /// settings on top of that, leaving the body no idle moment to accept input.
    private var pollingPaused = false

    /// Hands the camera back to the photographer. Bounded rather than indefinite: the PTP/IP link
    /// is documented to drop after roughly 90s of silence, and a dropped link on this body costs a
    /// re-pair from its own screen — so silence is capped well short of that and the caller is
    /// told when it ends.
    func pausePolling() {
        guard !pollingPaused else { return }
        pollingPaused = true
        log("polling paused — camera controls handed back to the body")
        status("Camera control — adjust settings on the body")
    }

    func resumePolling() {
        guard pollingPaused else { return }
        pollingPaused = false
        log("polling resumed")
    }

    var isPollingPaused: Bool { pollingPaused }

    private func tetherTick() async {
        // The whole point of the pause: no commands, so the body isn't busy.
        guard !pollingPaused else { return }
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
    private func importDownloaded(_ downloadedName: String) -> URL? {
        // A live-view frame must never enter the gallery. This is reachable on an ordinary path:
        // pressing the shutter during live view cancels a `capture-preview` mid-flight, so the
        // camera's "Saving file as capture_preview.jpg" reply lands in the *next* command's
        // buffer, and the tether watch would then import a low-resolution preview as if it were
        // the shot — in front of a client. Deleted rather than merely skipped, since the cancelled
        // tick's own cleanup never ran.
        guard !downloadedName.hasPrefix(Self.previewFilenamePrefix) else {
            log("ignoring stray live-view frame \(downloadedName)")
            try? FileManager.default.removeItem(at: captureDirectory.appendingPathComponent(downloadedName))
            return nil
        }
        let downloadedURL = captureDirectory.appendingPathComponent(downloadedName)
        guard FileManager.default.fileExists(atPath: downloadedURL.path) else { return nil }
        let stamp = DateFormatter.captureFilenameFormatter.string(from: Date())
        var finalURL = captureDirectory.appendingPathComponent(stamp + "." + downloadedURL.pathExtension)
        // A burst can land two frames within the same one-second stamp — disambiguate.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = captureDirectory.appendingPathComponent(
                stamp + "-" + UUID().uuidString.prefix(4) + "." + downloadedURL.pathExtension)
        }
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: finalURL)
        } catch {
            return nil
        }
        log("downloaded \(finalURL.lastPathComponent)")
        captureContinuation?.yield(finalURL)
        return finalURL
    }

    // MARK: - Live view

    /// Filenames gphoto2 gives preview frames. They land in the shell's cwd (the capture folder)
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
            await self?.cleanUpPreviewFiles()
        }
    }

    /// Pulls one preview frame. Returns false if nothing was delivered, so the caller can back off
    /// instead of spinning against a camera that isn't producing frames.
    private func liveViewTick() async -> Bool {
        guard liveViewPauseDepth == 0, !pollingPaused else { return false }
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
            let url = captureDirectory.appendingPathComponent(name)
            // Always remove it: a preview frame is not a capture, and leaving it in the capture
            // folder both pollutes the gallery and makes the next frame hit an overwrite prompt.
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
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: captureDirectory.path) else { return }
        for name in names where name.hasPrefix(Self.previewFilenamePrefix) {
            try? FileManager.default.removeItem(at: captureDirectory.appendingPathComponent(name))
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
                let output = try await sendCommandLocked(
                    "get-config \(path)",
                    doneMarkers: ["END", "*** Error", "ERROR"],
                    timeout: 15
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
        try await withReconnect { try await self.triggerCaptureOnce() }
    }

    private func triggerCaptureOnce() async throws {
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
                for name in names { importDownloaded(name) }
                return
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
