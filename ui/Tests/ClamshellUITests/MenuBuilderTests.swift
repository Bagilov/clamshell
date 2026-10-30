import AppKit
@testable import Clamshell
import ClamshellCore
import Testing

/// Regression tests for the menu construction bugs found in review round 2.
@MainActor
@Suite("MenuBuilder")
struct MenuBuilderTests {
    /// A command whose launcher exists, so the menu builds the full session set.
    ///
    /// The menu only offers the keep-awake choices when the CLI is installed, so
    /// pointing at the real `/usr/local/bin/clamshell` would make every assertion
    /// depend on the machine having clamshell installed. A throwaway executable
    /// keeps the tests hermetic: they pass on a bare CI runner and on a developer
    /// machine alike.
    private func installedCommand() throws -> ClamshellCommand {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clamshell-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("clamshell")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return ClamshellCommand(path: script.path, timeout: 1)
    }

    @Test("Rebuilding the menu twice does not reuse a menu item")
    func rebuildingDoesNotReuseItems() throws {
        // `NSMenuItem` can belong to a single menu; adding a stored instance to a
        // second menu throws NSInternalInconsistencyException ("Item to be
        // inserted into menu already is in another menu"). The old menu stays
        // installed until the new one is assigned, which is exactly the shape of
        // MenuBarController.rebuildMenu().
        var builder = MenuBuilder()
        let command = try installedCommand()
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
    func marksSelectedDuration() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()

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
    func rebuildReplacesDurationItems() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()
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
    func updateRowOnlyWhenAvailable() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()

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
    func checkRowAlwaysPresent() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()
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
    func loginRowOnlyWhenAvailable() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()

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
    func uninstallRowPresent() throws {
        var builder = MenuBuilder()
        let command = try installedCommand()
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
