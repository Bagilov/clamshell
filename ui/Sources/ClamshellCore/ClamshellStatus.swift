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

/// Decoding for `clamshell status --json`.
///
/// Written by hand rather than synthesised: the JSON uses short keys, and a
/// missing or `null` field must degrade to "no trigger" instead of failing the
/// whole decode and hiding an otherwise valid status.
extension ClamshellStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case isDisabled = "disabled"
        case remainingSeconds
        case batteryFloor = "floor"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let disabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        let remaining = try container.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        let floor = try container.decodeIfPresent(Int.self, forKey: .batteryFloor)
        self.init(
            isDisabled: disabled,
            remainingSeconds: remaining,
            batteryFloor: (floor ?? 0) > 0 ? floor : nil
        )
    }
}
