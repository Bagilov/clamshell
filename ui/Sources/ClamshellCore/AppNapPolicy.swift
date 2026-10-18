import Foundation

/// App Nap options for the menu bar app.
///
/// The app is an accessory whose timers drive the visible countdown, so it must
/// opt out of App Nap. The choice of option matters: plain `.userInitiated`
/// also sets the `idleSystemSleepDisabled` bit, which holds a power assertion
/// that prevents system sleep for as long as the app runs — the exact opposite
/// of what this tool is for. `userInitiatedAllowingIdleSystemSleep` keeps the
/// timers running while still letting the Mac sleep normally.
public enum AppNapPolicy {
    /// Options to pass to `ProcessInfo.beginActivity`.
    public static let activityOptions: ProcessInfo.ActivityOptions =
        .userInitiatedAllowingIdleSystemSleep

    /// Whether the chosen options would block idle system sleep.
    ///
    /// Exposed so a test can assert the policy never inverts tool behaviour.
    public static var preventsIdleSystemSleep: Bool {
        activityOptions.contains(.idleSystemSleepDisabled)
    }
}
