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
        let args = ClamshellCommand.startArguments(span: nil, floorPercent: nil, darken: false)
        #expect(args == ["on"])
    }

    @Test("Adds the span when one is given")
    func addsSpan() {
        let args = ClamshellCommand.startArguments(span: "45m", floorPercent: nil, darken: false)
        #expect(args == ["on", "--for", "45m"])
    }

    @Test("Adds the battery floor when enabled")
    func addsBatteryFloor() {
        let args = ClamshellCommand.startArguments(span: nil, floorPercent: 20, darken: false)
        #expect(args == ["on", "--battery", "20"])
    }

    @Test("Passes a custom battery floor through unchanged")
    func passesCustomBatteryFloor() {
        let args = ClamshellCommand.startArguments(span: nil, floorPercent: 37, darken: false)
        #expect(args == ["on", "--battery", "37"])
    }

    @Test("Adds the darken flag when requested")
    func addsDarken() {
        let args = ClamshellCommand.startArguments(span: nil, floorPercent: nil, darken: true)
        #expect(args == ["on", "--darken"])
    }

    @Test("Combines every option in a stable order")
    func combinesAllOptions() {
        let args = ClamshellCommand.startArguments(span: "2h", floorPercent: 50, darken: true)
        #expect(args == ["on", "--for", "2h", "--battery", "50", "--darken"])
    }

    @Test("Omits darken when not requested")
    func omitsDarkenByDefault() {
        let args = ClamshellCommand.startArguments(span: "1h", floorPercent: 30, darken: false)
        #expect(!args.contains("--darken"))
    }

    @Test("Accepts a manually entered span verbatim")
    func acceptsManualSpan() {
        let args = ClamshellCommand.startArguments(
            span: "1h45m", floorPercent: nil, darken: false
        )
        #expect(args == ["on", "--for", "1h45m"])
    }
}

@Suite("DurationFormat normalizeSpan")
struct NormalizeSpanTests {
    @Test("Normalises unit forms with and without spaces")
    func normalisesUnitForms() {
        #expect(DurationFormat.normalizeSpan("45m") == "45m")
        #expect(DurationFormat.normalizeSpan("1h30m") == "1h30m")
        #expect(DurationFormat.normalizeSpan("1h 30m") == "1h30m")
        #expect(DurationFormat.normalizeSpan(" 2H ") == "2h")
        #expect(DurationFormat.normalizeSpan("1d2h3m4s") == "1d2h3m4s")
    }

    @Test("Treats a bare number as minutes")
    func bareNumberIsMinutes() {
        #expect(DurationFormat.normalizeSpan("90") == "90m")
        #expect(DurationFormat.normalizeSpan("1") == "1m")
    }

    @Test("Drops zero-length groups")
    func dropsZeroGroups() {
        #expect(DurationFormat.normalizeSpan("0h30m") == "30m")
        #expect(DurationFormat.normalizeSpan("1h0m") == "1h")
    }

    @Test("Rejects empty, bare units and malformed input")
    func rejectsMalformed() {
        #expect(DurationFormat.normalizeSpan("") == nil)
        #expect(DurationFormat.normalizeSpan("   ") == nil)
        #expect(DurationFormat.normalizeSpan("h") == nil)
        #expect(DurationFormat.normalizeSpan("1x") == nil)
        #expect(DurationFormat.normalizeSpan("abc") == nil)
        #expect(DurationFormat.normalizeSpan("1h30") == nil)
        #expect(DurationFormat.normalizeSpan("0") == nil)
        #expect(DurationFormat.normalizeSpan("0h0m") == nil)
        #expect(DurationFormat.normalizeSpan("-5m") == nil)
    }

    @Test("Rejects a duration beyond the sane maximum")
    func rejectsBeyondMaximum() {
        // A typo must not create an effectively endless session.
        #expect(DurationFormat.normalizeSpan("999999999") == nil)
        #expect(DurationFormat.normalizeSpan("999999999m") == nil)
        #expect(DurationFormat.normalizeSpan("40d") == nil)
        #expect(DurationFormat.normalizeSpan("30d") == "30d")
        #expect(DurationFormat.maximumSeconds == 2_592_000)
    }

    @Test("Normalising is idempotent and space-insensitive")
    func normalisingIsStable() {
        // The output must be a fixed point, and the spaced and compact spellings
        // must agree — that is what makes the field forgiving to type into.
        let pairs: [(compact: String, spaced: String)] = [
            ("45m", "45m"),
            ("1h30m", "1h 30m"),
            ("1d2h3m4s", "1d 2h 3m 4s"),
            ("30m", "0h30m"),
        ]
        for pair in pairs {
            let fromCompact = DurationFormat.normalizeSpan(pair.compact)
            let fromSpaced = DurationFormat.normalizeSpan(pair.spaced)
            #expect(fromCompact == fromSpaced)
            #expect(DurationFormat.normalizeSpan(fromCompact ?? "") == fromCompact)
        }
    }
}
