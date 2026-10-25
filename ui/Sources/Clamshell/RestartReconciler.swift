import ClamshellCore
import Foundation

/// Re-aligns a leftover auto-restore timer once, shortly after app launch.
///
/// The watcher is a transient `launchctl` job, so a reboot (or a crash) can
/// leave `state.plist` behind with nothing scheduled: sleep stays disabled and
/// no trigger will ever fire. The CLI owns the reconciliation logic; this only
/// decides when to ask and keeps the work off the main thread.
struct RestartReconciler {
    private let command: ClamshellCommand

    init(command: ClamshellCommand) {
        self.command = command
    }

    /// Ask the CLI to reconcile, unless it is not installed or already running.
    ///
    /// Failures are deliberately silent: reconciliation is a repair, and the
    /// menu already reflects whatever `status` reports, so an alert here would
    /// be noise on a machine that simply has no leftover session.
    func run() {
        guard command.isInstalled else { return }
        Task.detached(priority: .utility) { [command] in
            try? command.reconcile()
        }
    }
}
