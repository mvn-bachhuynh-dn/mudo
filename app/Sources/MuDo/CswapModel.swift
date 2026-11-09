import Foundation
import MuDoCore
import Observation
import os

/// Where a list of cswap accounts lives: cswap keeps its own accounts per machine, so the Mac
/// and each mudod server that has cswap installed are separate sources.
struct CswapSource: Identifiable, Equatable {
    /// "local" or the server's UUID.
    var id: String
    var name: String
    var accounts: [CswapAccount] = []
    var error: String?
}

/// Runs `cswap` (claude-swap) on this Mac and, through mudod's `/v1/cswap`, on each server,
/// and holds the account lists for the Accounts tab.
@MainActor
@Observable
final class CswapModel {
    private(set) var sources: [CswapSource] = []
    private(set) var loading = false
    /// "<source id>/<number>" being switched to; all rows are disabled while set.
    private(set) var switching: String?
    private(set) var binary: String?
    /// Id of the source the tab shows; falls back to the first when it is gone.
    var selectedSource = "local"
    /// Supplies the remote servers (not the managed local one) and their tokens.
    @ObservationIgnored var servers: () -> [(config: ServerConfig, token: String)] = { [] }

    @ObservationIgnored private static let log = Logger(subsystem: "dev.steve.MuDo", category: "cswap")

    init() { locate() }

    /// Something to show: cswap on this Mac, or a server that answered `/v1/cswap`.
    var available: Bool { binary != nil || !sources.isEmpty }

    /// The source the tab shows.
    var current: CswapSource? {
        sources.first { $0.id == selectedSource } ?? sources.first
    }

    func isSwitching(_ source: CswapSource, _ account: CswapAccount) -> Bool {
        switching == "\(source.id)/\(account.number)"
    }

    /// Looks for `cswap` in the fixed install locations (the app has no login-shell PATH).
    func locate() {
        // Hidden switch for screenshots: `scripts/demo` turns it off so the Mac's real account
        // list never appears next to the fake server's.
        guard UserDefaults.standard.object(forKey: "cswapLocal") as? Bool ?? true else {
            binary = nil
            return
        }
        binary = CswapPaths.firstExecutable(home: NSHomeDirectory()) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var next: [CswapSource] = []
        if let binary {
            var source = CswapSource(id: "local", name: "This Mac")
            let run = await Self.run(binary, CswapCommand.list)
            if run.status == 0 {
                do {
                    source.accounts = try CswapList.parse(Data(run.stdout.utf8)).accounts
                } catch {
                    source.error = "Unexpected cswap output"
                }
            } else {
                source.error = CswapCommand.errorLine(run.stderr.isEmpty ? run.stdout : run.stderr)
                Self.log.error("cswap list failed (\(run.status, privacy: .public))")
            }
            next.append(source)
        }
        for (config, token) in servers() {
            var source = CswapSource(id: config.id.uuidString, name: config.name)
            switch await Self.remote(config.daemonURL, token: token, path: "v1/cswap", method: "GET") {
            case .success(let data):
                do {
                    source.accounts = try CswapList.parse(data).accounts
                } catch {
                    source.error = "Unexpected cswap output"
                }
            case .failure(.notInstalled):
                continue  // an older mudod, or no cswap on that server
            case .failure(let e):
                source.error = e.message
            }
            next.append(source)
        }
        sources = next
        if !next.contains(where: { $0.id == selectedSource }), let first = next.first {
            selectedSource = first.id
        }
    }

    func switchTo(_ account: CswapAccount, in source: CswapSource) async {
        guard switching == nil else { return }
        switching = "\(source.id)/\(account.number)"
        defer { switching = nil }
        var failure: String?
        if source.id == "local" {
            if let binary {
                let run = await Self.run(binary, CswapCommand.switchTo(account.number))
                if run.status != 0 {
                    failure = CswapCommand.errorLine(run.stderr.isEmpty ? run.stdout : run.stderr)
                }
            }
        } else if let entry = servers().first(where: { $0.config.id.uuidString == source.id }) {
            let path = "v1/cswap/switch/\(account.number)"
            if case .failure(let e) = await Self.remote(entry.config.daemonURL, token: entry.token, path: path, method: "POST") {
                failure = e.message
            }
        }
        if let failure { Self.log.error("cswap switch failed: \(failure, privacy: .public)") }
        // A refresh already in flight would skip ours; wait for it so the list reflects the switch.
        while loading { try? await Task.sleep(for: .milliseconds(100)) }
        await refresh()
        if let failure, let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].error = failure
        }
    }

    // MARK: - Remote (mudod)

    private enum RemoteFailure: Error {
        case notInstalled
        case other(String)

        var message: String {
            switch self {
            case .notInstalled: "cswap not available"
            case .other(let m): m
            }
        }
    }

    private nonisolated static func remote(_ daemon: URL, token: String, path: String, method: String)
        async -> Result<Data, RemoteFailure> {
        var request = URLRequest(url: daemon.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200, 204: return .success(body)
            case 404: return .failure(.notInstalled)
            case 401: return .failure(.other("token invalid"))
            default:
                let text = String(decoding: body, as: UTF8.self)
                return .failure(.other(CswapCommand.errorLine(text.isEmpty ? "HTTP \(code)" : text)))
            }
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    // MARK: - Process

    private struct Run: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private nonisolated static func run(_ path: String, _ args: [String]) async -> Run {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(path, args))
            }
        }
    }

    /// No shell; stdin closed; killed after 20 s.
    private nonisolated static func runSync(_ path: String, _ args: [String]) -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Run(status: -1, stdout: "", stderr: "Could not run cswap: \(error.localizedDescription)")
        }
        let box = ProcessBox(process)
        let timeout = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let errData = DataBox()
        let errDone = DispatchSemaphore(value: 0)
        let errHandle = err.fileHandleForReading
        DispatchQueue.global().async {
            errData.data = errHandle.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        timeout.cancel()
        let status = process.terminationReason == .exit ? process.terminationStatus : -1
        return Run(status: status,
                   stdout: String(decoding: outData, as: UTF8.self),
                   stderr: String(decoding: errData.data, as: UTF8.self))
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Written once by the stderr reader before the semaphore signals.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
