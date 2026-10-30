import ClamshellCore
import ServiceManagement
import Testing

/// Tests for the login-item status mapping.
///
/// Only the pure mapping is exercised: calling `register()` in a test would
/// change the developer's own login items, which no unit test may do.
@Suite("LoginItem")
struct LoginItemTests {
    @Test("An enabled or approval-pending registration reads as on")
    func enabledStatusesReadAsOn() {
        #expect(LoginItem.mapStatus(.enabled))
        // `requiresApproval` means the registration exists and macOS will honour
        // it once approved, so the toggle must not flip itself back off.
        #expect(LoginItem.mapStatus(.requiresApproval))
    }

    @Test("An unregistered or missing login item reads as off")
    func disabledStatusesReadAsOff() {
        #expect(LoginItem.mapStatus(.notRegistered) == false)
        #expect(LoginItem.mapStatus(.notFound) == false)
    }

    @Test("A binary without an app bundle is reported as unavailable")
    func unavailableOutsideBundle() {
        // `swift test` runs from an unbundled binary, which is exactly the case
        // that must hide the toggle rather than fail on every click.
        let bundle = Bundle.main
        let expected = bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension == "app"
        #expect(LoginItem().isAvailable == expected)
    }

    @Test("The not-bundled error explains the requirement")
    func notBundledMessage() {
        let message = LoginItem.LoginItemError.notBundled.errorDescription ?? ""
        #expect(message.contains("bundle"))
    }
}
