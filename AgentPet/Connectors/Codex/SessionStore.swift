import Combine
import Foundation

enum TaskStatus: String, Hashable {
    case running
    case needsInput = "needs_input"
    case ready
    case interrupted
    case unknown

    var title: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Permission request observed"
        case .ready: "Ready · turn finished"
        case .interrupted: "Interrupted"
        case .unknown: "Unknown runtime state"
        }
    }
}

enum PetState: String, Equatable {
    case idle
    case typing
    case needsInput = "needs_input"
    case unknown
    case disconnected
    case syncing
    case reconnecting
    case paused

    var animationKey: String { rawValue }
}

struct SessionEvent: Decodable, Sendable {
    let event: String
    let sessionID: String?
    let turnID: String?
    let timestamp: Double
    let sequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case event
        case sessionID = "session_id"
        case turnID = "turn_id"
        case timestamp
        case sequence
    }
}

struct AppliedSessionChange: Equatable {
    let revision: Int
    let event: String
    let transition: String?
}

struct SessionState: Hashable {
    let sessionID: String
    var threadID: String?
    var title: String?
    var turnID: String
    var status: TaskStatus
    var updatedAt: Date
    var startedAt: Date?
}

struct CodexThread: Identifiable, Hashable {
    let id: String
    var title: String
    var sessionID: String?
    var source: String?
    var createdAt: Date?
    var updatedAt: Date?
}

struct DashboardTask: Identifiable {
    let id: String
    let title: String
    let status: TaskStatus
    let updatedAt: Date?
    let threadID: String?
    let source: String?
    let isLive: Bool
    let isHistorical: Bool
    let startedAt: Date?
}

@MainActor
final class SessionStore: ObservableObject {
    private struct TurnKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    @Published private(set) var sessions: [String: SessionState] = [:]
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var lastChange: AppliedSessionChange?
    private var revision = 0
    private var terminalTurns = Set<TurnKey>()
    private var terminalOrder: [TurnKey] = []
    private var permissionTurns = Set<TurnKey>()
    private var permissionOrder: [TurnKey] = []
    private var ambiguousStarts = Set<TurnKey>()
    private var ambiguousStartOrder: [TurnKey] = []
    private var ambiguousSessions = Set<String>()
    private var uncertainSessionIDs = Set<String>()

    var runningCount: Int {
        sessions.values.filter { $0.status == .running }.count
    }

    var needsInputCount: Int {
        sessions.values.filter { $0.status == .needsInput }.count
    }

    func updateThreads(_ threads: [CodexThread]) {
        self.threads = threads
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        for (sessionID, var session) in sessions {
            let thread: CodexThread?

            if let verifiedThreadID = session.threadID {
                thread = byID[verifiedThreadID]
            } else {
                let matches = threads.filter {
                    $0.id == sessionID || $0.sessionID == sessionID
                }
                thread = matches.count == 1 ? matches.first : nil
            }

            guard let thread else { continue }
            session.threadID = thread.id
            session.title = thread.title
            sessions[sessionID] = session
        }
    }

    var mappedLiveThreadIDs: Set<String> {
        Set(sessions.values.compactMap { session in
            guard session.status == .running || session.status == .needsInput else { return nil }
            return session.threadID
        })
    }

    func mapThread(sessionID: String, to thread: CodexThread) {
        guard var session = sessions[sessionID] else { return }

        if let verifiedThreadID = session.threadID {
            guard thread.id == verifiedThreadID else { return }
        } else {
            guard thread.id == sessionID || thread.sessionID == sessionID else { return }
        }

        session.threadID = thread.id
        session.title = thread.title
        sessions[sessionID] = session
    }

    func invalidateRuntime() {
        var changed = false
        for id in Array(sessions.keys) {
            guard var session = sessions[id],
                  session.status == .running || session.status == .needsInput else { continue }
            session.status = .unknown
            session.updatedAt = Date()
            sessions[id] = session
            uncertainSessionIDs.insert(id)
            changed = true
        }
        if changed {
            revision += 1
            lastChange = nil
            pruneHistory()
        }
    }

