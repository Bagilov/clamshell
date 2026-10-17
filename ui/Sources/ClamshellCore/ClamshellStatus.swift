import Foundation

/// The observed state of the `clamshell` CLI.
public struct ClamshellStatus: Equatable, Sendable {
    /// Whether system sleep is currently disabled.
    public let isDisabled: Bool
    /// Seconds until the CLI's automatic restore fires, when a timer is active.
    public let remainingSeconds: Int?
    /// Battery percentage that stops the session, or `nil` when disabled.
    public let batteryFloor: Int?

    public init(isDisabled: Bool, remainingSeconds: Int?, batteryFloor: Int? = nil) {
        self.isDisabled = isDisabled
        self.remainingSeconds = remainingSeconds
        self.batteryFloor = batteryFloor
    }

    /// A status representing sleep being allowed with no pending trigger.
    public static let idle = ClamshellStatus(isDisabled: false, remainingSeconds: nil)
}
