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

    private var inFlight = false

    func focus(codeServer: URL, cwd: String, project: String) {
        let target = TabMatcher.targetURL(codeServer: codeServer, cwd: cwd)
        Self.log.info("focus cwd=\(cwd, privacy: .public) project=\(project, privacy: .public) target=\(target.absoluteString, privacy: .public)")
        open(target) { tabs in
            for t in tabs where TabMatcher.isUnder(codeServer: codeServer, t.url) {
                Self.log.info("code-server tab w=\(t.windowID, privacy: .public) t=\(t.tabIndex, privacy: .public) url=\(t.url, privacy: .public) title=\(t.title, privacy: .public)")
            }
            return TabMatcher.match(tabs: tabs, codeServer: codeServer, cwd: cwd, project: project).map { ($0, false) }
        }
    }

    /// Slack web: reuse a tab of `team` (navigating it to the channel or thread if needed), else a new window.
    func focusSlack(_ url: URL, team: String, channel: String, thread: String?) {
        Self.log.info("slack web focus target=\(url.absoluteString, privacy: .public)")
        open(url) { SlackLink.webTab(in: $0, team: team, channel: channel, thread: thread) }
    }

    /// Focuses the tab `pick` returns (loading `target` in it when `navigate`), else opens `target`
    /// in a new window.
    private func open(_ target: URL, pick: @escaping ([ChromeTab]) -> (tab: ChromeTab, navigate: Bool)?) {
        guard !inFlight else {
            Self.log.info("focus ignored (already in flight) target=\(target.absoluteString, privacy: .public)")
            return
        }
        inFlight = true
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
                if let (tab, navigate) = pick(tabs) {
                    Self.log.info("matched windowID=\(tab.windowID, privacy: .public) tabIndex=\(tab.tabIndex, privacy: .public) navigate=\(navigate, privacy: .public)")
                    let script = navigate ? ChromeScripts.navigate(tab, to: target) : ChromeScripts.focus(tab)
                    switch await run(script, parse: { _ in true }) {
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
        let result = await AppleScriptRunner.run(source, parse: parse)
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
