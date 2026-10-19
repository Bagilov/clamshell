import Foundation

/// Validation for a manually entered battery floor.
///
/// Mirrors the range the CLI accepts, so a custom value typed in the menu is
/// rejected in the UI instead of failing later in a subprocess.
public enum BatteryFloorRange {
    /// Lowest accepted percentage.
    public static let minimum = 5
    /// Highest accepted percentage.
    public static let maximum = 95

    /// Whether a percentage is inside the supported range.
    public static func contains(_ percent: Int) -> Bool {
        (minimum ... maximum).contains(percent)
    }

    /// Build the CLI argument for a custom floor value.
    ///
    /// - Parameter input: Raw text from a text field.
    /// - Returns: The value when it parses and is in range, otherwise `nil`.
    public static func parse(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let value = Int(text), contains(value) else { return nil }
        return value
    }
}

/// A battery floor: either disabled, a preset, or a value entered by hand.
///
/// Modelled as a value type rather than a fixed enum so a manually entered
/// percentage is a first-class choice and flows through the same plumbing.
public struct BatteryFloor: Equatable, Identifiable, Sendable {
    /// The percentage that stops the session, or `nil` when disabled.
    public let percent: Int?

    public var id: Int {
        percent ?? 0
    }

    /// The floor is disabled.
    public static let off = BatteryFloor(percent: nil)

    private init(percent: Int?) {
        self.percent = percent
    }

    /// Build a floor from a percentage.
    ///
    /// - Parameter percent: A value inside `BatteryFloorRange`, or `nil`.
    /// - Returns: The floor, or `nil` when the percentage is out of range.
    public static func preset(_ percent: Int?) -> BatteryFloor? {
        guard let percent else { return .off }
        guard BatteryFloorRange.contains(percent) else { return nil }
        return BatteryFloor(percent: percent)
    }

    /// Build a floor from raw user input.
    ///
    /// - Parameter input: Text from a text field, optionally with a `%`.
    /// - Returns: The floor, or `nil` when the input does not parse.
    public static func custom(_ input: String) -> BatteryFloor? {
        guard let value = BatteryFloorRange.parse(input) else { return nil }
        return BatteryFloor(percent: value)
    }

    /// Whether the floor is disabled.
    public var isOff: Bool {
        percent == nil
    }

    /// Label shown in the menu.
    public var title: String {
        guard let percent else { return "No battery limit" }
        return "Stop at \(percent)%"
    }

    /// Compact label for the menu bar tooltip.
    public var shortTitle: String {
        guard let percent else { return "no battery limit" }
        return "stops at \(percent)%"
    }

    /// The choices offered as presets in the menu.
    public static let presets: [BatteryFloor] = [.off] + [20, 30, 40, 50].compactMap { preset($0) }
}
