import Foundation

/// What the app knows about the server. One state, so "has a server", "has data", "is fresh" and "last error" can't
/// disagree.
public enum Connection: Equatable, Sendable {
    /// No server connected yet: the first run.
    case noServer
    /// Nothing heard yet (launch, or a new server in Settings).
    case connecting
    /// The last poll worked.
    case live(Snapshot, at: Date)
    /// The last poll failed; this is the last snapshot that arrived, and when.
    case stale(Snapshot, at: Date, error: VPSError)
    /// Polls fail and no snapshot ever arrived.
    case unreachable(error: VPSError)

    public func received(_ snapshot: Snapshot, at date: Date) -> Connection {
        .live(snapshot, at: date)
    }

    public func failed(_ error: VPSError) -> Connection {
        switch self {
        case .noServer, .connecting, .unreachable: return .unreachable(error: error)
        case .live(let snapshot, let at), .stale(let snapshot, let at, _): return .stale(snapshot, at: at, error: error)
        }
    }

    public var snapshot: Snapshot? {
        switch self {
        case .live(let snapshot, _), .stale(let snapshot, _, _): return snapshot
        case .noServer, .connecting, .unreachable: return nil
        }
    }

    /// When the snapshot arrived, on this Mac's clock.
    public var receivedAt: Date? {
        switch self {
        case .live(_, let at), .stale(_, let at, _): return at
        case .noServer, .connecting, .unreachable: return nil
        }
    }

    public var error: VPSError? {
        switch self {
        case .stale(_, _, let error), .unreachable(let error): return error
        case .noServer, .connecting, .live: return nil
        }
    }

    /// The server can't be reached right now, whether or not old numbers are on screen.
    public var isDown: Bool { error != nil }
}

/// Where a confirmation opened: a disk action shows both in its group of the disk map and in the list of everything
/// that can be freed, and only the row that was clicked expands.
public enum Place: Equatable, Sendable {
    case list, map
}

/// The UI state of one action button: a disk action, a session's Close, a process's End, or the bulk close.
public enum ActionState: Equatable, Sendable {
    case idle
    /// The row is expanded into "Sure? … Cancel / Free".
    case confirming(Place)
    case running
    case done(freedBytes: Int64, message: String)
    case failed(VPSError)

    public var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }
}

/// "Close idle over 24 h": which sessions it closes.
public enum BulkClose {
    /// Its key in the action states; can't collide with a server id (no colon-separated pid).
    public static let id = "bulk-close"
    public static let minimumIdle: Double = 24 * 3_600

    /// Idle, closable and silent for 24 h on the server's clock, in the server's order.
    public static func selection(in snapshot: Snapshot) -> [Worker] {
        snapshot.workers.filter {
            $0.state == .idle && $0.closable && snapshot.at - $0.lastActivity >= minimumIdle
        }
    }
}

/// When the app asks the server for a fresh disk scan by itself.
public enum ScanPolicy {
    public static let maxAge: Double = 6 * 3_600

    /// No scan yet, or the last one is older than six hours, and none is running.
    public static func isStale(_ scan: Scan, at now: Double) -> Bool {
        guard !scan.running else { return false }
        guard let at = scan.at else { return true }
        return now - at > maxAge
    }
}

/// What an action id points at in a snapshot. The id is the server's; this only says which row it came from.
public enum ActionTarget: Equatable, Sendable {
    case worker(Worker)
    case process(MemProcess, group: MemGroup)
    case disk(DiskAction)

    public init?(id: String, in snapshot: Snapshot) {
        if let worker = snapshot.workers.first(where: { $0.id == id }) {
            self = .worker(worker)
        } else if let action = snapshot.scan.actions.first(where: { $0.id == id }) {
            self = .disk(action)
        } else if let (process, group) = snapshot.memory.groups.lazy.compactMap({ group in
            group.processes.first { $0.id == id }.map { ($0, group) }
        }).first {
            self = .process(process, group: group)
        } else {
            return nil
        }
    }
}
