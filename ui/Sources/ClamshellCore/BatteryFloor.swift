import Foundation

/// A user-chosen battery level at which clamshell mode is stopped automatically.
///
/// Only the values below are offered, mirroring the range the CLI accepts, so
/// the menu can present a fixed, predictable list.
public enum BatteryFloorOption: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case twenty = 20
    case thirty = 30
    case forty = 40
    case fifty = 50

    public var id: Int {
        rawValue
    }

    /// The percentage passed to the CLI, or `nil` when the floor is disabled.
    public var percent: Int? {
        self == .off ? nil : rawValue
    }

    /// Label shown in the menu.
    public var title: String {
        switch self {
        case .off: "No battery limit"
        case .twenty: "Stop at 20%"
        case .thirty: "Stop at 30%"
        case .forty: "Stop at 40%"
        case .fifty: "Stop at 50%"
        }
    }

    /// Compact label for the menu bar tooltip.
    public var shortTitle: String {
        self == .off ? "no battery limit" : "stops at \(rawValue)%"
    }
}
