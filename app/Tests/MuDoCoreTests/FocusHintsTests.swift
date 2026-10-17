import Foundation
import Testing
@testable import MuDoCore

@Suite struct FocusHintsTests {
    func titles(_ cwd: String, _ project: String, home: String = "/Users/dev") -> [String] {
        FocusHints.titleCandidates(cwd: cwd, project: project, home: home)
    }

    @Test func deepestThenProjectThenParentsBelowHome() {
        #expect(titles("/Users/dev/code/app/src", "app") == ["src", "app", "code"])
        #expect(titles("/Users/dev/code/app/src/ui", "app") == ["ui", "app", "src", "code"])
    }

    @Test func projectIsCwd() {
        #expect(titles("/Users/dev/code/app", "app") == ["app", "code"])
    }

    @Test func neverHomeOrAbove() {
        #expect(titles("/Users/dev", "dev") == ["dev"])
        #expect(titles("/Users/dev", "") == [])
        #expect(titles("/", "") == [])
        #expect(titles("/Users/dev/", "x", home: "/Users/dev/") == ["x"])
    }

    @Test func outsideHomeKeepsAllButParentsOfHome() {
        #expect(titles("/opt/work/app", "app") == ["app", "work", "opt"])
        // "/Users" is above home; another user's folder is not.
        #expect(titles("/Users/other/app", "app") == ["app", "other"])
    }

    @Test func dedups() {
        #expect(titles("/Users/dev/app/app/src", "app") == ["src", "app"])
    }

    @Test func bundleIDs() {
        #expect(FocusHints.bundleID(program: "iTerm.app") == "com.googlecode.iterm2")
        #expect(FocusHints.bundleID(program: "Apple_Terminal") == "com.apple.Terminal")
        #expect(FocusHints.bundleID(program: "ghostty") == "com.mitchellh.ghostty")
        #expect(FocusHints.bundleID(program: "vscode") == "com.microsoft.VSCode")
        #expect(FocusHints.bundleID(program: "tmux") == nil)
        #expect(FocusHints.bundleID(program: nil) == nil)
    }
}
