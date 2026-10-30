import AppKit
import ClamshellCore

/// Update actions: check for a newer release, and install one on consent.
///
/// Split from `MenuBarController` for the file-length rule: the consent flow
/// and relaunch are self-contained and read better on their own.
@MainActor
extension MenuBarController {
    /// Run an immediate check, reporting the outcome for a manual request.
    ///
    /// Reporting is limited to a manual check: a periodic check that fails
    /// because the machine is offline must not raise an alert.
    @objc func checkForUpdates() {
        updates.checkNow { status in
            guard status.failed else { return }
            Prompt.invalid(
                title: "Could Not Check for Updates",
                message: status.error ?? "The release list could not be reached."
            )
        }
    }

    /// Ask for consent, then install the known release and offer a restart.
    @objc func installUpdate() {
        guard let release = updates.availableRelease else { return }
        let message = UpdatePresentation.consentMessage(for: release, current: About.version)
        guard Prompt.confirmUpdate(version: release.version, message: message) else {
            // A cancelled install may be offered again next launch.
            updates.clearOffer()
            return
        }
        install(release)
    }

    /// Run the install off the main thread, then offer to relaunch on success.
    private func install(_ release: ReleaseInfo) {
        guard !isWorking else { return }
        isWorking = true
        renderBusy()
        Task { @MainActor in
            defer { isWorking = false }
            do {
                _ = try await Task.detached(priority: .utility) {
                    try self.command.installUpdate()
                }.value
            } catch {
                Prompt.failure(error)
                await refreshStatus()
                render()
                return
            }
            await refreshStatus()
            render()
            if Prompt.offerRelaunch(version: release.version) {
                relaunch()
            }
        }
    }

    /// Replace the running process with a fresh copy of the new binary.
    ///
    /// The bundle on disk changed beneath the running process, so relaunching is
    /// the only way the new code takes effect. The session watcher is independent
    /// of the app, so an active keep-awake session is unaffected.
    private func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            // Running from a build directory or unbundled: reopening by path
            // would start a second instance of the same old binary.
            Prompt.invalid(
                title: "Restart Clamshell",
                message: "Quit and reopen Clamshell to use the new version."
            )
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
