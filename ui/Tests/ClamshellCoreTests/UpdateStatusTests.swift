import ClamshellCore
import Foundation
import Testing

/// Decoding of `clamshell update --json`, and the strings built from it.
///
/// The same "missing keys degrade" rule as the status payload applies here, so a
/// failed check with an `error` and no `release` must decode into a usable value
/// rather than failing the decode.
@Suite("Update status decoding")
struct UpdateStatusTests {
    private func decode(_ json: String) throws -> UpdateStatus {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(UpdateStatus.self, from: data)
    }

    @Test("Decodes an available release with its installer facts")
    func decodesAvailableRelease() throws {
        let status = try decode(
            """
            {
              "current": "0.3.0",
              "latest": "0.4.0",
              "updateAvailable": true,
              "checkedAt": 1700000000,
              "fromCache": false,
              "release": {
                "version": "0.4.0",
                "tag": "v0.4.0",
                "name": "Clamshell 0.4.0",
                "prerelease": false,
                "pageUrl": "https://example.test/v0.4.0",
                "assetName": "Clamshell-0.4.0.pkg",
                "hasDigest": true
              }
            }
            """
        )
        #expect(status.updateAvailable)
        #expect(status.latest == "0.4.0")
        #expect(status.release?.version == "0.4.0")
        #expect(status.release?.assetName == "Clamshell-0.4.0.pkg")
        #expect(status.release?.hasDigest == true)
        #expect(status.failed == false)
    }

    @Test("Up to date decodes with no release")
    func decodesUpToDate() throws {
        let status = try decode(
            """
            {"current": "0.4.0", "latest": "0.4.0", "updateAvailable": false,
             "checkedAt": 1, "fromCache": true}
            """
        )
        #expect(status.updateAvailable == false)
        #expect(status.release == nil)
        #expect(status.failed == false)
        #expect(status.fromCache)
    }

    @Test("A failed check decodes as an error without a release")
    func decodesFailedCheck() throws {
        let status = try decode(
            """
            {"current": "0.3.0", "latest": null, "updateAvailable": false,
             "checkedAt": 5, "fromCache": false, "error": "offline"}
            """
        )
        #expect(status.failed)
        #expect(status.error == "offline")
        #expect(status.release == nil)
    }

    @Test("Missing keys degrade to a safe value instead of failing")
    func degradesOnMissingKeys() throws {
        let status = try decode("{}")
        #expect(status.current == "unknown")
        #expect(status.release == nil)
        #expect(status.checkedAt == 0)
    }

    @Test("A partial release decodes without losing the rest of the payload")
    func decodesPartialRelease() throws {
        let status = try decode(
            """
            {"current": "0.3.0", "updateAvailable": true, "release": {"version": "0.4.0"}}
            """
        )
        #expect(status.release?.version == "0.4.0")
        #expect(status.release?.assetName == "")
        #expect(status.release?.hasDigest == false)
    }
}

/// The menu and consent strings derived from an update status.
@Suite("Update presentation")
struct UpdatePresentationTests {
    private func release(prerelease: Bool = false, hasDigest: Bool = true) -> ReleaseInfo {
        ReleaseInfo(
            version: "0.4.0",
            tag: "v0.4.0",
            name: "Clamshell 0.4.0",
            isPrerelease: prerelease,
            pageURL: "https://example.test/v0.4.0",
            assetName: "Clamshell-0.4.0.pkg",
            hasDigest: hasDigest
        )
    }

    private func status(_ release: ReleaseInfo?, failed: Bool = false) -> UpdateStatus {
        UpdateStatus(
            current: "0.3.0",
            latest: release?.version,
            release: release,
            checkedAt: 0,
            fromCache: false,
            error: failed ? "offline" : nil
        )
    }

    @Test("Shows an install row only when a release is known")
    func updateTitleRequiresARelease() {
        #expect(UpdatePresentation.updateTitle(for: status(release())) == "Update to 0.4.0…")
        #expect(UpdatePresentation.updateTitle(for: status(nil)) == nil)
        #expect(UpdatePresentation.updateTitle(for: nil) == nil)
    }

    @Test("Names a pre-release as a beta")
    func updateTitleMarksPrerelease() {
        let title = UpdatePresentation.updateTitle(for: status(release(prerelease: true)))
        #expect(title == "Update to 0.4.0 (beta)…")
    }

    @Test("The manual check row notes a previous failure")
    func checkTitleNotesFailure() {
        #expect(UpdatePresentation.checkTitle(for: status(nil)) == "Check for Updates…")
        #expect(
            UpdatePresentation.checkTitle(for: status(nil, failed: true))
                == "Check for Updates… (last check failed)"
        )
    }

    @Test("The consent text states the version, kind and verification")
    func consentMessageDescribesTheInstall() {
        let message = UpdatePresentation.consentMessage(
            for: release(),
            current: "0.3.0"
        )
        #expect(message.contains("0.4.0"))
        #expect(message.contains("0.3.0"))
        #expect(message.contains("checksum"))
        #expect(message.contains("administrator"))
    }

    @Test("The consent text warns when there is no checksum")
    func consentMessageWarnsWithoutDigest() {
        let message = UpdatePresentation.consentMessage(
            for: release(hasDigest: false),
            current: "0.3.0"
        )
        #expect(message.contains("no checksum"))
    }
}
