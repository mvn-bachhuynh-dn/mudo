import Foundation

public struct Backoff: Sendable {
    public let initial: Duration
    public let maximum: Duration
    private var current: Duration?

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        self.initial = initial
        self.maximum = maximum
    }

    public mutating func next() -> Duration {
        let value = current.map { min($0 * 2, maximum) } ?? initial
        current = value
        return value
    }

    public mutating func reset() {
        current = nil
    }
}

public enum StreamError: Error, Equatable {
    case unauthorized
    case http(Int)
}

/// Opens the daemon's SSE stream. Throws `StreamError.unauthorized` on HTTP 401.
public protocol EventTransport: Sendable {
    func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error>
}

/// One live SSE connection to one mudod server, with reconnect (spec 6.6).
@MainActor
public final class ServerConnection {
    public let config: ServerConfig
    private let token: String
    private let store: SessionStore
    private let transport: any EventTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onAckRetry: @MainActor ([SessionKey]) -> Void
    private var backoff = Backoff()
    private var task: Task<Void, Never>?

    public init(config: ServerConfig, token: String, store: SessionStore, transport: any EventTransport,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onAckRetry: @escaping @MainActor ([SessionKey]) -> Void = { _ in }) {
        self.config = config
        self.token = token
        self.store = store
        self.transport = transport
        self.sleep = sleep
        self.onAckRetry = onAckRetry
    }

    public var streamURL: URL {
        config.daemonURL.appending(path: "v1/stream")
    }

    public func start() {
        guard task == nil else { return }
        store.setStatus(.connecting, for: config.id)
        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func reconnectNow() {
        guard store.status(of: config.id) != .unauthorized else { return }
        stop()
        backoff.reset()
        start()
    }

    private func run() async {
        while !Task.isCancelled {
            var connected = false
            do {
                for try await event in transport.events(url: streamURL, token: token) {
                    if Task.isCancelled { return }
                    guard let message = try? StreamMessage.decode(event: event.event, data: event.data) else {
                        continue
                    }
                    if !connected {
                        connected = true
                        backoff.reset()
                        store.setStatus(.connected, for: config.id)
                    }
                    let retries = store.apply(message, from: config.id)
                    if !retries.isEmpty { onAckRetry(retries) }
                }
            } catch StreamError.unauthorized {
                if Task.isCancelled { return }
                store.setStatus(.unauthorized, for: config.id)
                task = nil
                return
            } catch {
                // Network error or HTTP error: fall through to the retry path.
            }
            if Task.isCancelled { return }
            store.setStatus(.offline, for: config.id)
            do {
                try await sleep(backoff.next())
            } catch {
                return
            }
        }
    }
}
