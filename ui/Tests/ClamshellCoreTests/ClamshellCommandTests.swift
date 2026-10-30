import ClamshellCore
import Foundation
import Testing

/// Serialized: every test here spawns a child process and waits on a timeout, so
/// running them in parallel makes each one compete for the same CPU budget and
/// pushes the timing assertions over their bounds on a loaded CI runner.
@Suite("ClamshellCommand", .serialized)
struct ClamshellCommandTests {
    @Test("Prefers the user-owned launcher when present")
    func resolveLauncherPrefersLocal() {
        let local = ClamshellCommand.localPath
        if FileManager.default.isExecutableFile(atPath: local) {
            #expect(ClamshellCommand.resolveLauncher() == local)
        } else {
            #expect(ClamshellCommand.resolveLauncher() == ClamshellCommand.defaultPath)
        }
    }

    @Test("Local launcher lives outside TCC-protected folders")
    func localLauncherIsNotUnderDocuments() {
        let path = ClamshellCommand.localPath
        #expect(path.contains("Library/Application Support"))
        #expect(!path.contains("/Documents"))
    }

    @Test("Reports not installed for a missing path")
    func reportsNotInstalledForMissingPath() {
        let command = ClamshellCommand(path: "/nonexistent/clamshell", timeout: 1)
        #expect(!command.isInstalled)
        #expect(throws: ClamshellError.self) {
            _ = try command.run(["status"])
        }
    }

    @Test("Exposes the resolved launcher path for error messages")
    func exposesResolvedLauncherPath() {
        let custom = "/custom/path/clamshell"
        let command = ClamshellCommand(path: custom, timeout: 1)
        #expect(command.launcherPath == custom)
    }

    @Test("Missing-launcher error names the resolved path")
    func missingLauncherErrorNamesResolvedPath() {
        let custom = "/custom/path/clamshell"
        let command = ClamshellCommand(path: custom, timeout: 1)
        do {
            _ = try command.run(["status"])
            Issue.record("expected the run to throw")
        } catch let error as ClamshellError {
            #expect(error == ClamshellError.cliNotFound(custom))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Captures output far larger than the pipe buffer")
    func capturesOutputLargerThanPipeBuffer() throws {
        // A read-after-exit implementation deadlocks here: macOS pipe buffers
        // hold about 64 KiB and the child blocks on write once they are full.
        let script = try makeScript("""
        #!/bin/sh
        i=0
        while [ "$i" -lt 4000 ]; do
            printf 'abcdefghijklmnopqrstuvwxyz0123456789'
            i=$((i + 1))
        done
        """)
        let command = ClamshellCommand(path: script.path, timeout: 30)
        let output = try command.run([])
        #expect(output.count == 4000 * 36)
    }

    /// Seconds a hung-child test allows before the run must give up.
    ///
    /// The run's own timeout is this minus the terminate grace, and the margin
    /// absorbs a loaded CI runner: a 1s budget was flaky whenever several of
    /// these spawned children competed for the same CPU.
    private static let hungTimeout: TimeInterval = 3

    @Test("Times out and returns when the child never exits")
    func timesOutOnHungChild() throws {
        // `exec` replaces the shell with `sleep`, so the process the parent
        // signalled is the one that exits: no shell wrapper lingers to hold the
        // pipes open.
        let script = try makeScript("""
        #!/bin/sh
        exec sleep 600
        """)
        let command = ClamshellCommand(path: script.path, timeout: Self.hungTimeout)
        let start = Date()
        do {
            _ = try command.run([])
            Issue.record("expected the run to time out")
        } catch let error as ClamshellError {
            #expect(error == ClamshellError.commandFailed(
                command: "clamshell",
                detail: "timed out after \(Int(Self.hungTimeout))s"
            ))
        }
        #expect(Date().timeIntervalSince(start) < Self.hungTimeout + 20)
    }

    @Test("Times out even when a descendant keeps the pipe open")
    func timesOutWithSurvivingDescendant() throws {
        // The child exits on SIGTERM, but the background grandchild inherits
        // stdout and outlives it, so EOF never arrives on the pipe. The run must
        // still return on the timeout instead of blocking on the readers.
        let script = try makeScript("""
        #!/bin/sh
        sh -c 'trap "" TERM; sleep 600' &
        exec sleep 600
        """)
        let command = ClamshellCommand(path: script.path, timeout: Self.hungTimeout)
        let start = Date()
        do {
            _ = try command.run([])
            Issue.record("expected the run to time out")
        } catch let error as ClamshellError {
            #expect(error == ClamshellError.commandFailed(
                command: "clamshell",
                detail: "timed out after \(Int(Self.hungTimeout))s"
            ))
        }
        #expect(Date().timeIntervalSince(start) < Self.hungTimeout + 30)
    }

    @Test("Keeps the child's stderr in the timeout message")
    func timeoutIncludesStderr() throws {
        // The whole point of draining the pipes is to surface why the CLI hung,
        // so its diagnostics have to reach the error, not just "timed out".
        let script = try makeScript("""
        #!/bin/sh
        echo 'Traceback: something exploded' >&2
        exec sleep 600
        """)
        let command = ClamshellCommand(path: script.path, timeout: Self.hungTimeout)
        do {
            _ = try command.run([])
            Issue.record("expected the run to time out")
        } catch let error as ClamshellError {
            let detail = "\(error)"
            #expect(detail.contains("timed out after \(Int(Self.hungTimeout))s"))
            #expect(detail.contains("Traceback: something exploded"))
        }
    }

    @Test("Truncates a very large error body instead of carrying it whole")
    func truncatesHugeErrorBody() throws {
        // A hung CLI can dump far more than a dialog can show; the error must
        // stay bounded while still carrying the head of the output.
        let script = try makeScript("""
        #!/bin/sh
        head -c 200000 /dev/zero | tr '\\0' 'x' >&2
        exec sleep 600
        """)
        let command = ClamshellCommand(path: script.path, timeout: Self.hungTimeout)
        do {
            _ = try command.run([])
            Issue.record("expected the run to time out")
        } catch let error as ClamshellError {
            let detail = "\(error)"
            #expect(detail.contains("(truncated)"))
            #expect(detail.count < 5000)
        }
    }

    /// Write an executable shell script into a unique temporary directory.
    private func makeScript(_ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clamshell-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("cli")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script
    }
}
