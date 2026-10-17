import Foundation

/// The text and icon the menu bar should show for a given state.
///
/// Kept out of the AppKit controller so the mapping from state to presentation
/// is pure and unit-testable, and so the controller stays small.
public struct MenuBarPresentation: Equatable, Sendable {
    /// Title of the disabled state row at the top of the menu.
    public let menuTitle: String
    /// Text shown next to the status item glyph, if any.
    public let buttonTitle: String
    /// Tooltip shown when hovering the status item.
    public let toolTip: String
    /// SF Symbol name for the status item glyph.
    public let iconName: String
    /// Whether the status item shows a warning icon.
    public let isWarning: Bool

    /// Build the presentation for the current status and countdown.
    ///
    /// - Parameters:
    ///   - status: The latest status reported by the CLI.
    ///   - remainingSeconds: Seconds left in the session, already clamped at
    ///     zero, or `nil` when no deadline applies.
    ///   - error: A CLI failure to surface instead of the normal state.
    /// - Returns: The presentation to apply to the status item and menu row.
    public static func make(
        status: ClamshellStatus,
        remainingSeconds: Int?,
        error: Error?
    ) -> MenuBarPresentation {
        if let error {
            let text = error.localizedDescription
            return MenuBarPresentation(
                menuTitle: "Error: \(text)",
                buttonTitle: "",
                toolTip: "Clamshell: \(text)",
                iconName: "exclamationmark.triangle",
                isWarning: true
            )
        }

        let floorText = status.batteryFloor.map { " · stops at \($0)%" } ?? ""
        let icon = status.isDisabled ? "moon.zzz.fill" : "moon.zzz"

        if let remaining = remainingSeconds, remaining > 0 {
            let full = DurationFormat.text(fromSeconds: remaining)
            return MenuBarPresentation(
                menuTitle: "Active, auto-restores in \(full)\(floorText)",
                buttonTitle: " \(DurationFormat.compact(fromSeconds: remaining))",
                toolTip: "Clamshell: auto-restores in \(full)\(floorText)",
                iconName: icon,
                isWarning: false
            )
        }

        if status.isDisabled {
            return MenuBarPresentation(
                menuTitle: "Active until stopped\(floorText)",
                buttonTitle: status.batteryFloor == nil ? " ∞" : " 🔋",
                toolTip: "Clamshell: active until stopped\(floorText)",
                iconName: icon,
                isWarning: false
            )
        }

        return MenuBarPresentation(
            menuTitle: "Sleep is enabled",
            buttonTitle: "",
            toolTip: "Clamshell: sleep is enabled",
            iconName: icon,
            isWarning: false
        )
    }

    /// Presentation shown while a CLI command is in flight.
    public static let busy = MenuBarPresentation(
        menuTitle: "Working…",
        buttonTitle: "",
        toolTip: "Clamshell: working…",
        iconName: "hourglass",
        isWarning: false
    )
}
