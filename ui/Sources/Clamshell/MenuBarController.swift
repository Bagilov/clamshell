import AppKit
import ClamshellCore

/// Owns the menu bar item, the status menu and the periodic refresh timer.
///
/// All CLI interaction happens off the main thread; results are applied back on
/// the main queue so AppKit state stays single-threaded.
@MainActor
final class MenuBarController: NSObject {
    private let command = ClamshellCommand()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var status = ClamshellStatus.idle
    private var deadline: Date?
    private var batteryFloor = BatteryFloorOption.off
    private var selectedDuration = DurationOption.indefinite
    private var lastError: Error?
    private var isWorking = false
    private var awaitingExpiryRefresh = false

    private let stateItem = NSMenuItem()
    private var floorItems: [NSMenuItem] = []
    private var activity: NSObjectProtocol?
    private var menuDelegate: MenuOpenObserver?

    func applicationDidFinishLaunching(_: Notification) {
        buildMenu()
        render()
        refresh()
        // App Nap throttles timers in a background accessory app, so opt out
        // of napping. This does not itself prevent system sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Refresh clamshell status countdown"
        )
        // The CLI is queried every 5s, but the displayed countdown ticks every
        // second from the local deadline so it looks live without shelling out.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    func applicationWillTerminate(_: Notification) {
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        addSessionItems(to: menu)
        menu.addItem(.separator())
        addFloorItems(to: menu)
        menu.addItem(.separator())
        addCommandItems(to: menu)

        statusItem.menu = menu
        let observer = MenuOpenObserver { [weak self] in
            self?.refresh()
        }
        menuDelegate = observer
        menu.delegate = observer
    }

    /// Add the keep-awake choices, or a hint when the CLI is not installed.
    private func addSessionItems(to menu: NSMenu) {
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
                action: #selector(startSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            menu.addItem(item)
        }
    }

    /// Add the battery-floor header and its radio-style choices.
    private func addFloorItems(to menu: NSMenu) {
        let header = NSMenuItem(title: "Stop on Low Battery", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        floorItems = BatteryFloorOption.allCases.map { option in
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectFloor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = option == batteryFloor ? .on : .off
            menu.addItem(item)
            return item
        }
    }

    /// Add the stop, refresh and quit commands.
    private func addCommandItems(to menu: NSMenu) {
        let offItem = NSMenuItem(
            title: "Stop Clamshell Mode",
            action: #selector(stopSession),
            keyEquivalent: ""
        )
        offItem.target = self
        menu.addItem(offItem)

        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func refresh() {
        guard !isWorking else { return }
        Task { @MainActor in
            await refreshStatus()
            render()
        }
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? DurationOption else { return }
        selectedDuration = option
        perform { try self.command.enable(duration: option, floor: self.batteryFloor) }
    }

    @objc private func selectFloor(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? BatteryFloorOption else { return }
        batteryFloor = option
        for item in floorItems {
            item.state = (item.representedObject as? BatteryFloorOption) == option ? .on : .off
        }
        guard status.isDisabled else { return }
        // Re-apply with the time still remaining, so changing the floor mid-run
        // never restarts the countdown from full length.
        let span = remainingSeconds.map(String.init) ?? selectedDuration.span
        perform { try self.command.enable(span: span, floor: option) }
    }

    @objc private func stopSession() {
        perform { try self.command.disable() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Run a CLI mutation, then refresh the displayed state.
    private func perform(_ action: @escaping () throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        renderBusy()
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try action()
            } catch {
                present(error)
            }
            await refreshStatus()
            render()
        }
    }

    /// Fetch the current status, recording any failure for the menu to show.
    ///
    /// The remaining time is converted into a local deadline so the countdown
    /// can tick every second without querying the CLI that often.
    private func refreshStatus() async {
        guard command.isInstalled else {
            lastError = ClamshellError.cliNotFound(command.launcherPath)
            return
        }
        do {
            status = try await Task.detached(priority: .utility) {
                try self.command.status()
            }.value
            if let remaining = status.remainingSeconds, remaining > 0 {
                deadline = Date().addingTimeInterval(TimeInterval(remaining))
            } else {
                deadline = nil
            }
            syncFloorFromStatus()
            awaitingExpiryRefresh = false
            lastError = nil
        } catch {
            deadline = nil
            awaitingExpiryRefresh = false
            lastError = error
        }
    }

    /// Reflect the floor reported by the CLI in the stored selection and menu.
    private func syncFloorFromStatus() {
        let reported = status.batteryFloor ?? 0
        let option = BatteryFloorOption(rawValue: reported) ?? .off
        guard option != batteryFloor else { return }
        batteryFloor = option
        for item in floorItems {
            item.state = (item.representedObject as? BatteryFloorOption) == option ? .on : .off
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Clamshell"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func renderBusy() {
        stateItem.title = "Working…"
        statusItem.button?.image = Symbol.icon(named: "hourglass")
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Clamshell: working…"
    }

    /// Remaining seconds derived from the local deadline, if one is set.
    private var remainingSeconds: Int? {
        guard let deadline else { return nil }
        let seconds = Int(deadline.timeIntervalSinceNow.rounded())
        return max(0, seconds)
    }

    private func render() {
        if let error = lastError {
            stateItem.title = "Error: \(error.localizedDescription)"
            statusItem.button?.image = Symbol.icon(named: "exclamationmark.triangle")
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "Clamshell: \(error.localizedDescription)"
            return
        }
        resolveLocalExpiry()
        let icon = status.isDisabled ? "moon.zzz.fill" : "moon.zzz"
        statusItem.button?.image = Symbol.icon(named: icon)
        let floorText = status.batteryFloor.map { " · stops at \($0)%" } ?? ""
        if let remaining = remainingSeconds, remaining > 0 {
            let full = DurationFormat.text(fromSeconds: remaining)
            stateItem.title = "Active, auto-restores in \(full)\(floorText)"
            statusItem.button?.title = " \(DurationFormat.compact(fromSeconds: remaining))"
            statusItem.button?.toolTip = "Clamshell: auto-restores in \(full)\(floorText)"
        } else if status.isDisabled {
            stateItem.title = "Active until stopped\(floorText)"
            statusItem.button?.title = status.batteryFloor == nil ? " ∞" : " 🔋"
            statusItem.button?.toolTip = "Clamshell: active until stopped\(floorText)"
        } else {
            stateItem.title = "Sleep is enabled"
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "Clamshell: sleep is enabled"
        }
    }

    /// Apply the deadline locally once it passes, so the menu bar never shows a
    /// stale "active until stopped" during the gap before the next poll.
    ///
    /// The CLI's scheduled job restores sleep at the deadline, so treating the
    /// session as finished here matches what the next poll will report.
    private func resolveLocalExpiry() {
        guard let deadline, deadline.timeIntervalSinceNow <= 0 else { return }
        self.deadline = nil
        status = ClamshellStatus.idle
        if !awaitingExpiryRefresh {
            awaitingExpiryRefresh = true
            refresh()
        }
    }
}
