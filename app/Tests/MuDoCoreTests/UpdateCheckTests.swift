import Foundation
import Testing
@testable import MuDoCore

@Suite struct UpdateCheckTests {
    private let fallback = URL(string: "https://github.com/mvn-bachhuynh-dn/mudo/releases/latest")!

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("v1.0.0") == AppVersion("1.0.0"))
        #expect(AppVersion("1.2.3")! < AppVersion("1.2.4")!)
        #expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    @Test(arguments: ["0.5", "0.5.0-rc1", "dev", "", "v", "1.2.3.4", "a.b.c", "1..2", "-1.0.0", "+1.0.0", " 1.0.0"])
    func rejectsNonVersions(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func parsesLatestRelease() {
        let data = Data(#"{"tag_name":"v0.6.0","html_url":"https://github.com/mvn-bachhuynh-dn/mudo/releases/tag/v0.6.0"}"#.utf8)
        #expect(UpdateCheck.parse(data) == LatestRelease(
            version: "0.6.0",
            url: URL(string: "https://github.com/mvn-bachhuynh-dn/mudo/releases/tag/v0.6.0")!))
    }

    @Test func foreignReleaseURLFallsBack() {
        let data = Data(#"{"tag_name":"v0.6.0","html_url":"https://evil.example.com/mudo/releases/tag/v0.6.0"}"#.utf8)
        #expect(UpdateCheck.parse(data) == LatestRelease(version: "0.6.0", url: fallback))
        let missing = Data(#"{"tag_name":"0.6.0"}"#.utf8)
        #expect(UpdateCheck.parse(missing) == LatestRelease(version: "0.6.0", url: fallback))
    }

    @Test func badTagOrBodyIsNil() {
        #expect(UpdateCheck.parse(Data(#"{"tag_name":"v0.6.0-rc1","html_url":"https://github.com/mvn-bachhuynh-dn/mudo/releases/latest"}"#.utf8)) == nil)
        #expect(UpdateCheck.parse(Data(#"{"html_url":"https://github.com/mvn-bachhuynh-dn/mudo/releases/latest"}"#.utf8)) == nil)
        #expect(UpdateCheck.parse(Data("<html>rate limited</html>".utf8)) == nil)
    }

    @Test func dueAfterADay() {
        let now = utc(2026, 10, 20, 12, 0, 0)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
    }

    @Test func noticeOnlyForNewerUnskippedVersion() {
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.6.0", skipped: nil, enabled: true) == "0.6.0")
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.5.0", skipped: nil, enabled: true) == nil)
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.4.9", skipped: nil, enabled: true) == nil)
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.6.0", skipped: "0.6.0", enabled: true) == nil)
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.7.0", skipped: "0.6.0", enabled: true) == "0.7.0")
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "0.6.0", skipped: nil, enabled: false) == nil)
        #expect(UpdateCheck.notice(current: "dev", latest: "0.6.0", skipped: nil, enabled: true) == nil)
        #expect(UpdateCheck.notice(current: "0.5.0", latest: nil, skipped: nil, enabled: true) == nil)
        #expect(UpdateCheck.notice(current: "0.5.0", latest: "garbage", skipped: nil, enabled: true) == nil)
    }

    @Test func homebrewInstallCopiesTheCommand() {
        let url = URL(string: "https://github.com/mvn-bachhuynh-dn/mudo/releases/tag/v0.6.0")!
        for path in UpdateCheck.caskrooms {
            #expect(UpdateCheck.action(releaseURL: url, exists: { $0 == path }) == .copyBrewCommand)
        }
        #expect(UpdateCheck.action(releaseURL: url, exists: { _ in false }) == .openRelease(url))
        #expect(UpdateCheck.caskrooms == ["/opt/homebrew/Caskroom/mudo", "/usr/local/Caskroom/mudo"])
        #expect(UpdateCheck.brewCommand == "brew upgrade --cask mudo")
    }
}
