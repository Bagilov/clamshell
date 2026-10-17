import ClamshellCore
import Foundation
import Testing

@Suite("About")
struct AboutTests {
    @Test("Repository URL points at the public project")
    func repositoryURLIsCorrect() {
        #expect(About.repositoryURL.absoluteString == "https://github.com/Bagilov/clamshell")
    }

    @Test("Repository URL is HTTPS and absolute")
    func repositoryURLIsUsable() {
        #expect(About.repositoryURL.scheme == "https")
        #expect(About.repositoryURL.host != nil)
    }

    @Test("Name and summary are present for the About panel")
    func nameAndSummaryArePresent() {
        #expect(!About.name.isEmpty)
        #expect(!About.summary.isEmpty)
        #expect(About.name == "Clamshell")
    }

    @Test("Version falls back when the bundle key is missing")
    func versionFallsBack() {
        // The test bundle has no CFBundleShortVersionString, so this exercises
        // the fallback path rather than crashing.
        #expect(!About.version.isEmpty)
    }
}
