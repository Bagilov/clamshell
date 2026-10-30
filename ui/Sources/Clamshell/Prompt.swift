import AppKit

/// A small modal prompt for free-form input.
///
/// `NSAlert` has no text field of its own, so one is added as an accessory
/// view. Kept separate from the controller so the input plumbing stays in one
/// place and the controller keeps to menu wiring.
@MainActor
enum Prompt {
    /// Ask for a single line of text.
    ///
    /// - Parameters:
    ///   - title: Dialog title.
    ///   - message: Explanatory text shown under the title.
    ///   - placeholder: Placeholder shown in the empty field.
    ///   - defaultValue: Text the field starts with.
    /// - Returns: The entered text, or `nil` when the user cancels.
    static func text(
        title: String,
        message: String,
        placeholder: String,
        defaultValue: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = placeholder
        field.stringValue = defaultValue
        alert.accessoryView = field

        // Accessory apps have no key window, so the field needs focus explicitly
        // or the dialog opens with nothing selected.
        alert.window.initialFirstResponder = field
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Show a validation failure for a prompt that was already dismissed.
    static func invalid(title: String, message: String) {
        warn(title: title, message: message)
    }

    /// Ask the user to confirm installing an update.
    ///
    /// Installing is the one action that changes the system, so it always goes
    /// through an explicit confirmation. The default button is "Install" and
    /// "Cancel" is offered, so the safe choice is one keystroke away.
    ///
    /// - Parameters:
    ///   - version: Version the update would install.
    ///   - message: Body text describing what will happen.
    /// - Returns: `true` when the user chose to install.
    static func confirmUpdate(version: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install Clamshell \(version)?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Report a successful update and offer to relaunch.
    ///
    /// The installed binaries changed on disk while the old process is still
    /// running, so restarting is what actually puts the new version in use.
    ///
    /// - Returns: `true` when the user chose to restart now.
    static func offerRelaunch(version: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Clamshell \(version) installed"
        alert.informativeText =
            "Restart Clamshell to start using the new version? "
                + "Any keep-awake session keeps running either way."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ask the user to confirm removing the installation.
    ///
    /// The wording is deliberate: it names what disappears, because uninstalling
    /// deletes the root-owned helper, the sudoers rule and the CLI without an
    /// obvious way to undo. The default button is "Cancel", so the destructive
    /// choice needs a second click or the arrow keys.
    ///
    /// - Returns: `true` when the user chose to uninstall.
    static func confirmUninstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Uninstall Clamshell?"
        alert.informativeText =
            "This removes the helper, the sudoers rule and the clamshell command, "
                + "and restores normal sleep. The app bundle stays until you move "
                + "it to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall")
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Button one is Cancel, so any return other than the first button means
        // the user picked Uninstall.
        return alert.runModal() != .alertFirstButtonReturn
    }

    /// Report a failure from a background action, such as a CLI error.
    ///
    /// Activating first matters for an accessory app: with no key window the
    /// alert would otherwise open behind the frontmost app and go unseen.
    static func failure(_ error: Error) {
        warn(title: "Clamshell", message: error.localizedDescription)
    }

    private static func warn(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
