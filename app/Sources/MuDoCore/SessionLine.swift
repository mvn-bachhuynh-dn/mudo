import Foundation

/// The dim line under a session's name: why it waits, the agent's last reply
/// once the turn is over, otherwise the prompt it works on.
public enum SessionLine {
    public static func text(for s: Session) -> String {
        switch s.state {
        case .waiting:
            if let notice = s.notice, !notice.isEmpty { return notice }
        case .done, .idle, .ended:
            if let output = s.lastOutput, !output.isEmpty { return output }
        case .running:
            break
        }
        return s.lastPrompt
    }
}
