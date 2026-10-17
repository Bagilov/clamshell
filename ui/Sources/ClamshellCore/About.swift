import Foundation

/// Static project information shown in the app's About panel.
public enum About {
    /// Canonical repository URL for the project.
    public static let repositoryURL = URL(string: "https://github.com/Bagilov/clamshell")!

    /// Project name shown in the About panel.
    public static let name = "Clamshell"

    /// Short description shown under the name.
    public static let summary = "Keep a MacBook awake with the lid closed."

    /// Version reported by the app bundle, or "unknown" when unavailable.
    ///
    /// Read from `CFBundleShortVersionString` so the value always tracks the
    /// packaged Info.plist instead of a second hard-coded copy.
    public static var version: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        return (value as? String) ?? "unknown"
    }
}
