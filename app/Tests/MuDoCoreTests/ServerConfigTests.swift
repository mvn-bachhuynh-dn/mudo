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

    /// mudod builds links with Go's url.Values, which writes a space as "+" and a "+" as %2B.
    @Test func plusIsSpace() throws {
        let url = try #require(URL(string: "mudo://add?name=This+Mac&token=a%2Bb&url=http%3A%2F%2F127.0.0.1%3A7879"))
        #expect(AddLink.parse(url)?.name == "This Mac")
        #expect(AddLink.parse(url)?.token == "a+b")
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

    @Test func roundTripsManagedLocal() throws {
        let c = ServerConfig(id: UUID(), name: "This Mac", daemonURL: URL(string: "http://127.0.0.1:7879")!,
                             codeServerURL: nil, managedLocal: true)
        let data = try JSONEncoder().encode([c])
        #expect(try JSONDecoder().decode([ServerConfig].self, from: data) == [c])
    }

    /// A config saved before `managedLocal` existed still loads, as not managed.
    @Test func decodesConfigWithoutManagedLocal() throws {
        let json = #"[{"id":"6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8","name":"devbox","daemonURL":"http:\/\/100.64.0.10:7879"}]"#
        let configs = try JSONDecoder().decode([ServerConfig].self, from: Data(json.utf8))
        #expect(configs.count == 1)
        #expect(configs[0].name == "devbox")
        #expect(configs[0].codeServerURL == nil)
        #expect(!configs[0].managedLocal)
    }
}

@Suite struct ServerConfigLocalTests {
    func config(_ url: String) -> ServerConfig {
        ServerConfig(id: UUID(), name: "a", daemonURL: URL(string: url)!, codeServerURL: nil)
    }

    @Test func loopbackIsLocal() {
        for url in ["http://127.0.0.1:7879", "http://[::1]:7879", "http://localhost:7879", "http://LOCALHOST:7879"] {
            #expect(config(url).isLocal, "\(url)")
        }
    }

    @Test func remoteIsNotLocal() {
        for url in ["http://[fd7a:115c:a1e0::10]:7879", "http://100.64.0.10:7879", "http://devbox:7879", "http://127.0.0.2:7879"] {
            #expect(!config(url).isLocal, "\(url)")
        }
    }
}
