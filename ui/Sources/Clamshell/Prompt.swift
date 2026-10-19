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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
