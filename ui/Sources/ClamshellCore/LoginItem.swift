import Foundation
import ServiceManagement

/// Wraps the login-item registration that starts the app at sign-in.
///
/// The app is an accessory with no Dock icon, so without a login item a pending
/// keep-awake session would be left unmanaged after a reboot: the transient
/// watcher job is gone and nothing re-arms it. Registering as a login item is
/// exactly the supported way to bring the app back, and it keeps the reconcile
/// step meaningful.
///
/// `SMAppService.mainApp` is used rather than a helper bundle: the app itself is
/// what needs to run, and this needs no privileged install and no separate
/// launch agent. The status is read back from the system instead of being
/// remembered locally, so the toggle reflects what macOS will actually do.
public struct LoginItem: Sendable {
    /// Why a login-item change could not be made.
    public enum LoginItemError: LocalizedError, Equatable {
        case notBundled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                "Launch at Login needs the installed app bundle."
            case let .failed(detail):
                "Could not change the login item: \(detail)"
            }
        }
    }

    public init() {}

    /// Whether the app is currently registered to launch at sign-in.
    ///
    /// Any status other than `.notRegistered` counts as enabled, so a pending
    /// `.requiresApproval` state is reported as on: the registration exists and
    /// macOS will honour it once the user approves in System Settings.
    public var isEnabled: Bool {
        Self.mapStatus(SMAppService.mainApp.status)
    }

    /// Whether macOS is holding the registration until the user approves it.
    ///
    /// Read from the system rather than remembered, so the explanation is only
    /// shown while it actually applies.
    public static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Whether the current process can register a login item at all.
    ///
    /// Registration requires a real bundle with an identifier; a bare binary run
    /// from a build directory has none, so the toggle is hidden there instead of
    /// failing on every click.
    public var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Register or unregister the app as a login item.
    ///
    /// - Parameter enabled: `true` to launch at sign-in, `false` to stop.
    /// - Throws: `LoginItemError` when the change is unavailable or rejected.
    public func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LoginItemError.notBundled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
    }

    /// Map a system status onto the enabled/disabled pair the menu shows.
    ///
    /// Kept as a pure function so the mapping is tested without touching the
    /// real login item, which would change the developer's machine.
    public static func mapStatus(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound:
            false
        @unknown default:
            false
        }
    }
}
