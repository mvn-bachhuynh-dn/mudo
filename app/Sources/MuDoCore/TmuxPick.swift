import Foundation

/// Pure parsing of tmux output for local focus (spec 5.4).
public enum TmuxPick {
    /// `list-clients -F '#{client_activity} #{client_session} #{client_tty}'`: the tty of the most
    /// recently active client attached to `session`. Session names may contain spaces.
    public static func client(listClients: String, session: String) -> String? {
        var best: (activity: Int, tty: String)?
        for line in listClients.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 3, let activity = Int(parts[0]) else { continue }
            let name = parts[1..<(parts.count - 1)].joined(separator: " ")
            let tty = String(parts[parts.count - 1])
            guard name == session, !tty.isEmpty else { continue }
            if best == nil || activity > best!.activity { best = (activity, tty) }
        }
        return best?.tty
    }

    /// `list-panes -a -F '#{pane_tty} #{pane_id} #{socket_path}'`: the pane running on `tty`.
    public static func pane(listPanes: String, tty: String) -> (pane: String, socket: String)? {
        for line in listPanes.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == tty, !parts[1].isEmpty, !parts[2].isEmpty else { continue }
            return (String(parts[1]), String(parts[2]))
        }
        return nil
    }

    /// A well-known tmux install that exists. The recorded path comes over the network, so it is
    /// never run as given: it only moves its entry to the front when it is one of the fixed paths.
    public static func resolveBinary(recorded: String?, exists: (String) -> Bool, home: String) -> String? {
        var known = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", home + "/.local/bin/tmux", "/usr/bin/tmux"]
        if let recorded, let i = known.firstIndex(of: recorded) {
            known.insert(known.remove(at: i), at: 0)
        }
        return known.first(where: exists)
    }

    /// Whether `-S <path>` may be passed to tmux: an absolute path owned by the current user,
    /// so a socket path from the network cannot point tmux at another user's server.
    /// `owner` is the path's owner uid, nil when it cannot be read.
    public static func socketAllowed(path: String, owner: UInt32?, currentUID: UInt32) -> Bool {
        path.hasPrefix("/") && owner == currentUID
    }
}
