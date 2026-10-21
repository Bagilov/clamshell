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
            throw ClamshellError.commandFailed(
                command: joined(arguments),
                detail: "timed out after \(Int(timeout))s"
            )
        }
        Self.finishReading(captures, readers: readers)

        let out = captures[0].text
        let err = captures[1].text
        guard process.terminationStatus == 0 else {
            throw ClamshellError.commandFailed(
                command: joined(arguments),
                detail: err.isEmpty ? out : err
            )
        }
        return out
    }

    /// Read the current status reported by the CLI.
    public func status() throws -> ClamshellStatus {
        let output = try run(["status"])
        guard let status = StatusParser.parse(output) else {
            throw ClamshellError.commandFailed(command: "status", detail: "unrecognised output")
        }
        return status
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

    private func joined(_ arguments: [String]) -> String {
        (["clamshell"] + arguments).joined(separator: " ")
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

/// Drains one pipe to EOF on a background queue.
///
/// Keeping the reader off the caller's thread is what makes large output safe:
/// the child never blocks on a full pipe buffer while the parent waits for exit.
///
/// Reading uses `poll` with a short timeout instead of a blocking read, so
/// `stop()` can end the loop even when a surviving descendant still holds the
/// write end open and EOF never arrives.
private final class PipeCapture: @unchecked Sendable {
    /// How long `poll` blocks before the stop flag is checked again.
    private static let pollInterval: Int32 = 200

    private let descriptor: Int32
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false

    init(_ pipe: Pipe) {
        descriptor = pipe.fileHandleForReading.fileDescriptor
    }

    /// Read until the write end closes or `stop()` is called.
    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !isStopped {
            var target = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&target, 1, Self.pollInterval)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            if ready == 0 {
                continue
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                lock.lock()
                data.append(contentsOf: buffer[0 ..< count])
                lock.unlock()
            } else if count == 0 {
                return
            } else if errno != EAGAIN, errno != EINTR {
                return
            }
        }
    }

    /// Ask `drain()` to return without waiting for EOF.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Captured output, trimmed of surrounding whitespace and newlines.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let decoded = String(bytes: data, encoding: .utf8) ?? ""
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
