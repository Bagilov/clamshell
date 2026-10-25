import AppKit
@testable import Clamshell
import ClamshellCore
import Testing

/// Regression tests for the menu construction bugs found in review round 2.
@MainActor
@Suite("MenuBuilder")
struct MenuBuilderTests {
    @Test("Rebuilding the menu twice does not reuse a menu item")
    func rebuildingDoesNotReuseItems() {
        // `NSMenuItem` can belong to a single menu; adding a stored instance to a
        // second menu throws NSInternalInconsistencyException ("Item to be
        // inserted into menu already is in another menu"). The old menu stays
        // installed until the new one is assigned, which is exactly the shape of
        // MenuBarController.rebuildMenu().
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)
        final class Holder {
            var menu: NSMenu?
        }
        let holder = Holder()

        func build() -> NSMenu {
            builder.buildMenu(
                target: NSObject(),
                command: command,
                floor: .off,
                duration: .indefinite,
                darken: false
            )
        }

        let first = build()
        holder.menu = first
        let second = build()
        holder.menu = second
        let third = build()
        holder.menu = third

        #expect(third.items.isEmpty == false)
        #expect(builder.stateItem.menu === third)
    }

    @Test("Checks the selected duration and clears it for a custom span")
    func marksSelectedDuration() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)

        _ = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .hours2,
            darken: false
        )
        let checked = builder.durationItems.filter { $0.state == .on }
        #expect(checked.count == 1)
        #expect(checked.first?.representedObject as? DurationOption == .hours2)

        // A custom span matches no preset, so nothing may look selected.
        _ = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: nil,
            darken: false
        )
        #expect(builder.durationItems.allSatisfy { $0.state == .off })
    }

    @Test("Does not accumulate duration items across rebuilds")
    func rebuildReplacesDurationItems() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)
        let expected = DurationOption.allCases.count

        for _ in 0 ..< 3 {
            _ = builder.buildMenu(
                target: NSObject(),
                command: command,
                floor: .off,
                duration: .hour1,
                darken: false
            )
        }
        #expect(builder.durationItems.count == expected)
    }
}
