import AppKit

/// Builds status bar icons from SF Symbols with a menu-bar-appropriate size.
enum Symbol {
    /// Return a configured template image for the given SF Symbol name.
    ///
    /// Template images let macOS invert the glyph automatically for light and
    /// dark menu bars. A text fallback is returned if the symbol is missing.
    static func icon(named name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(configuration)
        else {
            return NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: name)
        }
        image.isTemplate = true
        return image
    }
}
