import ClamshellCore
import Foundation

/// Watches the release list in the background and reports what it finds.
///
/// Owns the policy the app applies, none of which belongs in the CLI:
///
/// * checks are **periodic but rare** (once a day), so the app is not a polling
///   client and a fresh install does not hit the network on first launch;
/// * a **failed check is silent**: an offline laptop must not raise an alert;
/// * the result is only **reported**; installing needs the user's consent, which
///   the controller asks for and this type never does on its own.
@MainActor
final class UpdateChecker {
    private let command: ClamshellCommand
    private let interval: TimeInterval
    private var timer: Timer?

    /// Whether the user has been offered the currently known release already, so
    /// a repeated check does not re-raise the same consent dialog.
    private var offeredVersion: String?

    /// The most recent result, or `nil` before the first completed check.
    private(set) var status: UpdateStatus?

    /// Called on the main actor after every completed check.
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - command: The CLI wrapper used to check for updates.
    ///   - interval: Minimum time between automatic checks.
    init(command: ClamshellCommand, interval: TimeInterval = 24 * 60 * 60) {
        self.command = command
        self.interval = interval
    }

    /// The release the app should offer to install, if any.
    var availableRelease: ReleaseInfo? {
        status?.release
    }

    /// Start the recurring check.
    ///
    /// The first check waits one interval: a just-launched app should not reach
    /// the network, and the CLI's own day-long cache would answer from disk
    /// anyway. `checkNow` is available for the explicit menu action.
    func start() {
        guard command.isInstalled else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    /// Run a check now, bypassing the CLI's throttle.
    ///
    /// - Parameter completion: Called on the main actor with the result, so a
    ///   manual check can report a failure while a periodic one stays silent.
    func checkNow(completion: ((UpdateStatus) -> Void)? = nil) {
        check(force: true, completion: completion)
    }

    /// Ask the CLI and publish the result, unless it is not installed.
    ///
    /// Errors are swallowed deliberately: the CLI already reports a failed check
    /// as data, and a hard failure (missing launcher) is what `status` surfaces.
    func check(force: Bool, completion: ((UpdateStatus) -> Void)? = nil) {
        guard command.isInstalled else { return }
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { [command] in
                try? command.updateStatus(force: force)
            }.value
            guard let result else { return }
            status = result
            onChange?()
            completion?(result)
        }
    }

    /// Whether a release should trigger the one-time offer, exactly once.
    ///
    /// Keeps the consent prompt from reappearing on every periodic check while
    /// still allowing a later, newer release to be offered afresh.
    func shouldOffer(_ release: ReleaseInfo) -> Bool {
        guard offeredVersion != release.version else { return false }
        offeredVersion = release.version
        return true
    }

    /// Forget the offered version, so a cancelled install can be offered again.
    func clearOffer() {
        offeredVersion = nil
    }
}
