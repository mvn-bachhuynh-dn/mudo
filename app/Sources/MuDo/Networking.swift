import Foundation
import MuDoCore

struct APIClient: Sendable {
    /// POST /v1/sessions/{id}/ack. 404 and 409 mean there is nothing left to ack.
    func ack(daemon: URL, token: String, sessionID: String) async -> Bool {
        var request = URLRequest(url: daemon.appending(path: "v1/sessions")
            .appending(path: sessionID)
            .appending(path: "ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        return code == 204 || code == 404 || code == 409
    }

    /// GET /v1/health with the token (Settings → Test).
    func health(daemon: URL, token: String) async -> ServerCheck.Daemon {
        var request = URLRequest(url: daemon.appending(path: "v1/health"))
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            return ServerCheck.daemon(status: (response as? HTTPURLResponse)?.statusCode, body: body, error: nil)
        } catch {
            return ServerCheck.daemon(status: nil, body: nil, error: error.localizedDescription)
        }
    }

    /// Any HTTP answer from the code-server URL counts as reachable (it may be a login page).
    func probe(codeServer url: URL?) async -> ServerCheck.CodeServer {
        guard let url else { return .notSet }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ServerCheck.codeServer(status: (response as? HTTPURLResponse)?.statusCode, error: nil)
        } catch {
            return ServerCheck.codeServer(status: nil, error: error.localizedDescription)
        }
    }
}
