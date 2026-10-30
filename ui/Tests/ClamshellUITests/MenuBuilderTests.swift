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

    private func updateStatus(release: Bool) -> UpdateStatus {
        let info = release
            ? ReleaseInfo(
                version: "0.4.0",
                tag: "v0.4.0",
                name: "Clamshell 0.4.0",
                isPrerelease: false,
                pageURL: "https://example.test/v0.4.0",
                assetName: "Clamshell-0.4.0.pkg",
                hasDigest: true
            )
            : nil
        return UpdateStatus(
            current: "0.3.0",
            latest: info?.version,
            release: info,
            checkedAt: 0,
            fromCache: false
        )
    }

    @Test("Adds an install row only when a release is known")
    func updateRowOnlyWhenAvailable() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)

        // The menu is held for the duration of each assertion: an NSMenu that is
        // released takes its items' `menu` back-reference with it.
        let withUpdate = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false,
            update: updateStatus(release: true)
        )
        #expect(builder.updateItem.title == "Update to 0.4.0…")
        #expect(builder.updateItem.menu === withUpdate)

        let withoutUpdate = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false,
            update: updateStatus(release: false)
        )
        #expect(withoutUpdate.items.contains(builder.updateItem) == false)
    }

    @Test("Always adds a manual check row, even on a failed check")
    func checkRowAlwaysPresent() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)
        let menu = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false,
            update: updateStatus(release: false)
        )
        #expect(builder.checkUpdatesItem.menu === menu)
        #expect(builder.checkUpdatesItem.title == "Check for Updates…")
    }

    @Test("Shows the login row only when the app can register it")
    func loginRowOnlyWhenAvailable() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)

        let available = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false,
            launchAtLogin: true,
            canLaunchAtLogin: true
        )
        #expect(builder.loginItem.menu === available)
        #expect(builder.loginItem.title == "Launch at Login")
        #expect(builder.loginItem.state == .on)

        // An unbundled binary must not offer a row that every click would reject.
        let unavailable = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false,
            launchAtLogin: false,
            canLaunchAtLogin: false
        )
        #expect(unavailable.items.contains(builder.loginItem) == false)
    }

    @Test("Offers an uninstall row that opens a confirmation")
    func uninstallRowPresent() {
        var builder = MenuBuilder()
        let command = ClamshellCommand(path: "/usr/local/bin/clamshell", timeout: 1)
        let menu = builder.buildMenu(
            target: NSObject(),
            command: command,
            floor: .off,
            duration: .indefinite,
            darken: false
        )
        let uninstall = menu.items.first { $0.title == "Uninstall Clamshell…" }
        #expect(uninstall != nil)
        #expect(uninstall?.action == #selector(MenuActions.uninstall))
    }
}