    @discardableResult
    func apply(_ event: SessionEvent) -> Bool {
        guard let sessionID = event.sessionID, !sessionID.isEmpty,
              let turnID = event.turnID, !turnID.isEmpty,
              event.timestamp.isFinite else { return false }

        let date = Date(timeIntervalSince1970: event.timestamp)
        let key = TurnKey(sessionID: sessionID, turnID: turnID)
        let current = sessions[sessionID]
        var transition: String?

        switch event.event {
        case "UserPromptSubmit":
            guard !terminalTurns.contains(key),
                  !permissionTurns.contains(key),
                  !ambiguousStarts.contains(key) else { return false }
            if let current, current.turnID == turnID { return false }
            if let current, ambiguousSessions.contains(sessionID) {
                remember(key, in: &ambiguousStarts, order: &ambiguousStartOrder)
                if current.status != .unknown {
                    var unknown = current
                    unknown.status = .unknown
                    unknown.updatedAt = date
                    sessions[sessionID] = unknown
                    return publish(event, transition: nil)
                }
                return false
            }
            if let current, current.status == .running || current.status == .needsInput {
                remember(key, in: &ambiguousStarts, order: &ambiguousStartOrder)
                ambiguousSessions.insert(sessionID)
                var unknown = current
                unknown.status = .unknown
                unknown.updatedAt = date
                sessions[sessionID] = unknown
                return publish(event, transition: nil)
            }
            if runningCount == 0 && needsInputCount == 0 { transition = "start_work" }
            sessions[sessionID] = SessionState(
                sessionID: sessionID,
                threadID: current?.threadID,
                title: current?.title,
                turnID: turnID,
                status: .running,
                updatedAt: date,
                startedAt: date
            )
            uncertainSessionIDs.remove(sessionID)

        case "PermissionRequest":
            guard !terminalTurns.contains(key), !permissionTurns.contains(key) else { return false }
            guard !uncertainSessionIDs.contains(sessionID) else { return false }
            remember(key, in: &permissionTurns, order: &permissionOrder)
            if let current, current.turnID != turnID {
                guard current.status == .running || current.status == .needsInput else { return false }
                ambiguousSessions.insert(sessionID)
                var unknown = current
                unknown.status = .unknown
                unknown.updatedAt = date
                sessions[sessionID] = unknown
                return publish(event, transition: nil)
            }
            let oldStatus = current?.status
            guard oldStatus != .needsInput else { return false }
            if oldStatus == .running { transition = "request_input" }
            sessions[sessionID] = SessionState(
                sessionID: sessionID,
                threadID: current?.threadID,
                title: current?.title,
                turnID: turnID,
                status: .needsInput,
                updatedAt: date,
                startedAt: current?.turnID == turnID ? current?.startedAt : nil
            )

        case "Stop", "Interrupt":
            guard !terminalTurns.contains(key) else { return false }
            remember(key, in: &terminalTurns, order: &terminalOrder)
            guard current == nil || current?.turnID == turnID else {
                resolveAmbiguityIfSettled(sessionID)
                return false
            }
            if ambiguousSessions.contains(sessionID) {
                resolveAmbiguityIfSettled(sessionID)
                return false
            }
            let oldStatus = current?.status
            guard oldStatus != .ready && oldStatus != .interrupted else { return false }
            let next: TaskStatus = event.event == "Stop" ? .ready : .interrupted
            if event.event == "Stop", oldStatus == .running { transition = "finish" }
            if event.event == "Interrupt", oldStatus == .running { transition = "interrupt" }
            if oldStatus == next { return false }
            ambiguousSessions.remove(sessionID)
            sessions[sessionID] = SessionState(
                sessionID: sessionID,
                threadID: current?.threadID,
                title: current?.title,
                turnID: turnID,
                status: next,
                updatedAt: date,
                startedAt: current?.startedAt
            )
            uncertainSessionIDs.remove(sessionID)

        default:
            return false
        }

        return publish(event, transition: transition)
    }

