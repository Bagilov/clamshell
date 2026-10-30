import AppKit
import ClamshellCore

/// App-level menu actions: the login-item toggle and uninstall.
///
/// Split from `MenuBarController` for the file-length rule: both actions manage
/// the installation itself rather than a keep-awake session, so they read better
/// together and apart from the session wiring.
@MainActor
extension MenuBarController {
    /// Whether the login item can be changed, for the menu row.
    var canLaunchAtLogin: Bool {
        loginItemService.isAvailable
    }

    /// Whether the app is currently registered to start at sign-in.
    var launchAtLogin: Bool {
        loginItemService.isEnabled
    }

    /// Register or unregister the app as a login item.
    ///
    /// The state is read back from `SMAppService` through `LoginItem` after the
    /// change and the menu is rebuilt, so a rejected change cannot leave the tick
    /// claiming something macOS will not do. A registration macOS is still
    /// holding for approval is explained, because it reads as enabled but does
    /// nothing until the user confirms it in System Settings.
    @objc func toggleLaunchAtLogin() {
        let wanted = !loginItemService.isEnabled
        do {
            try loginItemService.setEnabled(wanted)
        } catch {
            Prompt.failure(error)
            return
        }
        rebuildMenu()
        if wanted, LoginItem.needsApproval {
            Prompt.invalid(
                title: "Approval Needed",
                message: "Allow Clamshell in System Settings → General → Login Items "
                    + "to finish enabling Launch at Login."
            )
        }
    }

    /// Ask for confirmation, then remove the whole installation.
    ///
    /// Uninstalling deletes the root-owned helper, the sudoers rule and the CLI,
    /// so it always goes through an explicit confirmation that names what is
    /// removed. The app bundle itself is left in place, and the alert says how to
    /// remove it. The login item is dropped first, so it cannot relaunch an app
    /// whose command line no longer exists.
    @objc func uninstall() {
        guard command.isInstalled else {
            Prompt.invalid(
                title: "Clamshell Not Installed",
                message: "The clamshell command was already removed."
            )
            return
        }
        // A busy guard and a declined confirmation are the same outcome: stop
        // before anything destructive, so they share one early exit.
        guard !isWorking, Prompt.confirmUninstall() else { return }
        isWorking = true
        renderBusy()
        Task { @MainActor in
            defer { isWorking = false }
            try? self.loginItemService.setEnabled(false)
            do {
                _ = try await Task.detached(priority: .utility) {
                    try self.command.uninstall()
                }.value
            } catch {
                Prompt.failure(error)
                await refreshStatus()
                render()
                return
            }
            await refreshStatus()
            render()
            Prompt.invalid(
                title: "Clamshell Uninstalled",
                message: "The helper, sudoers rule and command line were removed. "
                    + "Drag Clamshell.app to the Trash to remove the app itself."
            )
        }
    }
}
