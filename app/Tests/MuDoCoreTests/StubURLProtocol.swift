import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fakes HTTP for `URLSession` (use with `URLSessionConfiguration.protocolClasses`).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: (@Sendable (URLRequest) -> (Int, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static func reset() { lock.withLock { _handler = nil; _requests = [] } }

    static func session(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        reset()
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else { return }
        let (code, body) = handler(request)
        if code == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Parent of every suite that uses `StubURLProtocol`: its handler is process-global, so these
/// suites must not run in parallel with each other.
@Suite(.serialized) enum StubHTTPTests {}
