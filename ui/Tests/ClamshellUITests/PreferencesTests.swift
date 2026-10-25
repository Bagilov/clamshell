@testable import Clamshell
import ClamshellCore
import Foundation
import Testing

/// Each test gets its own `UserDefaults` suite so nothing leaks into the real
/// app domain or between tests.
@Suite("Preferences")
struct PreferencesTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "clamshell-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Defaults are off and indefinite before anything is saved")
    func emptyDefaults() throws {
        let preferences = try Preferences(defaults: freshDefaults())
        #expect(preferences.batteryFloor == .off)
        #expect(preferences.duration == .indefinite)
        #expect(preferences.customSpan == nil)
        #expect(preferences.darken == false)
    }

    @Test("A floor survives a round trip")
    func floorRoundTrip() throws {
        let defaults = try freshDefaults()
        let first = Preferences(defaults: defaults)
        first.batteryFloor = try #require(BatteryFloor.preset(30))

        let second = Preferences(defaults: defaults)
        #expect(second.batteryFloor == BatteryFloor.preset(30))
    }

    @Test("Turning the floor off clears the stored value")
    func floorOffClears() throws {
        let defaults = try freshDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.batteryFloor = try #require(BatteryFloor.preset(30))
        preferences.batteryFloor = .off
        #expect(Preferences(defaults: defaults).batteryFloor == .off)
    }

    @Test("A duration preset survives a round trip")
    func durationRoundTrip() throws {
        let defaults = try freshDefaults()
        Preferences(defaults: defaults).duration = .hours2
        #expect(Preferences(defaults: defaults).duration == .hours2)
    }

    @Test("A custom span survives a round trip and can be cleared")
    func customSpanRoundTrip() throws {
        let defaults = try freshDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.customSpan = "1h45m"
        #expect(Preferences(defaults: defaults).customSpan == "1h45m")
        preferences.customSpan = nil
        #expect(Preferences(defaults: defaults).customSpan == nil)
    }

    @Test("The darken toggle survives a round trip")
    func darkenRoundTrip() throws {
        let defaults = try freshDefaults()
        Preferences(defaults: defaults).darken = true
        #expect(Preferences(defaults: defaults).darken)
    }

    @Test("Unreadable stored values fall back instead of crashing")
    func corruptValuesFallBack() throws {
        let defaults = try freshDefaults()
        defaults.set("not-a-number", forKey: "duration")
        defaults.set(999, forKey: "batteryFloor")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.duration == .indefinite)
        // 999 is outside the valid range, so it is ignored rather than honoured.
        #expect(preferences.batteryFloor == .off)
    }
}
