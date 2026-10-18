import ClamshellCore
import Foundation
import Testing

@Suite("AppNapPolicy")
struct AppNapPolicyTests {
    @Test("Never blocks idle system sleep")
    func neverBlocksIdleSystemSleep() {
        // Regression guard: plain `.userInitiated` sets the
        // idleSystemSleepDisabled bit and held a power assertion while the app
        // ran, so the Mac never slept even after clamshell mode was turned off.
        #expect(AppNapPolicy.preventsIdleSystemSleep == false)
    }

    @Test("Still opts out of App Nap")
    func stillOptsOutOfAppNap() {
        // The countdown must keep ticking, so the option cannot be an empty set.
        // `userInitiatedAllowingIdleSystemSleep` is `userInitiated` minus the
        // idle-sleep bit, so it is a non-empty subset rather than a superset.
        #expect(!AppNapPolicy.activityOptions.isEmpty)
        #expect(!AppNapPolicy.activityOptions.contains(.idleSystemSleepDisabled))
    }

    @Test("Accepts an activity assertion without error")
    func startsAndEndsCleanly() {
        let token = ProcessInfo.processInfo.beginActivity(
            options: AppNapPolicy.activityOptions,
            reason: "unit test"
        )
        ProcessInfo.processInfo.endActivity(token)
    }
}
