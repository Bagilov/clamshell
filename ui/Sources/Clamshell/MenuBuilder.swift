import AppKit
import ClamshellCore

/// Builds the status menu and keeps references to the items that change.
///
/// Menu construction is separated from the controller's state and timer
/// lifecycle so each type stays focused and within the size limit.
@MainActor
struct MenuBuilder {
    /// The disabled row at the top showing the current state.
    let stateItem = NSMenuItem()
    /// The battery-floor radio items, including the custom entry.
    private(set) var floorItems: [NSMenuItem] = []
    /// The toggle that blanks the display when a session starts.
    private(set) var darkenItem = NSMenuItem()

    /// Assemble the full status menu.
    ///
    /// - Parameters:
    ///   - target: Object that handles the menu actions.
    ///   - command: The CLI wrapper, used to detect whether it is installed.
    ///   - floor: Currently selected battery floor, for the radio state.
    ///   - darken: Whether the display toggle is currently on.
    /// - Returns: The assembled menu.
    mutating func buildMenu(
        target: AnyObject,
        command: ClamshellCommand,
        floor: BatteryFloor,
        darken: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        addSessionItems(to: menu, target: target, command: command)
        menu.addItem(.separator())
        addFloorItems(to: menu, target: target, floor: floor)
        menu.addItem(.separator())
        addDisplayItem(to: menu, target: target, darken: darken)
        menu.addItem(.separator())
        addCommandItems(to: menu, target: target)
        return menu
    }

    /// Keep-awake choices, with a manual entry, or a hint when not installed.
    private func addSessionItems(to menu: NSMenu, target: AnyObject, command: ClamshellCommand) {
        guard command.isInstalled else {
            let missing = NSMenuItem(
                title: "Run `clamshell install` first",
                action: nil,
                keyEquivalent: ""
            )
            missing.isEnabled = false
            menu.addItem(missing)
            return
        }
        for option in DurationOption.allCases {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(MenuActions.startSession(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = option
            menu.addItem(item)
        }
        let custom = NSMenuItem(
            title: "Custom…",
            action: #selector(MenuActions.startCustomSession),
            keyEquivalent: ""
        )
        custom.target = target
        menu.addItem(custom)
    }

    /// The battery-floor header, presets and a custom entry.
    private mutating func addFloorItems(
        to menu: NSMenu,
        target: AnyObject,
        floor: BatteryFloor
    ) {
        let header = NSMenuItem(title: "Stop on Low Battery", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // A custom value that matches no preset still needs a checked row, so it
        // is appended as its own item rather than silently dropping the state.
        var choices = BatteryFloor.presets
        if let percent = floor.percent, !choices.contains(where: { $0.percent == percent }) {
            choices.append(floor)
        }

        floorItems = choices.map { option in
            let item = NSMenuItem(
                title: option.title,
                action: #selector(MenuActions.selectFloor(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = option
            item.state = option == floor ? .on : .off
            menu.addItem(item)
            return item
        }

        let custom = NSMenuItem(
            title: "Custom…",
            action: #selector(MenuActions.selectCustomFloor),
            keyEquivalent: ""
        )
        custom.target = target
        menu.addItem(custom)
    }

    /// The display-blanking toggle.
    private mutating func addDisplayItem(to menu: NSMenu, target: AnyObject, darken: Bool) {
        darkenItem = NSMenuItem(
            title: "Turn Display Off",
            action: #selector(MenuActions.toggleDarken),
            keyEquivalent: ""
        )
        darkenItem.target = target
        darkenItem.state = darken ? .on : .off
        menu.addItem(darkenItem)
    }

    /// Stop, refresh and quit.
    private func addCommandItems(to menu: NSMenu, target: AnyObject) {
        let offItem = NSMenuItem(
            title: "Stop Clamshell Mode",
            action: #selector(MenuActions.stopSession),
            keyEquivalent: ""
        )
        offItem.target = target
        menu.addItem(offItem)

        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(MenuActions.refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = target
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "About Clamshell",
            action: #selector(MenuActions.showAbout),
            keyEquivalent: ""
        )
        about.target = target
        menu.addItem(about)

        let repository = NSMenuItem(
            title: "View Repository",
            action: #selector(MenuActions.openRepository),
            keyEquivalent: ""
        )
        repository.target = target
        menu.addItem(repository)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(MenuActions.quit),
            keyEquivalent: "q"
        )
        quit.target = target
        menu.addItem(quit)
    }
}

/// Selectors routed from the menu; implemented by `MenuBarController`.
@MainActor
@objc
protocol MenuActions {
    func startSession(_ sender: NSMenuItem)
    func startCustomSession()
    func selectFloor(_ sender: NSMenuItem)
    func selectCustomFloor()
    func toggleDarken()
    func stopSession()
    func refresh()
    func showAbout()
    func openRepository()
    func quit()
}
