import ClamshellCore
import Testing

@Suite("DurationFormat")
struct DurationFormatTests {
    @Test("Renders descending units")
    func textFromSecondsUsesDescendingUnits() {
        #expect(DurationFormat.text(fromSeconds: 0) == "0s")
        #expect(DurationFormat.text(fromSeconds: -5) == "0s")
        #expect(DurationFormat.text(fromSeconds: 45) == "45s")
        #expect(DurationFormat.text(fromSeconds: 60) == "1m")
        #expect(DurationFormat.text(fromSeconds: 3661) == "1h 1m 1s")
        #expect(DurationFormat.text(fromSeconds: 86400) == "1d")
    }

    @Test("Parses unit groups")
    func secondsFromTextParsesGroups() {
        #expect(DurationFormat.seconds(fromText: "45s") == 45)
        #expect(DurationFormat.seconds(fromText: "1h 30m") == 5400)
        #expect(DurationFormat.seconds(fromText: "1d 2h 3m 4s") == 93784)
    }

    @Test("Rejects malformed input")
    func secondsFromTextRejectsMalformedInput() {
        #expect(DurationFormat.seconds(fromText: "") == nil)
        #expect(DurationFormat.seconds(fromText: "soon") == nil)
        #expect(DurationFormat.seconds(fromText: "1x") == nil)
        #expect(DurationFormat.seconds(fromText: "h") == nil)
    }

    @Test("Round-trips through text")
    func roundTripThroughText() {
        let text = DurationFormat.text(fromSeconds: 5400)
        #expect(DurationFormat.seconds(fromText: text) == 5400)
    }

    @Test("Renders a compact menu bar countdown")
    func compactUsesAtMostTwoUnits() {
        #expect(DurationFormat.compact(fromSeconds: 0) == "0s")
        #expect(DurationFormat.compact(fromSeconds: -5) == "0s")
        #expect(DurationFormat.compact(fromSeconds: 45) == "45s")
        #expect(DurationFormat.compact(fromSeconds: 59) == "59s")
        #expect(DurationFormat.compact(fromSeconds: 60) == "1m")
        #expect(DurationFormat.compact(fromSeconds: 3599) == "59m")
        #expect(DurationFormat.compact(fromSeconds: 3600) == "1h")
        #expect(DurationFormat.compact(fromSeconds: 14399) == "3h59m")
        #expect(DurationFormat.compact(fromSeconds: 86400) == "1d")
        #expect(DurationFormat.compact(fromSeconds: 90000) == "1d1h")
    }

    @Test("Compact output never exceeds two unit groups")
    func compactKeepsWidthStable() {
        for seconds in [61, 3661, 90061, 604_800] {
            let groups = DurationFormat.compact(fromSeconds: seconds)
                .split(whereSeparator: { $0.isLetter })
                .count
            #expect(groups <= 2)
        }
    }
}

@Suite("StatusParser")
struct StatusParserTests {
    @Test("Parses disabled state with timer")
    func parsesDisabledStateWithTimer() {
        let output = "Sleep is DISABLED (clamshell mode active).\nAuto-restore in 1h 30m.\n"
        let expected = ClamshellStatus(isDisabled: true, remainingSeconds: 5400)
        #expect(StatusParser.parse(output) == expected)
    }

    @Test("Parses enabled state")
    func parsesEnabledState() {
        let output = "Sleep is enabled (normal behaviour).\n"
        #expect(StatusParser.parse(output) == ClamshellStatus.idle)
    }

    @Test("Parses disabled state without timer")
    func parsesDisabledStateWithoutTimer() {
        let output = "Sleep is DISABLED (clamshell mode active).\n"
        let expected = ClamshellStatus(isDisabled: true, remainingSeconds: nil)
        #expect(StatusParser.parse(output) == expected)
    }

    @Test("Parses the battery floor line")
    func parsesBatteryFloor() {
        let output = """
        Sleep is DISABLED (clamshell mode active).
        Auto-restore in 1h.
        Auto-restore at 25% battery.
        """
        let expected = ClamshellStatus(
            isDisabled: true,
            remainingSeconds: 3600,
            batteryFloor: 25
        )
        #expect(StatusParser.parse(output) == expected)
    }

    @Test("Parses a battery-floor-only session")
    func parsesFloorOnlySession() {
        let output = """
        Sleep is DISABLED (clamshell mode active).
        Auto-restore at 20% battery.
        """
        let expected = ClamshellStatus(
            isDisabled: true,
            remainingSeconds: nil,
            batteryFloor: 20
        )
        #expect(StatusParser.parse(output) == expected)
    }

    @Test("Ignores a battery floor when sleep is enabled")
    func parsesFloorTextWithoutState() {
        #expect(StatusParser.parse("Auto-restore at 20% battery.\n") == nil)
    }

    @Test("Ignores malformed battery floor text")
    func ignoresMalformedBatteryFloor() {
        let output = """
        Sleep is DISABLED (clamshell mode active).
        Auto-restore at low% battery.
        """
        let expected = ClamshellStatus(isDisabled: true, remainingSeconds: nil)
        #expect(StatusParser.parse(output) == expected)
    }

    @Test("Returns nil for unrecognised output")
    func returnsNilForUnrecognisedOutput() {
        #expect(StatusParser.parse("command not found\n") == nil)
        #expect(StatusParser.parse("") == nil)
    }

    @Test("Ignores expired deadline line")
    func ignoresExpiredDeadlineLine() {
        let output = """
        Sleep is enabled (normal behaviour).
        Auto-restore deadline has passed; run 'clamshell off' if needed.
        """
        #expect(StatusParser.parse(output) == ClamshellStatus.idle)
    }
}

@Suite("DurationOption")
struct DurationOptionTests {
    @Test("Spans match CLI syntax")
    func spansMatchCLISyntax() {
        #expect(DurationOption.indefinite.span == nil)
        #expect(DurationOption.minutes30.span == "30m")
        #expect(DurationOption.hour1.span == "1h")
        #expect(DurationOption.hours8.span == "8h")
    }

    @Test("Lists every option exactly once")
    func everyTitledOptionIsListedOnce() {
        let titles = DurationOption.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.count == 6)
    }
}
