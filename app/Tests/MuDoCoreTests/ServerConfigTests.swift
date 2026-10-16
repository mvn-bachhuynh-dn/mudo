import Foundation
import Testing
@testable import MuDoCore

@Suite struct AddLinkTests {
    @Test func parsesMudodInstallLink() throws {
        let url = try #require(URL(string: "mudo://add?name=devbox&token=03b4&url=http%3A%2F%2F100.64.0.10%3A7879"))
        #expect(AddLink.parse(url) == ServerDraft(
            name: "devbox",
            daemonURL: URL(string: "http://100.64.0.10:7879")!,
            token: "03b4",
            codeServerURL: nil))
    }

    @Test func parsesCodeServer() throws {
        let url = try #require(URL(string: "mudo://add?name=a&token=t&url=http%3A%2F%2Fh%3A7879&code_server=http%3A%2F%2Fh%3A8080"))
        #expect(AddLink.parse(url)?.codeServerURL == URL(string: "http://h:8080"))
    }

    @Test func nameDefaultsToHost() throws {
        let url = try #require(URL(string: "mudo://add?token=t&url=http%3A%2F%2Fdevbox%3A7879"))
        #expect(AddLink.parse(url)?.name == "devbox")
    }

    @Test func rejectsBadLinks() throws {
        for text in [
            "https://add?token=t&url=http%3A%2F%2Fh",
            "mudo://remove?token=t&url=http%3A%2F%2Fh",
            "mudo://add?url=http%3A%2F%2Fh",
            "mudo://add?token=&url=http%3A%2F%2Fh",
            "mudo://add?token=t",
            "mudo://add?token=t&url=ftp%3A%2F%2Fh",
            "mudo://add?token=t&url=nohost",
        ] {
            #expect(AddLink.parse(try #require(URL(string: text))) == nil, "\(text)")
        }
    }
}

@Suite struct ServerConfigCodingTests {
    @Test func roundTrips() throws {
        let c = ServerConfig(id: UUID(), name: "a", daemonURL: URL(string: "http://h:7879")!,
                             codeServerURL: URL(string: "http://h:8080"))
        let data = try JSONEncoder().encode([c])
        #expect(try JSONDecoder().decode([ServerConfig].self, from: data) == [c])
    }
}
