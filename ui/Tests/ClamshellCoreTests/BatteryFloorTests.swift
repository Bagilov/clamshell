import ClamshellCore
import Testing

@Suite("BatteryFloor")
struct BatteryFloorTests {
    @Test("Off maps to no percentage")
    func offHasNoPercent() {
        #expect(BatteryFloor.off.percent == nil)
        #expect(BatteryFloor.off.isOff)
    }

    @Test("Presets map to their percentage")
    func presetsMapToPercent() {
        #expect(BatteryFloor.preset(20)?.percent == 20)
        #expect(BatteryFloor.preset(30)?.percent == 30)
        #expect(BatteryFloor.preset(40)?.percent == 40)
        #expect(BatteryFloor.preset(50)?.percent == 50)
    }

    @Test("Preset list starts with off and is unique")
    func presetListIsWellFormed() {
        let presets = BatteryFloor.presets
        #expect(presets.first?.isOff == true)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.count == 5)
    }

    @Test("Titles describe the level or its absence")
    func titlesDescribeLevel() {
        #expect(BatteryFloor.off.title == "No battery limit")
        #expect(BatteryFloor.preset(25)?.title == "Stop at 25%")
        #expect(BatteryFloor.off.shortTitle == "no battery limit")
        #expect(BatteryFloor.preset(30)?.shortTitle == "stops at 30%")
    }

    @Test("Custom input accepts a bare number and a percent sign")
    func customAcceptsCommonInput() {
        #expect(BatteryFloor.custom("25")?.percent == 25)
        #expect(BatteryFloor.custom(" 37 ")?.percent == 37)
        #expect(BatteryFloor.custom("40%")?.percent == 40)
        #expect(BatteryFloor.custom("5")?.percent == 5)
        #expect(BatteryFloor.custom("95")?.percent == 95)
    }

    @Test("Custom input rejects out-of-range and non-numeric text")
    func customRejectsInvalidInput() {
        #expect(BatteryFloor.custom("4") == nil)
        #expect(BatteryFloor.custom("96") == nil)
        #expect(BatteryFloor.custom("0") == nil)
        #expect(BatteryFloor.custom("-10") == nil)
        #expect(BatteryFloor.custom("abc") == nil)
        #expect(BatteryFloor.custom("") == nil)
        #expect(BatteryFloor.custom("20.5") == nil)
    }

    @Test("Preset rejects out-of-range values")
    func presetRejectsOutOfRange() {
        #expect(BatteryFloor.preset(4) == nil)
        #expect(BatteryFloor.preset(96) == nil)
        #expect(BatteryFloor.preset(nil)?.isOff == true)
    }

    @Test("Identity is stable for the same level")
    func identityIsStable() {
        #expect(BatteryFloor.preset(25) == BatteryFloor.custom("25"))
        #expect(BatteryFloor.preset(25) != BatteryFloor.preset(30))
    }
}

@Suite("BatteryFloorRange")
struct BatteryFloorRangeTests {
    @Test("Contains the supported range only")
    func containsSupportedRange() {
        #expect(BatteryFloorRange.contains(5))
        #expect(BatteryFloorRange.contains(50))
        #expect(BatteryFloorRange.contains(95))
        #expect(!BatteryFloorRange.contains(4))
        #expect(!BatteryFloorRange.contains(96))
    }

    @Test("Bounds match the CLI")
    func boundsMatchCLI() {
        #expect(BatteryFloorRange.minimum == 5)
        #expect(BatteryFloorRange.maximum == 95)
    }
}
