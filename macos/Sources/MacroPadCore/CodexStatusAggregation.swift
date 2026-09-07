import Foundation

public enum CodexLifecycleStatus: String, Codable, Sendable {
    case running
    case approval
    case completed
    case error
}

public struct CodexLifecycleEvent: Sendable {
    public let eventName: String
    public let sessionID: String
    public let turnID: String?
    public let instanceID: String
    public let isError: Bool

    public init(eventName: String, sessionID: String, turnID: String?, instanceID: String, isError: Bool) {
        self.eventName = eventName
        self.sessionID = sessionID
        self.turnID = turnID
        self.instanceID = instanceID
        self.isError = isError
    }
}

public struct CodexLifecycleAggregate: Equatable, Sendable {
    public let status: CodexLifecycleStatus?
    public let activeSessionCount: Int
    public let changed: Bool
}

public struct CodexStatusAggregator: Sendable {
    private struct SessionState: Sendable {
        var status: CodexLifecycleStatus
        var turnID: String
    }

    private struct TerminalTurn: Hashable, Sendable {
        let instanceID: String
        let sessionID: String
        let turnID: String
    }

    private var sessions: [String: SessionState] = [:]
    private var terminalTurns = Set<TerminalTurn>()
    private var stickyError = false
    private var terminalStatus: CodexLifecycleStatus?
    public private(set) var currentStatus: CodexLifecycleStatus?

    public init() {}

    public mutating func apply(_ event: CodexLifecycleEvent) -> CodexLifecycleAggregate {
        let previous = currentStatus
        let key = "\(event.instanceID):\(event.sessionID)"
        if event.eventName == "SessionStart" {
            let prefix = "\(event.instanceID):"
            sessions = sessions.filter { !$0.key.hasPrefix(prefix) || $0.key == key }
            return recalculate(previous: previous)
        }
        if event.eventName == "SessionEnd" {
            sessions.removeValue(forKey: key)
            if event.isError { stickyError = true; terminalStatus = .error }
            else { terminalStatus = .completed }
            return recalculate(previous: previous)
        }
        guard let turnID = event.turnID else { return recalculate(previous: previous) }
        let terminalKey = TerminalTurn(
            instanceID: event.instanceID, sessionID: event.sessionID, turnID: turnID)
        guard !terminalTurns.contains(terminalKey) else { return recalculate(previous: previous) }
        if event.eventName == "UserPromptSubmit" {
            stickyError = false
            terminalStatus = nil
            sessions[key] = SessionState(status: event.isError ? .error : .running, turnID: turnID)
            return recalculate(previous: previous)
        }
        guard let existing = sessions[key], existing.turnID == turnID else {
            return recalculate(previous: previous)
        }
        if event.eventName == "Stop" {
            sessions.removeValue(forKey: key)
            terminalTurns.insert(terminalKey)
            if event.isError || existing.status == .error { stickyError = true; terminalStatus = .error }
            else { terminalStatus = .completed }
        } else if event.isError {
            sessions[key] = SessionState(status: .error, turnID: turnID)
        } else if event.eventName == "PermissionRequest" {
            sessions[key] = SessionState(status: .approval, turnID: turnID)
        } else if event.eventName == "PreToolUse" || event.eventName == "PostToolUse" {
            sessions[key] = SessionState(status: .running, turnID: turnID)
        }
        return recalculate(previous: previous)
    }

    public mutating func retire(instanceID: String) -> CodexLifecycleAggregate {
        let previous = currentStatus
        let prefix = "\(instanceID):"
        sessions = sessions.filter { !$0.key.hasPrefix(prefix) }
        if sessions.isEmpty && !stickyError { terminalStatus = .completed }
        return recalculate(previous: previous)
    }

    private mutating func recalculate(previous: CodexLifecycleStatus?) -> CodexLifecycleAggregate {
        let active = sessions.values.map(\.status).max(by: { priority($0) < priority($1) })
        currentStatus = [active, stickyError ? .error : nil, sessions.isEmpty ? terminalStatus : nil]
            .compactMap { $0 }
            .max(by: { priority($0) < priority($1) })
        return CodexLifecycleAggregate(
            status: currentStatus,
            activeSessionCount: sessions.count,
            changed: currentStatus != previous)
    }

    private func priority(_ status: CodexLifecycleStatus) -> Int {
        switch status {
        case .completed: 1
        case .running: 2
        case .error: 3
        case .approval: 4
        }
    }
}
