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
    private static let candidatePaths = [
        "/usr/local/bin/gphoto2",   // Homebrew on Intel
        "/opt/homebrew/bin/gphoto2" // Homebrew on Apple Silicon
    ]

    /// Whether the gphoto2 CLI is installed — used to show a helpful setup prompt on first run.
    nonisolated static var isInstalled: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static let cameraWaitInterval: UInt64 = 1_000_000_000
    private static let connectRetryAttempts = 60
    /// Consecutive reachability-probe refusals before assuming the camera is re-pairing and
    /// dropping back to fresh-pairing (probe-free) connect behavior.
    private static let probeFailureLimit = 5
    private static let connectRetryDelay: UInt64 = 1_000_000_000
    // Kept tight: this is the granularity at which every shell command's completion is noticed,
    // including capture and download, so it's pure added latency on top of the camera's own work.
    private static let pollInterval: UInt64 = 20_000_000
    private static let readyTimeout: TimeInterval = 100 // covers the ~90s on-camera confirmation window
    // Measured live: the camera drops its PTP/IP connection after ~90s of inactivity
    // ("read PTPIPHeader: Connection reset by peer"). Ping well under that.
    private static let keepAliveCheckInterval: UInt64 = 5_000_000_000
    private static let keepAliveThreshold: TimeInterval = 25

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
    private var lastActivityAt = Date()
    private var keepAliveTask: Task<Void, Never>?
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

    // Serializes shell commands. Swift actors are re-entrant across `await` (and `sendCommand`
    // awaits while polling), so without this the background tether watcher and an app-shutter
    // capture could interleave their writes/reads on the one shell. Every `sendCommand` holds it.
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private var isEstablishing = false

    private func acquireCommandLock() async {
        while commandBusy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commandWaiters.append(continuation)
            }
        }
        commandBusy = true
    }

    private func releaseCommandLock() {
        commandBusy = false
        if !commandWaiters.isEmpty {
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

    /// The camera's current IP, from the ARP table. Uses `arp -an` (numeric) rather than `arp -a`:
    /// the latter does reverse-DNS on every entry and takes ~15s here, which was starving the whole
    /// discovery/reconnect loop; the numeric form returns in milliseconds. Since numeric output
    /// drops the "cwc…" hostname, the camera is identified by its Canon MAC OUI, with a link-local
    /// (169.254.x) peer as the fallback (EOS Utility wired-LAN self-assigns one).
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
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
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
                markActivity()
                // Keep-alive disabled for now — evidence suggests it may be *causing*
                // the camera to drop the session rather than preventing it (connection
                // survived a full 90s idle in a manual test with zero traffic, but died
                // within one keep-alive cycle in both app-driven tests). Needs more
                // investigation before re-enabling.
                // startKeepAlive()
                await optimizeCaptureTarget()
                return true
            }
            if snapshot.contains("Connection refused") || snapshot.contains("Timeout") || snapshot.contains("ERROR") {
                closeShell()
                return false
            }
            if !proc.isRunning {
                closeShell()
                return false
            }
            if Task.isCancelled {
                closeShell()
                return false
            }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        closeShell()
        return false
    }

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
        keepAliveTask?.cancel()
        keepAliveTask = nil
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
        process?.terminate()
        process = nil
        stdinHandle = nil
        markConnected(false)
    }

    private func markActivity() {
        lastActivityAt = Date()
    }

    /// The camera drops its PTP/IP connection after ~90s of inactivity, so while connected but
    /// otherwise idle (no real command in flight), periodically send a harmless `summary` to
    /// reset its idle timer.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepAliveCheckInterval)
                guard let self, !Task.isCancelled else { return }
                await self.keepAliveTick()
            }
        }
    }

    private func keepAliveTick() async {
        guard isConnected, Date().timeIntervalSince(lastActivityAt) > Self.keepAliveThreshold else { return }
        log("keep-alive ping")
        _ = try? await sendCommand("summary", doneMarkers: ["Manufacturer:", "ERROR", "*** Error"], timeout: 15)
    }

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
            // Network is the primary path here, and `networkCameraIP()` (an ARP lookup) is fast, so
            // check it every second — a camera that reappears after a reset is grabbed promptly.
            if var ip = networkCameraIP() {
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
                                hasEverConnected = false
                                continue
                            }
                            log("ptpip:\(ip) not answering — re-checking for a fresher address")
                            guard let freshIP = networkCameraIP() else { break }
                            ip = freshIP
                            try? await Task.sleep(nanoseconds: Self.connectRetryDelay)
                            continue
                        }
                        probeFailures = 0
                    }
                    log("attempt \(attempt)/\(Self.connectRetryAttempts): connecting to ptpip:\(ip)")
                    if await openShell(port: "ptpip:\(ip)") {
                        markConnected(true)
                        status("Connected")
                        return
                    }
                    // A failed attempt against a link-local address that's since gone stale (the
                    // camera re-paired under a new self-assigned IP mid-attempt) doesn't error out —
                    // it just hangs until openShell's own ~100s readyTimeout gives up. Re-resolve ARP
                    // before the next attempt so a fresh IP is picked up immediately instead of
                    // burning that same ~100s timeout again against an address that will never answer.
                    guard let freshIP = networkCameraIP() else { break }
                    if freshIP != ip {
                        log("camera moved to \(freshIP) mid-retry — reconnecting there instead")
                        ip = freshIP
                        continue
                    }
                    try? await Task.sleep(nanoseconds: Self.connectRetryDelay)
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
                if waited == 0 { status("Waiting for camera…") }
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
    private func sendCommand(_ command: String, doneMarkers: [String], timeout: TimeInterval, quiet: Bool = false) async throws -> String {
        await acquireCommandLock()
        defer { releaseCommandLock() }
        guard let stdinHandle, let process, process.isRunning else {
            throw GPhotoError.noCameraDetected
        }
        buffer.clear()
        markActivity()
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
            try Task.checkCancellation()
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

    private func tetherTick() async {
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
                "wait-event-and-download \(Self.tetherWaitWindow)",
                doneMarkers: ["gphoto2:", "*** Error"],
                timeout: 8,
                quiet: true
            )
            let files = CaptureOutput.savedFilenames(in: output)
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

    /// Reads all exposed camera settings in one pass over the open shell session.
    func fetchSettings() async throws -> [CameraSetting] {
        try await withReconnect { try await self.fetchSettingsOnce() }
    }

    private func fetchSettingsOnce() async throws -> [CameraSetting] {
        var results: [CameraSetting] = []
        for path in Self.settingPaths {
            let output = try await sendCommand(
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

    /// Applies a new value to a single setting, then re-reads it so the caller gets the camera's
    /// authoritative post-change state (the camera may snap the value to its nearest valid step).
    func updateSetting(_ path: String, to value: String) async throws -> CameraSetting? {
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

    static func appendLog(_ message: String) {
        let line = "[\(DateFormatter.logFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            let size = handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            if size > logRotateBytes {
                let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: logURL, to: old)
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}
