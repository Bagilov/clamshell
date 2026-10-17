import Foundation

/// A keep-awake duration choice offered in the menu bar UI.
///
/// Each case maps to the span syntax accepted by the `clamshell` CLI, or to a
/// session without any automatic restore when `span` is `nil`.
public enum DurationOption: String, CaseIterable, Identifiable, Sendable {
    case indefinite
    case minutes30
    case hour1
    case hours2
    case hours4
    case hours8

    public var id: String {
        rawValue
    }

    /// CLI span argument, or `nil` for an indefinite session.
    public var span: String? {
        switch self {
        case .indefinite: nil
        case .minutes30: "30m"
        case .hour1: "1h"
        case .hours2: "2h"
        case .hours4: "4h"
        case .hours8: "8h"
        }
    }

    /// Short label shown in the menu.
    public var title: String {
        switch self {
        case .indefinite: "Until I stop"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .hours2: "2 hours"
        case .hours4: "4 hours"
        case .hours8: "8 hours"
        }
    }
}

/// Formatting helpers shared by the CLI wrapper and the countdown display.
public enum DurationFormat {
    private static let units: [(name: Character, size: Int)] = [
        ("d", 86400), ("h", 3600), ("m", 60), ("s", 1),
    ]

    /// Render a second count the way the CLI does, for example `1h 30m`.
    public static func text(fromSeconds seconds: Int) -> String {
        guard seconds > 0 else { return "0s" }
        var remaining = seconds
        var parts: [String] = []
        for unit in units where remaining >= unit.size {
            let (count, rest) = remaining.quotientAndRemainder(dividingBy: unit.size)
            remaining = rest
            parts.append("\(count)\(unit.name)")
        }
        return parts.joined(separator: " ")
    }

    /// Parse a rendered span such as `1h 30m` back into seconds.
    ///
    /// Returns `nil` when the text does not consist solely of `<count><unit>`
    /// groups, so a malformed CLI message cannot be shown as a real countdown.
    public static func seconds(fromText text: String) -> Int? {
        let groups = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !groups.isEmpty else { return nil }
        var total = 0
        for group in groups {
            let unit = group.last.map(Character.init)
            let value = String(group.dropLast())
            guard let unit, let size = size(of: unit), let count = Int(value) else {
                return nil
            }
            total += count * size
        }
        return total
    }

    /// Render a second count for the narrow menu bar, for example `3h59m`.
    ///
    /// Shows at most two units so the label keeps a stable, small width, drops
    /// a zero lower unit (`1h` rather than `1h0m`), and falls back to seconds
    /// under a minute so short timers still tick visibly.
    public static func compact(fromSeconds seconds: Int) -> String {
        guard seconds > 0 else { return "0s" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }

    private static func size(of unit: Character) -> Int? {
        units.first { $0.name == unit }?.size
    }
}
