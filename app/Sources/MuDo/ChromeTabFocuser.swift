import AppKit
import MuDoCore

@MainActor
final class ChromeTabFocuser {
    static let chromeBundleID = "com.google.Chrome"

    var onAutomationDenied: (() -> Void)?
    private let queue = DispatchQueue(label: "dev.steve.MuDo.applescript")

    private enum ScriptResult<T: Sendable>: Sendable {
        case ok(T)
        case denied
        case failed
    }

    func focus(codeServer: URL, cwd: String, project: String) {
        let target = TabMatcher.targetURL(codeServer: codeServer, cwd: cwd)
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID) else {
            NSWorkspace.shared.open(target)
            return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).isEmpty else {
            openNewWindow(target, chrome: chrome)
            return
        }
        Task {
            switch await run(ChromeScripts.listTabs, parse: Self.parseTabs) {
            case .denied:
                onAutomationDenied?()
                openNewWindow(target, chrome: chrome)
                return
            case .failed:
                openNewWindow(target, chrome: chrome)
                return
            case let .ok(tabs):
                if let tab = TabMatcher.match(tabs: tabs, codeServer: codeServer, cwd: cwd, project: project) {
                    switch await run(ChromeScripts.focus(tab), parse: { _ in true }) {
                    case .ok: return
                    case .denied: onAutomationDenied?()
                    case .failed: break
                    }
                }
                switch await run(ChromeScripts.newWindow(target), parse: { _ in true }) {
                case .ok: return
                case .denied: onAutomationDenied?()
                case .failed: break
                }
                openNewWindow(target, chrome: chrome)
            }
        }
    }

    private func openNewWindow(_ url: URL, chrome: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", chrome.path, "--args", "--new-window", url.absoluteString]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private func run<T: Sendable>(_ source: String,
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

    nonisolated static func parseTabs(_ list: NSAppleEventDescriptor) -> [ChromeTab] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { i in
            guard let item = list.atIndex(i), item.numberOfItems == 4,
                  let url = item.atIndex(3)?.stringValue else { return nil }
            return ChromeTab(windowID: Int(item.atIndex(1)?.int32Value ?? 0),
                             tabIndex: Int(item.atIndex(2)?.int32Value ?? 0),
                             url: url,
                             title: item.atIndex(4)?.stringValue ?? "")
        }
    }
}
