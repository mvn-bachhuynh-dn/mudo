import Foundation
import MuDoCore

struct URLSessionTransport: EventTransport {
    func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error> {
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
}
