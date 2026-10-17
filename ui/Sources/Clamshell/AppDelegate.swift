import AppKit

/// Menu bar application that drives the `clamshell` CLI.
///
/// The app is an accessory (`LSUIElement`): it shows only a status item and has
/// no Dock icon or main window.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keeps the delegate alive, since `NSApplication.delegate` is weak.
    private static var retained: AppDelegate?

    private let controller = MenuBarController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.applicationDidFinishLaunching(notification)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.applicationWillTerminate(notification)
    }
}
