import ClamshellCore
import Foundation
import Testing

@Suite("ClamshellCommand")
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
}
