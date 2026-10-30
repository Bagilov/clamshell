import Foundation

/// Errors raised while talking to the `clamshell` CLI.
public enum ClamshellError: LocalizedError, Equatable {
    case cliNotFound(String)
    case commandFailed(command: String, detail: String)
    case notMacOS

    public var errorDescription: String? {
        switch self {
        case let .cliNotFound(path):
            "The clamshell command was not found at \(path)."
        case let .commandFailed(command, detail):
            "`\(command)` failed: \(detail)"
        case .notMacOS:
            "Clamshell only supports macOS."
        }
    }
}

/// Parses `clamshell status` output into a `ClamshellStatus`.
public enum StatusParser {
    /// Parse the text printed by `clamshell status`.
    ///
    /// Returns `nil` when the text does not contain a recognisable state line,
    /// so callers can distinguish "not installed" from "sleep is enabled".
    public static func parse(_ output: String) -> ClamshellStatus? {
        var isDisabled: Bool?
        var remaining: Int?
        var floor: Int?
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Sleep is DISABLED") {
                isDisabled = true
            } else if text.hasPrefix("Sleep is enabled") {
                isDisabled = false
            } else if let value = remainingSeconds(from: text) {
                remaining = value
            } else if let value = batteryFloor(from: text) {
                floor = value
            }
        }
        guard let isDisabled else { return nil }
        return ClamshellStatus(
            isDisabled: isDisabled,
            remainingSeconds: remaining,
            batteryFloor: floor
        )
    }

    private static func remainingSeconds(from line: String) -> Int? {
        let prefix = "Auto-restore in "
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return DurationFormat.seconds(fromText: value)
    }

    private static func batteryFloor(from line: String) -> Int? {
        let prefix = "Auto-restore at "
        let suffix = "% battery."
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let value = line.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(value)
    }
}

/// Runs the `clamshell` CLI out of process.
///
/// The CLI performs all privileged work through its own sudoers-scoped helper,
/// so this type never invokes `sudo` itself.
public struct ClamshellCommand: Sendable {
    /// Path of the CLI launcher installed by `clamshell install`.
    public static let defaultPath = "/usr/local/bin/clamshell"

    /// User-owned launcher, readable by the app without TCC approval.
    public static let localPath =
        NSHomeDirectory() + "/Library/Application Support/clamshell/clamshell"

    private let path: String
    private let timeout: TimeInterval

    public init(path: String? = nil, timeout: TimeInterval = 30) {
        self.path = path ?? ClamshellCommand.resolveLauncher()
        self.timeout = timeout
    }

    /// Pick the first launcher that exists, preferring the user-owned copy.
    ///
    /// The copy in `~/Library/Application Support` is readable from the
    /// sandboxed app, while the `/usr/local/bin` launcher only appears after
    /// the privileged install is approved.
    public static func resolveLauncher() -> String {
        let existing = [localPath, defaultPath].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        return existing ?? defaultPath
    }

    /// Whether the CLI launcher exists and is executable.
    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The launcher path this command will actually invoke.
    public var launcherPath: String {
        path
    }

    /// How long a terminated child may take to exit before it is killed.
    private static let terminateGrace: TimeInterval = 5

    /// Run the CLI with the given arguments and return its stdout.
    ///
    /// Both pipes are drained on background queues while the child runs. A macOS
    /// pipe buffer is about 64 KiB, so reading only after exit deadlocks as soon
    /// as the CLI writes more than that — a Python traceback on stderr is enough.
    /// Waiting is bounded by `timeout`, after which the child is terminated and,
    /// if it still refuses to exit, killed.
    ///
    /// - Parameter arguments: Subcommand and options, for example `["on", "--for", "1h"]`.
    /// - Returns: The trimmed standard output.
    /// - Throws: `ClamshellError` when the CLI is missing, times out or exits non-zero.
    public func run(_ arguments: [String]) throws -> String {
        guard isInstalled else { throw ClamshellError.cliNotFound(path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        try process.run()

        // Start draining only after a successful spawn, so a launch failure
        // cannot leave reader threads blocked on a pipe nobody will close.
        let captures = [PipeCapture(stdout), PipeCapture(stderr)]
        let readers = DispatchGroup()
        for capture in captures {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                capture.drain()
                readers.leave()
            }
        }

        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + Self.terminateGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exitSignal.wait()
            }
            Self.finishReading(captures, readers: readers)
            // Whatever the child printed before hanging is the whole point of
            // draining the pipes, so keep it in the timeout detail.
            let partial = Self.excerpt(captures[1].text)
            let base = "timed out after \(Int(timeout))s"
            throw ClamshellError.commandFailed(
                command: joined(arguments),
                detail: partial.isEmpty ? base : "\(base): \(partial)"
            )
        }
        Self.finishReading(captures, readers: readers)

