import AppKit

/// Refreshes the displayed state whenever the status menu opens.
///
/// App Nap can throttle the periodic timer, so refreshing on open guarantees
/// the countdown is current at the moment the user looks at it.
@MainActor
final class MenuOpenObserver: NSObject, NSMenuDelegate {
    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    func menuWillOpen(_: NSMenu) {
        onOpen()
    }
}
