import Foundation
import Testing
@testable import MuDoCore

@Suite struct LocalDaemonLogicTests {
    let a = Data("mudod v1".utf8)
    let b = Data("mudod v2".utf8)

    @Test func sameDataNeedsNoUpgrade() {
        #expect(!LocalDaemonLogic.needsUpgrade(bundled: a, installed: Data(a)))
    }

    @Test func differentDataNeedsUpgrade() {
        #expect(LocalDaemonLogic.needsUpgrade(bundled: b, installed: a))
    }

    @Test func missingInstalledNeedsUpgrade() {
        #expect(LocalDaemonLogic.needsUpgrade(bundled: a, installed: nil))
    }

    @Test func missingBundledNeverUpgrades() {
        #expect(!LocalDaemonLogic.needsUpgrade(bundled: nil, installed: a))
        #expect(!LocalDaemonLogic.needsUpgrade(bundled: nil, installed: nil))
    }

    @Test func sha256MatchesKnownVectors() {
        #expect(LocalDaemonLogic.sha256Hex(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(LocalDaemonLogic.sha256Hex(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks: the padding spills into a second block.
        #expect(LocalDaemonLogic.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) ==
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func linkIsTakenFromTheLastMatchingLine() throws {
        let output = """
        mudo://add?name=This%20Mac&token=old&url=http%3A%2F%2F127.0.0.1%3A7879
        warning: port 7879 is busy, using 7880
        mudo://add?name=This%20Mac&token=t&url=http%3A%2F%2F127.0.0.1%3A7880

        """
        let link = try #require(LocalDaemonLogic.link(fromInstallOutput: output))
        #expect(link.absoluteString == "mudo://add?name=This%20Mac&token=t&url=http%3A%2F%2F127.0.0.1%3A7880")
        #expect(AddLink.parse(link)?.daemonURL.absoluteString == "http://127.0.0.1:7880")
    }

    @Test func noLinkGivesNil() {
        #expect(LocalDaemonLogic.link(fromInstallOutput: "warning: something\nmudod installed\n") == nil)
        #expect(LocalDaemonLogic.link(fromInstallOutput: "") == nil)
    }
}
