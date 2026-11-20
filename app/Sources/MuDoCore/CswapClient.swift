import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to a mudod server's cswap endpoints (`GET /v1/cswap`, `POST /v1/cswap/switch/{number}`).
public struct CswapClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// 404: no `cswap` on that server, or a mudod older than 0.13.0.
        case notAvailable
        case message(String)

        public var message: String {
            switch self {
            case .notAvailable: "cswap not available"
            case .message(let m): m
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func list(daemon: URL, token: String) async -> Result<CswapList.Result, Failure> {
        switch await send(daemon: daemon, token: token, path: "v1/cswap", method: "GET") {
        case .success(let data):
            do {
                return .success(try CswapList.parse(data))
            } catch {
                return .failure(.message("Unexpected cswap output"))
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    public func switchTo(_ number: Int, daemon: URL, token: String) async -> Result<Void, Failure> {
        await send(daemon: daemon, token: token, path: "v1/cswap/switch/\(number)", method: "POST")
            .map { _ in () }
    }

    private func send(daemon: URL, token: String, path: String, method: String) async -> Result<Data, Failure> {
        var request = URLRequest(url: daemon.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (body, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200, 204: return .success(body)
            case 404: return .failure(.notAvailable)
            case 401: return .failure(.message("token invalid"))
            default:
                let text = String(decoding: body, as: UTF8.self)
                return .failure(.message(CswapCommand.errorLine(text.isEmpty ? "HTTP \(code)" : text)))
            }
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }
}