        let out = captures[0].text
        let err = captures[1].text
        guard process.terminationStatus == 0 else {
            throw ClamshellError.commandFailed(
                command: joined(arguments),
                detail: Self.excerpt(err.isEmpty ? out : err)
            )
        }
        return out
    }

    /// Read the current status reported by the CLI.
    ///
    /// Prefers the `--json` form, which does not depend on the wording of the
    /// human-readable output. Falls back to the text parser for an older CLI
    /// that predates the flag, so an app update cannot break a pending session.
    public func status() throws -> ClamshellStatus {
        if let status = try? jsonStatus() {
            return status
        }
        let output = try run(["status"])
        guard let status = StatusParser.parse(output) else {
            throw ClamshellError.commandFailed(command: "status", detail: "unrecognised output")
        }
        return status
    }

    /// Decode `clamshell status --json`.
    private func jsonStatus() throws -> ClamshellStatus {
        let output = try run(["status", "--json"])
        guard let data = output.data(using: .utf8) else {
            throw ClamshellError.commandFailed(command: "status", detail: "unreadable output")
        }
        return try JSONDecoder().decode(ClamshellStatus.self, from: data)
    }

    /// Re-align a leftover timer with reality, called once at app launch.
    ///
    /// The watcher is a transient job, so after a reboot sleep could be left
    /// disabled with nothing scheduled. Failure is not fatal: the menu still
    /// shows the state reported by `status`.
    public func reconcile() throws {
        _ = try run(["reconcile"])
    }

    /// Check for a newer release without installing anything.
    ///
    /// The CLI throttles the request to once a day unless `force` is set, so a
    /// periodic call is cheap. A failed check is not an error: the decoded
    /// status carries the reason and the rest of the app keeps working.
    ///
    /// - Parameter force: Bypass the throttle and query the network now.
    /// - Returns: The decoded update status.
    /// - Throws: `ClamshellError` when the CLI is missing or returns unusable output.
    public func updateStatus(force: Bool = false) throws -> UpdateStatus {
        var arguments = ["update", "--json"]
        if force {
            arguments.append("--force")
        }
        let output = try run(arguments)
        guard let data = output.data(using: .utf8) else {
            throw ClamshellError.commandFailed(command: "update", detail: "unreadable output")
        }
        return try JSONDecoder().decode(UpdateStatus.self, from: data)
    }

    /// Install the release the last check found.
    ///
    /// The CLI downloads the installer, verifies its checksum and asks for one
    /// administrator approval. This is the only call that changes the system, so
    /// the app only makes it after an explicit user confirmation.
    ///
    /// - Returns: The textual confirmation printed by the CLI.
    /// - Throws: `ClamshellError` when the download, verification or install fails.
    public func installUpdate() throws -> String {
        try run(["update", "--install"])
    }

    /// Disable sleep, optionally scheduling automatic restore triggers.
    ///
    /// - Parameters:
    ///   - duration: Time limit, or `.indefinite` for no time limit.
    ///   - floor: Battery level that stops the session, or `.off`.
    ///   - darken: Whether to blank the display immediately.
    public func enable(
        duration: DurationOption,
        floor: BatteryFloor = .off,
        darken: Bool = false
    ) throws {
        try enable(span: duration.span, floorPercent: floor.percent, darken: darken)
    }

    /// Build the `clamshell on` argument list for the given options.
    ///
    /// Kept separate from `enable` so the argument mapping is unit-testable
    /// without spawning the CLI.
    ///
    /// - Parameters:
    ///   - span: CLI span such as `45m`, or `nil` for no time limit.
    ///   - floorPercent: Battery level that stops the session, or `nil`.
    ///   - darken: Whether to blank the display immediately.
    /// - Returns: The arguments to pass to the CLI, starting with `on`.
    public static func startArguments(
        span: String?,
        floorPercent: Int?,
        darken: Bool
    ) -> [String] {
        var arguments = ["on"]
        if let span {
            arguments.append(contentsOf: ["--for", span])
        }
        if let floorPercent {
            arguments.append(contentsOf: ["--battery", String(floorPercent)])
        }
        if darken {
            arguments.append("--darken")
        }
        return arguments
    }

    /// Disable sleep using a raw CLI span, so a running session can be
    /// re-applied with its remaining time instead of restarting at full length.
    ///
    /// - Parameters:
    ///   - span: CLI span such as `45m`, or `nil` for no time limit.
    ///   - floorPercent: Battery level that stops the session, or `nil`.
    ///   - darken: Whether to blank the display immediately.
    public func enable(
        span: String?,
        floorPercent: Int? = nil,
        darken: Bool = false
    ) throws {
        let arguments = ClamshellCommand.startArguments(
            span: span,
            floorPercent: floorPercent,
            darken: darken
        )
        _ = try run(arguments)
    }

    /// Restore normal sleep behaviour.
    public func disable() throws {
        _ = try run(["off"])
    }

    /// Blank the display now, for a session that is already running.
    ///
    /// `--darken` only takes effect when a session starts, so toggling it mid-run
    /// would otherwise change the menu without changing anything on screen.
    /// Delegates to the CLI, which keeps this app off `pmset` directly.
    public func darkenNow() throws {
        _ = try run(["darken"])
    }

    private func joined(_ arguments: [String]) -> String {
        (["clamshell"] + arguments).joined(separator: " ")
    }

    /// Longest child output kept in an error message.
    private static let detailLimit = 2000

    /// Trim child output to a length that is useful in an alert.
    ///
    /// A hung or verbose CLI can emit far more than fits a dialog or a log line,
    /// so only the head is kept and the truncation is made visible.
    private static func excerpt(_ text: String) -> String {
        guard text.count > detailLimit else { return text }
        return String(text.prefix(detailLimit)) + "… (truncated)"
    }

    /// Wait for the reader queues, forcing `drain()` to stop if they stall.
    ///
    /// A terminated child can leave a descendant holding the pipe's write end,
    /// so EOF may never arrive. Stopping the readers keeps `run`'s time bound
    /// absolute instead of waiting on a pipe nobody will close.
    private static func finishReading(_ captures: [PipeCapture], readers: DispatchGroup) {
        guard readers.wait(timeout: .now() + terminateGrace) == .timedOut else { return }
        for capture in captures {
            capture.stop()
        }
        _ = readers.wait(timeout: .now() + terminateGrace)
    }
}
