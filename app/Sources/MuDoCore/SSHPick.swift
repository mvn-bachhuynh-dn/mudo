import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Picks the local ssh client behind a remote session (spec 5.5).
public enum SSHPick {
    /// ControlMaster processes are dropped first. Then the exact local/remote port match wins;
    /// else exactly one connection to the server's address and port (NAT may change the local port).
    public static func choose(conns: [SSHConn], terminal: TerminalInfo, isMux: (Int) -> Bool) -> SSHConn? {
        let live = conns.filter { !isMux($0.pid) }
        guard let serverPort = terminal.sshServerPort else { return nil }
        if let clientPort = terminal.sshClientPort,
           let exact = live.first(where: { $0.localPort == clientPort && $0.remotePort == serverPort }) {
            return exact
        }
        guard let serverIP = terminal.sshServerIp.flatMap(numeric) else { return nil }
        let byHost = live.filter { $0.remotePort == serverPort && numeric($0.remoteHost) == serverIP }
        return byHost.count == 1 ? byHost[0] : nil
    }

    /// Spec 5.5 rule 3: drops ControlMasters (`[mux]` in the command line), and ssh without a tty
    /// unless an editor runs it (Remote-SSH). `commandLine` is `ps -o command=` for `pid`.
    public static func discard(pid: Int, table: ProcessTable, commandLine: String?) -> Bool {
        if commandLine?.contains("[mux]") == true { return true }
        guard table.process(pid)?.tty == nil else { return false }
        if case .app(.vscodeLike)? = table.owner(of: pid) { return false }
        return true
    }

    /// The address as raw bytes, so `fd7a::10` and its expanded form compare equal. No DNS.
    static func numeric(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
