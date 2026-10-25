import ClamshellCore
import Foundation
import Testing

@Suite("JSON status decoding")
struct JSONStatusTests {
    /// Decode exactly what `clamshell status --json` emits.
    @Test("Decodes a running session with a timer and a floor")
    func decodesRunningSession() throws {
        let json = #"{"disabled": true, "floor": 30, "remainingSeconds": 600}"#
        let status = try JSONDecoder().decode(
            ClamshellStatus.self,
            from: Data(json.utf8)
        )
        #expect(status.isDisabled)
        #expect(status.remainingSeconds == 600)
        #expect(status.batteryFloor == 30)
    }

    @Test("Decodes an idle status with an explicit null deadline")
    func decodesIdleWithNullDeadline() throws {
        let json = #"{"disabled": false, "floor": 0, "remainingSeconds": null}"#
        let status = try JSONDecoder().decode(
            ClamshellStatus.self,
            from: Data(json.utf8)
        )
        #expect(status.isDisabled == false)
        #expect(status.remainingSeconds == nil)
        #expect(status.batteryFloor == nil)
    }

    @Test("A floor of zero means disabled, not a 0% floor")
    func zeroFloorIsNil() throws {
        let json = #"{"disabled": true, "floor": 0, "remainingSeconds": null}"#
        let status = try JSONDecoder().decode(
            ClamshellStatus.self,
            from: Data(json.utf8)
        )
        #expect(status.batteryFloor == nil)
    }

    @Test("Missing keys degrade to a safe status instead of failing")
    func missingKeysDegrade() throws {
        // An older CLI may not know a field; the app must still read the state.
        let status = try JSONDecoder().decode(
            ClamshellStatus.self,
            from: Data(#"{"disabled": true}"#.utf8)
        )
        #expect(status.isDisabled)
        #expect(status.remainingSeconds == nil)
        #expect(status.batteryFloor == nil)
    }

    @Test("A floor-only session reports no deadline")
    func floorOnlySession() throws {
        let json = #"{"disabled": true, "floor": 25, "remainingSeconds": null}"#
        let status = try JSONDecoder().decode(
            ClamshellStatus.self,
            from: Data(json.utf8)
        )
        #expect(status.batteryFloor == 25)
        #expect(status.remainingSeconds == nil)
    }
}
