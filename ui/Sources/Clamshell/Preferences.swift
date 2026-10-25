import ClamshellCore
import Foundation

/// Remembers the menu bar app's last choices across launches.
///
/// Without this the floor and duration reset every time the app starts, so a
/// user who always runs the same session has to re-pick it after each reboot.
/// Values live in `UserDefaults`, aliased to the app's own domain.
struct Preferences {
    private enum Key {
        static let floor = "batteryFloor"
        static let duration = "duration"
        static let customSpan = "customSpan"
        static let darken = "darkenDisplay"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stored battery floor, or `.off` when nothing usable was saved.
    var batteryFloor: BatteryFloor {
        get {
            guard let raw = defaults.object(forKey: Key.floor) as? Int else { return .off }
            return BatteryFloor.preset(raw) ?? .off
        }
        nonmutating set {
            if let percent = newValue.percent {
                defaults.set(percent, forKey: Key.floor)
            } else {
                defaults.removeObject(forKey: Key.floor)
            }
        }
    }

    /// Stored duration preset, or `.indefinite` when nothing was saved.
    var duration: DurationOption {
        get {
            guard let raw = defaults.string(forKey: Key.duration) else { return .indefinite }
            return DurationOption(rawValue: raw) ?? .indefinite
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.duration)
        }
    }

    /// Stored custom span, when the last session used a hand-entered duration.
    var customSpan: String? {
        get { defaults.string(forKey: Key.customSpan) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Key.customSpan)
            } else {
                defaults.removeObject(forKey: Key.customSpan)
            }
        }
    }

    /// Whether the last session also blanked the display.
    var darken: Bool {
        get { defaults.bool(forKey: Key.darken) }
        nonmutating set { defaults.set(newValue, forKey: Key.darken) }
    }
}
