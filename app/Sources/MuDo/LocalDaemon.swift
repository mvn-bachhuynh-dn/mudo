import Foundation
import MuDoCore
import os

/// A failed mudod command; `output` is what it printed (stdout and stderr).
struct LocalDaemonError: Error {
    var output: String
}

/// Installs, removes and upgrades the mudod bundled in MuDo.app (spec 3.5, 5.6).
/// `mudod install` copies itself to ~/.local/bin/mudod and (re)loads its LaunchAgent.
@MainActor
final class LocalDaemon {
    private static let log = Logger(subsystem: "dev.steve.MuDo", category: "daemon")

    private var bundled: URL? { Bundle.main.url(forResource: "mudod", withExtension: nil) }
    private var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mudod")
    }

    /// Installs the bundled daemon and returns the server to add from its link.
    func enable() async -> Result<ServerDraft, LocalDaemonError> {
        guard let bin = bundled else {
            return .failure(LocalDaemonError(output: "This MuDo build has no bundled mudod."))
        }
        let run = await Self.run(bin.path, ["install", "--link-only"])
        guard run.status == 0,
              let link = LocalDaemonLogic.link(fromInstallOutput: run.stdout),
              let draft = AddLink.parse(link) else {
            Self.log.error("mudod install failed (\(run.status, privacy: .public)): \(run.combined, privacy: .public)")
            return .failure(LocalDaemonError(output: run.combined))
        }
        if !run.stderr.isEmpty {
            Self.log.info("mudod install: \(run.stderr, privacy: .public)")
        }
        return .success(draft)
    }

    /// Removes the LaunchAgent and hooks; mudod keeps its config, state and binary.
    func disable() async -> Result<Void, LocalDaemonError> {
        let bin = bundled?.path ?? installed.path
        let run = await Self.run(bin, ["uninstall"])
        guard run.status == 0 else {
            Self.log.error("mudod uninstall failed (\(run.status, privacy: .public)): \(run.combined, privacy: .public)")
            return .failure(LocalDaemonError(output: run.combined))
        }
        return .success(())
    }

    /// Reinstalls when the bundled mudod differs from the installed one (app update).
    /// The token and port are kept, so the configured local server stays valid.
    func upgradeIfNeeded() async {
        guard let bin = bundled else { return }
        let installedURL = installed
        let needed = await Task.detached {
            LocalDaemonLogic.needsUpgrade(bundled: try? Data(contentsOf: bin),
                                          installed: try? Data(contentsOf: installedURL))
        }.value
        guard needed else { return }
        Self.log.info("upgrading the installed mudod")
        let run = await Self.run(bin.path, ["install", "--link-only"])
        if run.status != 0 {
            Self.log.error("mudod upgrade failed (\(run.status, privacy: .public)): \(run.combined, privacy: .public)")
        }
    }

    // MARK: - Process

    private struct Run: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String

        var combined: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Runs `path` with `args` (no shell) off the main actor. Install can retry launchctl
    /// for a few seconds, so the timeout is generous.
    private nonisolated static func run(_ path: String, _ args: [String]) async -> Run {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(path, args))
            }
        }
    }

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
            return Run(status: -1, stdout: "", stderr: "Could not run \(path): \(error.localizedDescription)")
        }
        let box = ProcessBox(process)
        let timeout = DispatchWorkItem {
            if box.process.isRunning { box.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        // Drain stderr concurrently so a full pipe cannot block the child.
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
