import AppKit
import MuDoCore
import Observation
import os

/// Tells the user when a newer release is on GitHub. Checks 60 s after launch, then on an
/// hourly tick once 24 h have passed since the last successful check. Never installs anything.
@MainActor
@Observable
final class Updater {
    let settings: AppSettings
    /// This app's version; not a version (e.g. `dev`) means no checks and no notice.
    let current: String
    /// True for 3 s after the brew command was copied.
    private(set) var copied = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.steve.MuDo", category: "update")

    init(settings: AppSettings,
         current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") {
        self.settings = settings
        self.current = current
    }

    /// The version to announce, or nil.
    var notice: String? {
        UpdateCheck.notice(current: current, latest: settings.latestVersion,
                           skipped: settings.skippedVersion, enabled: settings.checkForUpdates)
    }

    func start() {
        guard timer == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.checkIfDue()
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Copies the brew command for a Homebrew install, else opens the release page.
    func upgrade() {
        switch UpdateCheck.action(releaseURL: releaseURL, exists: { FileManager.default.fileExists(atPath: $0) }) {
        case .copyBrewCommand:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateCheck.brewCommand, forType: .string)
            copied = true
            copiedReset?.cancel()
            copiedReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.copied = false
            }
        case let .openRelease(url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Hides the notice for the announced version only.
    func skip() {
        if let notice { settings.skippedVersion = notice }
    }

    /// The stored release page, re-checked against MuDo's releases; else the latest release page.
    private var releaseURL: URL {
        guard let text = settings.latestReleaseURL, text.hasPrefix(UpdateCheck.releasesPrefix),
              let url = URL(string: text) else { return UpdateCheck.fallbackURL }
        return url
    }

    private func checkIfDue() {
        guard settings.checkForUpdates, !checking, AppVersion(current) != nil,
              UpdateCheck.isDue(lastCheck: settings.lastUpdateCheck, now: Date()) else { return }
        checking = true
        Task { await check() }
    }

    /// A failure (network, non-200, bad JSON) changes nothing: the next hourly tick retries.
    private func check() async {
        defer { checking = false }
        var request = URLRequest(url: UpdateCheck.endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = UpdateCheck.parse(data) else {
                Self.log.info("update check: unexpected response")
                return
            }
            settings.lastUpdateCheck = Date()
            if let have = AppVersion(current), let new = AppVersion(release.version), new > have {
                settings.latestVersion = release.version
                settings.latestReleaseURL = release.url.absoluteString
            } else {
                settings.latestVersion = nil
                settings.latestReleaseURL = nil
            }
        } catch {
            Self.log.info("update check failed: \(String(describing: error), privacy: .public)")
        }
    }
}
