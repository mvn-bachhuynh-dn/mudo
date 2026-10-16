import AppKit
import MuDoCore
import os

@MainActor
final class ChromeTabFocuser {
    static let chromeBundleID = "com.google.Chrome"
    private static let log = Logger(subsystem: "dev.steve.MuDo", category: "focus")

    var onAutomationDenied: (() -> Void)?
    /// Called whenever a script runs successfully, i.e. Automation access is granted.
    var onAutomationAllowed: (() -> Void)?
    private let queue = DispatchQueue(label: "dev.steve.MuDo.applescript")

    private enum ScriptResult<T: Sendable>: Sendable {
        case ok(T)
        case denied
        case failed
    }

    private var inFlight = false

    func focus(codeServer: URL, cwd: String, project: String) {
        guard !inFlight else {
            Self.log.info("focus ignored (already in flight) cwd=\(cwd, privacy: .public)")
            return
        }
        inFlight = true
        start(codeServer: codeServer, cwd: cwd, project: project)
    }

    private func start(codeServer: URL, cwd: String, project: String) {
        let target = TabMatcher.targetURL(codeServer: codeServer, cwd: cwd)
        Self.log.info("focus cwd=\(cwd, privacy: .public) project=\(project, privacy: .public) target=\(target.absoluteString, privacy: .public)")
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleID) else {
            inFlight = false
            NSWorkspace.shared.open(target)
            return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).isEmpty else {
            inFlight = false
            openNewWindow(target, chrome: chrome)
            return
        }
        Task {
            defer { inFlight = false }
            let listStart = ContinuousClock.now
            let listed = await run(ChromeScripts.listTabs, parse: Self.parseTabs)
            let listMs = Int((ContinuousClock.now - listStart) / .milliseconds(1))
            switch listed {
            case .denied:
                Self.log.info("list tabs denied -> open -na")
                onAutomationDenied?()
                openNewWindow(target, chrome: chrome)
                return
            case .failed:
                Self.log.info("list tabs failed -> open -na")
                openNewWindow(target, chrome: chrome)
                return
            case let .ok(tabs):
                Self.log.info("listed \(tabs.count, privacy: .public) tabs in \(listMs, privacy: .public) ms")
                for t in tabs where TabMatcher.isUnder(codeServer: codeServer, t.url) {
                    Self.log.info("code-server tab w=\(t.windowID, privacy: .public) t=\(t.tabIndex, privacy: .public) url=\(t.url, privacy: .public) title=\(t.title, privacy: .public)")
                }
                if let tab = TabMatcher.match(tabs: tabs, codeServer: codeServer, cwd: cwd, project: project) {
                    Self.log.info("matched windowID=\(tab.windowID, privacy: .public) tabIndex=\(tab.tabIndex, privacy: .public)")
                    switch await run(ChromeScripts.focus(tab), parse: { _ in true }) {
                    case .ok:
                        Self.log.info("focused windowID=\(tab.windowID, privacy: .public) tabIndex=\(tab.tabIndex, privacy: .public)")
                        return
                    case .denied:
                        Self.log.info("focus denied -> open -na")
                        onAutomationDenied?()
                        openNewWindow(target, chrome: chrome)
                        return
                    case .failed:
                        Self.log.info("focus failed -> new window script")
                    }
                } else {
                    Self.log.info("no match -> new window script")
                }
                switch await run(ChromeScripts.newWindow(target), parse: { _ in true }) {
                case .ok:
                    Self.log.info("new window opened")
                    return
                case .denied:
                    Self.log.info("new window denied -> open -na")
                    onAutomationDenied?()
                case .failed:
                    Self.log.info("new window failed -> open -na")
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
        let result: ScriptResult<T> = await withCheckedContinuation { continuation in
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
        if case .ok = result { onAutomationAllowed?() }
        return result
    }

    /// Each item is {window id, list of URLs, list of titles}; the tab index is the 1-based position.
    nonisolated static func parseTabs(_ list: NSAppleEventDescriptor) -> [ChromeTab] {
        guard list.numberOfItems > 0 else { return [] }
        var tabs: [ChromeTab] = []
        for i in 1...list.numberOfItems {
            guard let item = list.atIndex(i), item.numberOfItems == 3,
                  let window = item.atIndex(1),
                  let urls = item.atIndex(2), let titles = item.atIndex(3),
                  urls.numberOfItems == titles.numberOfItems, urls.numberOfItems > 0 else { continue }
            for t in 1...urls.numberOfItems {
                guard let url = urls.atIndex(t)?.stringValue else { continue }
                tabs.append(ChromeTab(windowID: Int(window.int32Value), tabIndex: t, url: url,
                                      title: titles.atIndex(t)?.stringValue ?? ""))
            }
        }
        return tabs
    }
}
