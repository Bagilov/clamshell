import ClamshellCore
import Testing

@Suite("BatteryFloorOption")
struct BatteryFloorOptionTests {
    @Test("Off maps to no percent argument")
    func offHasNoPercent() {
        #expect(BatteryFloorOption.off.percent == nil)
    }

    @Test("Each level maps to its percentage")
    func levelsMapToPercent() {
        #expect(BatteryFloorOption.twenty.percent == 20)
        #expect(BatteryFloorOption.thirty.percent == 30)
        #expect(BatteryFloorOption.forty.percent == 40)
        #expect(BatteryFloorOption.fifty.percent == 50)
    }

    @Test("Raw values stay inside the range the CLI accepts")
    func rawValuesAreWithinCLIRange() {
        for option in BatteryFloorOption.allCases {
            #expect(option.rawValue >= 0)
            #expect(option.rawValue <= 95)
        }
    }

    @Test("Titles are unique and cover every case")
    func titlesAreUnique() {
        let titles = BatteryFloorOption.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.count == BatteryFloorOption.allCases.count)
    }

    @Test("Short title mentions the level or its absence")
    func shortTitleDescribesLevel() {
        #expect(BatteryFloorOption.off.shortTitle.contains("no battery"))
        #expect(BatteryFloorOption.thirty.shortTitle.contains("30%"))
    }

    @Test("Round-trips through the raw value reported by the CLI")
    func roundTripsFromRawValue() {
        for option in BatteryFloorOption.allCases {
            #expect(BatteryFloorOption(rawValue: option.rawValue) == option)
        }
        #expect(BatteryFloorOption(rawValue: 99) == nil)
    }
}
