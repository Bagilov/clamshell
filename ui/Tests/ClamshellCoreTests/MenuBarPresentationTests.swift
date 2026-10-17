import ClamshellCore
import Foundation
import Testing

@Suite("MenuBarPresentation")
struct MenuBarPresentationTests {
    @Test("Shows a countdown while a timed session runs")
    func showsCountdownWhenTimed() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: 3600)
        let view = MenuBarPresentation.make(status: status, remainingSeconds: 3600, error: nil)
        #expect(view.menuTitle == "Active, auto-restores in 1h")
        #expect(view.buttonTitle == " 1h")
        #expect(view.iconName == "moon.zzz.fill")
        #expect(!view.isWarning)
    }

    @Test("Mentions the battery floor in the title and tooltip")
    func mentionsBatteryFloor() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: 600, batteryFloor: 20)
        let view = MenuBarPresentation.make(status: status, remainingSeconds: 600, error: nil)
        #expect(view.menuTitle == "Active, auto-restores in 10m · stops at 20%")
        #expect(view.toolTip.contains("stops at 20%"))
    }

    @Test("Uses the infinity glyph when no trigger applies")
    func usesInfinityWhenUnlimited() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: nil)
        let view = MenuBarPresentation.make(status: status, remainingSeconds: nil, error: nil)
        #expect(view.menuTitle == "Active until stopped")
        #expect(view.buttonTitle == " ∞")
    }

    @Test("Uses the battery glyph for a floor-only session")
    func usesBatteryGlyphForFloorOnly() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: nil, batteryFloor: 30)
        let view = MenuBarPresentation.make(status: status, remainingSeconds: nil, error: nil)
        #expect(view.buttonTitle == " 🔋")
        #expect(view.menuTitle.contains("stops at 30%"))
    }

    @Test("Shows the idle state when sleep is enabled")
    func showsIdleState() {
        let view = MenuBarPresentation.make(
            status: .idle,
            remainingSeconds: nil,
            error: nil
        )
        #expect(view.menuTitle == "Sleep is enabled")
        #expect(view.buttonTitle == "")
        #expect(view.iconName == "moon.zzz")
    }

    @Test("Prefers the error over the normal state")
    func errorTakesPrecedence() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: 60)
        let view = MenuBarPresentation.make(
            status: status,
            remainingSeconds: 60,
            error: ClamshellError.cliNotFound("/x")
        )
        #expect(view.isWarning)
        #expect(view.iconName == "exclamationmark.triangle")
        #expect(view.menuTitle.hasPrefix("Error:"))
        #expect(view.buttonTitle == "")
    }

    @Test("Treats a zero countdown as elapsed")
    func treatsZeroCountdownAsElapsed() {
        let status = ClamshellStatus(isDisabled: true, remainingSeconds: 0)
        let view = MenuBarPresentation.make(status: status, remainingSeconds: 0, error: nil)
        #expect(view.menuTitle == "Active until stopped")
    }

    @Test("Busy presentation shows a working state")
    func busyShowsWorkingState() {
        #expect(MenuBarPresentation.busy.menuTitle == "Working…")
        #expect(MenuBarPresentation.busy.iconName == "hourglass")
    }
}

@Suite("ClamshellCommand startArguments")
struct StartArgumentsTests {
    @Test("Builds an indefinite start with no options")
    func buildsIndefiniteStart() {
        let args = ClamshellCommand.startArguments(span: nil, floor: .off, darken: false)
        #expect(args == ["on"])
    }

    @Test("Adds the span when one is given")
    func addsSpan() {
        let args = ClamshellCommand.startArguments(span: "45m", floor: .off, darken: false)
        #expect(args == ["on", "--for", "45m"])
    }

    @Test("Adds the battery floor when enabled")
    func addsBatteryFloor() {
        let args = ClamshellCommand.startArguments(span: nil, floor: .twenty, darken: false)
        #expect(args == ["on", "--battery", "20"])
    }

    @Test("Adds the darken flag when requested")
    func addsDarken() {
        let args = ClamshellCommand.startArguments(span: nil, floor: .off, darken: true)
        #expect(args == ["on", "--darken"])
    }

    @Test("Combines every option in a stable order")
    func combinesAllOptions() {
        let args = ClamshellCommand.startArguments(span: "2h", floor: .fifty, darken: true)
        #expect(args == ["on", "--for", "2h", "--battery", "50", "--darken"])
    }

    @Test("Omits darken when not requested")
    func omitsDarkenByDefault() {
        let args = ClamshellCommand.startArguments(span: "1h", floor: .thirty, darken: false)
        #expect(!args.contains("--darken"))
    }
}
