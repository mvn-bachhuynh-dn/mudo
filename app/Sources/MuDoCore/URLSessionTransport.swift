import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if !os(Linux)
public struct URLSessionTransport: EventTransport {
    public init() {}

    public func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    // Idle timeout between packets; the daemon pings every 15 s.
                    request.timeoutInterval = 45
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 401 { throw StreamError.unauthorized }
                    guard code == 200 else { throw StreamError.http(code) }
                    var parser = SSEParser()
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(4096)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || byte == 0x0D {
                            for event in parser.feed(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
