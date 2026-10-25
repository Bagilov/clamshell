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
    private var batteryFloor = BatteryFloor.off
    private var selectedDuration = DurationOption.indefinite
    private var customSpan: String?
    private var darkenDisplay = false
    private var lastError: Error?
    private var isWorking = false
    private var awaitingExpiryRefresh = false

    /// Last choices, restored on the next launch so they are not re-picked.
    private let preferences = Preferences()

    private var menuBuilder = MenuBuilder()
    private var activity: NSObjectProtocol?
    private var menuDelegate: MenuOpenObserver?

    func applicationDidFinishLaunching(_: Notification) {
        restorePreferences()
        buildMenu()
        render()
        refresh()
        reconcileAfterRestart()
        // App Nap throttles timers in a background accessory app, so opt out of
        // napping via AppNapPolicy, which deliberately does not block sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: AppNapPolicy.activityOptions,
            reason: "Refresh clamshell status countdown"
        )
        // The CLI is queried every 5s, but the displayed countdown ticks every
        // second from the local deadline so it looks live without shelling out.
        // Both timers also join the common run loop mode, because an open menu
        // switches the loop to tracking mode where only common timers fire.
        // Previous timers are dropped first so a repeated launch cannot leave
        // two of each running.
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        refreshTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        tickTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        for timer in [refreshTimer, tickTimer] {
            guard let timer else { continue }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func applicationWillTerminate(_: Notification) {
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    deinit {
        // The run loop holds the timers, so a controller that goes away before
        // termination must take them with it rather than leave idle ticks behind.
        refreshTimer?.invalidate()
        tickTimer?.invalidate()
    }

    /// Load the last saved choices before the first render.
    private func restorePreferences() {
        batteryFloor = preferences.batteryFloor
        selectedDuration = preferences.duration
        customSpan = preferences.customSpan
        darkenDisplay = preferences.darken
    }

    /// Persist the choices that should survive a relaunch.
    private func savePreferences() {
        preferences.batteryFloor = batteryFloor
        preferences.duration = selectedDuration
        preferences.customSpan = customSpan
        preferences.darken = darkenDisplay
    }

    /// Re-align a watcher left over from before a reboot, once, in the
    /// background: sleep may be disabled with nothing scheduled to restore it.
    private func reconcileAfterRestart() {
        RestartReconciler(command: command).run()
    }

    private func buildMenu() {
        let menu = menuBuilder.buildMenu(
            target: self,
            command: command,
            floor: batteryFloor,
            duration: customSpan == nil ? selectedDuration : nil,
            darken: darkenDisplay
        )
        statusItem.menu = menu
        let observer = MenuOpenObserver { [weak self] in
            self?.refresh()
        }
        menuDelegate = observer
        menu.delegate = observer
    }

    /// Rebuild the menu, used when the set of floor rows changes.
    private func rebuildMenu() {
        buildMenu()
    }
}

/// Menu actions: session control, selections and app commands.
@MainActor
extension MenuBarController {
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
        customSpan = nil
        savePreferences()
        markDurationSelection()
        perform {
            try self.command.enable(
                duration: option,
                floor: self.batteryFloor,
                darken: self.darkenDisplay
            )
        }
    }

    /// Ask for a duration by hand, then start a session with it.
    @objc func startCustomSession() {
        guard let input = Prompt.text(
            title: "Custom Duration",
            message: "How long should the Mac stay awake? Examples: 45m, 2h, 1h30m, 90.",
            placeholder: "1h30m"
        ) else {
            return
        }
        guard let span = DurationFormat.normalizeSpan(input) else {
            Prompt.invalid(
                title: "Invalid Duration",
                message: "Use forms like 45m, 2h or 1h30m. A bare number is minutes."
            )
            return
        }
        customSpan = span
        savePreferences()
        perform {
            try self.command.enable(
                span: span,
                floorPercent: self.batteryFloor.percent,
                darken: self.darkenDisplay
            )
        }
    }

    /// Ask for a battery floor by hand.
    @objc func selectCustomFloor() {
        guard let input = Prompt.text(
            title: "Custom Battery Level",
            message: "Stop clamshell mode when the battery reaches this level "
                + "(\(BatteryFloorRange.minimum)–\(BatteryFloorRange.maximum)%).",
            placeholder: "25",
            defaultValue: batteryFloor.percent.map(String.init) ?? ""
        ) else {
            return
        }
        guard let floor = BatteryFloor.custom(input) else {
            Prompt.invalid(
                title: "Invalid Battery Level",
                message: "Enter a whole number between \(BatteryFloorRange.minimum) "
                    + "and \(BatteryFloorRange.maximum)."
            )
            return
        }
        applyFloor(floor)
    }

    /// Toggle whether a session blanks the display.
    ///
    /// When a session is already running the toggle takes effect immediately,
    /// so the menu does not claim something the screen does not show.
    @objc func toggleDarken() {
        darkenDisplay.toggle()
        savePreferences()
        menuBuilder.darkenItem.state = darkenDisplay ? .on : .off
        guard darkenDisplay, status.isDisabled else { return }
        perform { try self.command.darkenNow() }
    }

    @objc func selectFloor(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? BatteryFloor else { return }
        applyFloor(option)
    }

    /// Store a new floor, refresh the menu ticks and re-apply a running session.
    private func applyFloor(_ floor: BatteryFloor) {
        batteryFloor = floor
        markFloorSelection()
        guard status.isDisabled else { return }
        // Re-apply with the time still remaining, so changing the floor mid-run
        // never restarts the countdown from full length.
        let span = remainingSeconds.map(String.init) ?? customSpan ?? selectedDuration.span
        perform { try self.command.enable(span: span, floorPercent: floor.percent) }
    }

    /// Tick the duration row matching the stored selection.
    private func markDurationSelection() {
        menuBuilder.markDurationSelection(customSpan == nil ? selectedDuration : nil)
    }

    /// Tick the floor row matching the stored selection.
    ///
    /// A custom value has no preset row, so a matching row is added first;
    /// otherwise the menu would show no selection at all.
    private func markFloorSelection() {
        guard menuBuilder.markFloorSelection(batteryFloor) else {
            rebuildMenu()
            return
        }
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
                Prompt.failure(error)
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
        let reported = status.batteryFloor
        let floor = BatteryFloor.preset(reported) ?? .off
        guard floor != batteryFloor else { return }
        batteryFloor = floor
        markFloorSelection()
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
