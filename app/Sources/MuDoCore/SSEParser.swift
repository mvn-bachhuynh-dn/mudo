public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental Server-Sent Events parser (WHATWG event-stream format).
/// Lines end with CRLF, LF or CR; an empty line dispatches the pending event.
public struct SSEParser: Sendable {
    private static let maxLine = 1 << 20

    private var line: [UInt8] = []
    private var afterCR = false
    private var eventName = ""
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var out: [SSEEvent] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            if byte == 0x0A || byte == 0x0D {
                afterCR = byte == 0x0D
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let event = process(text) { out.append(event) }
            } else if line.count < Self.maxLine {
                line.append(byte)
            }
        }
        return out
    }

    private mutating func process(_ text: String) -> SSEEvent? {
        if text.isEmpty {
            defer {
                eventName = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventName.isEmpty ? "message" : eventName,
                            data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring = ""
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
