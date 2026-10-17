import AppKit
import ClamshellCore

/// Owns the menu bar item, the status menu and the periodic refresh timer.
///
/// All CLI interaction happens off the main thread; results are applied back on
/// the main queue so AppKit state stays single-threaded.
@MainActor
final class MenuBarController: NSObject, MenuActions {
    private let command = ClamshellCommand()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var status = ClamshellStatus.idle
    private var deadline: Date?
    private var batteryFloor = BatteryFloorOption.off
    private var selectedDuration = DurationOption.indefinite
    private var darkenDisplay = false
    private var lastError: Error?
    private var isWorking = false
    private var awaitingExpiryRefresh = false

    private var menuBuilder = MenuBuilder()
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
        let menu = menuBuilder.buildMenu(
            target: self,
            command: command,
            floor: batteryFloor,
            darken: darkenDisplay
        )
        statusItem.menu = menu
        let observer = MenuOpenObserver { [weak self] in
            self?.refresh()
        }
        menuDelegate = observer
        menu.delegate = observer
    }

    @objc func refresh() {
        guard !isWorking else { return }
        Task { @MainActor in
            await refreshStatus()
            render()
        }
    }

    @objc func startSession(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? DurationOption else { return }
        selectedDuration = option
        perform {
            try self.command.enable(
                duration: option,
                floor: self.batteryFloor,
                darken: self.darkenDisplay
            )
        }
    }

    /// Toggle whether starting a session also blanks the display.
    @objc func toggleDarken() {
        darkenDisplay.toggle()
        menuBuilder.darkenItem.state = darkenDisplay ? .on : .off
    }

    @objc func selectFloor(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? BatteryFloorOption else { return }
        batteryFloor = option
        for item in menuBuilder.floorItems {
            item.state = (item.representedObject as? BatteryFloorOption) == option ? .on : .off
        }
        guard status.isDisabled else { return }
        // Re-apply with the time still remaining, so changing the floor mid-run
        // never restarts the countdown from full length.
        let span = remainingSeconds.map(String.init) ?? selectedDuration.span
        perform { try self.command.enable(span: span, floor: option) }
    }

    @objc func stopSession() {
        perform { try self.command.disable() }
    }

    @objc func showAbout() {
        // Activate first so the panel comes to the front from an accessory app,
        // which otherwise has no windows and can stay behind the active app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: About.name,
            .applicationVersion: About.version,
            .version: "",
            .credits: NSAttributedString(
                string: "\(About.summary)\n\(About.repositoryURL.absoluteString)"
            ),
        ])
    }

    @objc func openRepository() {
        NSWorkspace.shared.open(About.repositoryURL)
    }

    @objc func quit() {
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
        for item in menuBuilder.floorItems {
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
        apply(.busy)
    }

    /// Remaining seconds derived from the local deadline, if one is set.
    private var remainingSeconds: Int? {
        guard let deadline else { return nil }
        let seconds = Int(deadline.timeIntervalSinceNow.rounded())
        return max(0, seconds)
    }

    private func render() {
        resolveLocalExpiry()
        apply(MenuBarPresentation.make(
            status: status,
            remainingSeconds: remainingSeconds,
            error: lastError
        ))
    }

    /// Apply a presentation to the status item and the disabled menu row.
    private func apply(_ presentation: MenuBarPresentation) {
        menuBuilder.stateItem.title = presentation.menuTitle
        statusItem.button?.image = Symbol.icon(named: presentation.iconName)
        statusItem.button?.title = presentation.buttonTitle
        statusItem.button?.toolTip = presentation.toolTip
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
