import Foundation
import Testing
@testable import MuDoCore

@Suite struct IgnoreRulesTests {
    @Test func globMatchesAcrossSlashes() {
        let rules = IgnoreRules(patterns: ["*/kirocrew-workspace/_bg*"])
        #expect(rules.ignores(cwd: "/home/steve/workplace/kirocrew-workspace/_bg"))
        #expect(rules.ignores(cwd: "/home/x/kirocrew-workspace/_bg/sub"))
        #expect(!rules.ignores(cwd: "/home/steve/Projects/must-do"))
    }

    @Test func prefixGlob() {
        let rules = IgnoreRules(patterns: ["/tmp/*"])
        #expect(rules.ignores(cwd: "/tmp/claude-1000/x"))
        #expect(!rules.ignores(cwd: "/home/steve/Projects/must-do"))
    }

    @Test func literalMatchesOnlyExactly() {
        let rules = IgnoreRules(patterns: ["/a/b"])
        #expect(rules.ignores(cwd: "/a/b"))
        #expect(!rules.ignores(cwd: "/a/b/c"))
        #expect(!rules.ignores(cwd: "/x/a/b"))
    }

    @Test func blankPatternsAreIgnoredAndRegexCharsAreLiteral() {
        let rules = IgnoreRules(patterns: ["", "   ", "/a.b"])
        #expect(!rules.ignores(cwd: ""))
        #expect(!rules.ignores(cwd: "/axb"))
        #expect(rules.ignores(cwd: "/a.b"))
    }
}