    private func publish(_ event: SessionEvent, transition: String?) -> Bool {
        revision += 1
        lastChange = AppliedSessionChange(revision: revision, event: event.event, transition: transition)
        pruneHistory()
        return true
    }

    private func remember(_ key: TurnKey, in set: inout Set<TurnKey>, order: inout [TurnKey]) {
        guard set.insert(key).inserted else { return }
        order.append(key)
        if order.count > 200 {
            let expiredCount = order.count - 200
            let expired = Array(order.prefix(expiredCount))
            order.removeFirst(expiredCount)
            set.subtract(expired)
        }
    }

    private func resolveAmbiguityIfSettled(_ sessionID: String) {
        guard ambiguousSessions.contains(sessionID),
              let current = sessions[sessionID],
              terminalTurns.contains(TurnKey(sessionID: sessionID, turnID: current.turnID)),
              !ambiguousStarts.contains(where: {
                  $0.sessionID == sessionID && !terminalTurns.contains($0)
              }) else { return }
        ambiguousSessions.remove(sessionID)
        uncertainSessionIDs.remove(sessionID)
    }

    private func pruneHistory() {
        let inactive = sessions.values
            .filter { $0.status != .running && $0.status != .needsInput }
            .sorted { $0.updatedAt > $1.updatedAt }
        for session in inactive.dropFirst(50) {
            sessions.removeValue(forKey: session.sessionID)
            ambiguousSessions.remove(session.sessionID)
            uncertainSessionIDs.remove(session.sessionID)
        }
    }

    func petState(
        isConnected: Bool,
        isConnecting: Bool,
        isReconnecting: Bool,
        isPaused: Bool
    ) -> PetState {
        if isPaused { return .paused }
        if needsInputCount > 0 { return .needsInput }
        if runningCount > 0 { return .typing }
        if isReconnecting { return .reconnecting }
        if isConnecting { return .syncing }
        if !isConnected { return .disconnected }
        if !uncertainSessionIDs.isEmpty { return .unknown }
        return .idle
    }

    var dashboardTasks: [DashboardTask] {
        let sessionTasks = sessions.values.map { session in
            let thread = session.threadID.flatMap { threadID in threads.first { $0.id == threadID } }
            return DashboardTask(
                id: "session-\(session.sessionID)",
                title: session.title ?? thread?.title ?? "Codex session",
                status: session.status,
                updatedAt: session.updatedAt,
                threadID: session.threadID,
                source: thread?.source,
                isLive: session.status == .running,
                isHistorical: false,
                startedAt: session.startedAt
            )
        }
        let sessionThreadIDs = Set(sessionTasks.compactMap(\.threadID))
        let recent = threads
            .filter { !sessionThreadIDs.contains($0.id) }
            .map {
                DashboardTask(
                    id: "thread-\($0.id)",
                    title: $0.title,
                    status: .unknown,
                    updatedAt: $0.updatedAt ?? $0.createdAt,
                    threadID: $0.id,
                    source: $0.source,
                    isLive: false,
                    isHistorical: true,
                    startedAt: nil
                )
            }
        let sorted = (sessionTasks + recent).sorted {
            if dashboardPriority($0) != dashboardPriority($1) {
                return dashboardPriority($0) < dashboardPriority($1)
            }
            return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        return Array(sorted.prefix(50))
    }

    private func dashboardPriority(_ task: DashboardTask) -> Int {
        if task.status == .needsInput { return 0 }
        if task.status == .running { return 1 }
        if !task.isHistorical && (task.status == .ready || task.status == .interrupted) { return 2 }
        if task.isHistorical { return 3 }
        return 4
    }
}
