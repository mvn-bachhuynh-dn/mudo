import AppKit

enum ScriptResult<T: Sendable>: Sendable {
    case ok(T)
    case denied
    case failed
}

/// Runs AppleScript off the main thread. One serial queue for every focuser: `NSAppleScript` is not thread-safe.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "dev.steve.MuDo.applescript")

    /// Error -1743 (Automation not allowed) is `.denied`; any other error is `.failed`.
    static func run<T: Sendable>(_ source: String,
                                 parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> ScriptResult<T> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failed)
                    return
                }
                var error: NSDictionary?
                let output = script.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(returning: code == -1743 ? .denied : .failed)
                    return
                }
                continuation.resume(returning: .ok(parse(output)))
            }
        }
    }
}
