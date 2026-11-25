import Foundation

/// What `vpsmon status` prints (docs/contract.md). Decoded once, at the SSH boundary; everything past it trusts these
/// types. Sizes are bytes, times are Unix seconds on the server's clock.
public struct Snapshot: Codable, Equatable, Sendable {
    public var schema: Int
    /// vpsmon's own version; the app offers an update when its bundled copy is newer.
    public var version: String
    public var host: String
    public var at: Double
    public var uptimeSec: Double
    public var cpu: CPU
    public var memory: Memory
    /// Every real disk on the server: root first, then the others by mount path. The decoder makes sure root is there.
    public var disks: [Disk]
    public var services: [Service]
    public var oomKills: [OOMKill]
    /// Busy first, then idle longest first: the order the popover shows.
    public var workers: [Worker]
    /// The last 24 h, oldest first.
    public var history: [HistoryPoint]
    public var scan: Scan

    /// The root filesystem: the disk map and the cleanups are about it.
    public var rootDisk: Disk { disks[0] }
}

public struct CPU: Codable, Equatable, Sendable {
    public var cores: Int
    public var load1: Double
    public var load5: Double
    public var load15: Double
}

public struct Memory: Codable, Equatable, Sendable {
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var swapTotalBytes: Int64
    public var swapUsedBytes: Int64
    /// Every process's RssAnon + VmSwap: what ending them all would give back.
    public var processBytes: Int64
    /// Where the RAM goes, by program: biggest first, at most 8.
    public var groups: [MemGroup]

    public var availableFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 1 }

    public var swapFraction: Double { swapTotalBytes > 0 ? Double(swapUsedBytes) / Double(swapTotalBytes) : 0 }
}

public struct Disk: Codable, Equatable, Sendable, Identifiable {
    public var mount: String
    /// The mount source: "/dev/sdb", a ZFS dataset.
    public var device: String
    public var fstype: String
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var freeBytes: Int64
    /// Least-squares slope of usedBytes over the last 24 h; nil with less than an hour of history.
    public var growthBytesPerHour: Double?
    /// freeBytes / growth when the disk grows, else nil.
    public var fullInHours: Double?

    /// What `df` calls Use%: used over what is usable, so root's reserved blocks don't hide a full disk.
    public var usedFraction: Double {
        let usable = usedBytes + freeBytes
        return usable > 0 ? Double(usedBytes) / Double(usable) : 0
    }

    public var freeFraction: Double { 1 - usedFraction }

    public var id: String { mount }

    public var isRoot: Bool { mount == "/" }

    /// What the popover calls a disk other than root: its mount's last component, "data" for /mnt/data.
    public var name: String { mount.split(separator: "/").last.map(String.init) ?? mount }
}

/// The processes that share one `comm`.
public struct MemGroup: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var count: Int
    /// Biggest first, at most 6.
    public var processes: [MemProcess]

    public var id: String { name }
}

public struct MemProcess: Codable, Equatable, Sendable, Identifiable {
    /// The act id, `proc:<pid>:<start>`.
    public var id: String
    public var pid: Int
    public var user: String
    /// The command line, at most 160 characters.
    public var command: String
    public var bytes: Int64
    /// This process and all its descendants: what ending it frees.
    public var treeBytes: Int64
    /// Descendants that ending it also ends.
    public var children: Int
    public var startedAt: Double
    /// The server will agree to end it.
    public var killable: Bool
}

public struct Service: Codable, Equatable, Sendable {
    public var name: String
    public var active: Bool
}

public struct OOMKill: Codable, Equatable, Sendable {
    public var at: Double
    public var process: String
    public var pid: Int
}

public enum WorkerState: String, Codable, Equatable, Sendable {
    case busy, idle, unknown

    /// The contract maps anything else to "unknown"; so does the app, should a newer server send something new.
    public init(from decoder: any Decoder) throws {
        self = WorkerState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct Worker: Codable, Equatable, Sendable, Identifiable {
    /// The act id, `worker:<pid>:<procStart>`.
    public var id: String
    public var pid: Int
    public var user: String
    public var name: String
    public var workspace: String
    public var state: WorkerState
    public var stateSince: Double
    public var lastActivity: Double
    public var startedAt: Double
    public var memBytes: Int64
    public var processes: Int
    public var sessionId: String
    public var version: String
    public var resumeCommand: String
    /// Idle for at least 30 min: the server will agree to close it.
    public var closable: Bool
}

public struct HistoryPoint: Codable, Equatable, Sendable {
    public var at: Double
    /// Used bytes by mount. A disk mounted later is missing from older points.
    public var disks: [String: Int64]
    public var memAvailableBytes: Int64
    public var swapUsedBytes: Int64
    public var busy: Int
    public var idle: Int
}

public struct Scan: Codable, Equatable, Sendable {
    /// nil until a scan has finished once.
    public var at: Double?
    public var running: Bool
    public var actions: [DiskAction]
    /// Where the used space goes; no groups until a scan has finished once.
    public var map: DiskMap
}

public enum Risk: String, Codable, Equatable, Sendable {
    case safe, review

    /// Anything the app doesn't know is shown as needing review.
    public init(from decoder: any Decoder) throws {
        self = Risk(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .review
    }
}

public struct DiskAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var bytes: Int64
    public var risk: Risk
    /// Every item the action would free; `items` shows at most 25 of them.
    public var count: Int
    /// Biggest first, at most 25.
    public var items: [ActionItem]
}

public struct ActionItem: Codable, Equatable, Sendable {
    public var label: String
    public var bytes: Int64
}

/// The used space at scan time, in blocks that add up to all of it.
public struct DiskMap: Codable, Equatable, Sendable {
    /// statvfs used bytes when the scan measured the map.
    public var usedBytes: Int64
    /// Biggest first, "rest" last; their bytes add up to usedBytes.
    public var groups: [MapGroup]
}

public struct MapGroup: Codable, Equatable, Sendable, Identifiable {
    /// A registry id ("home", "docker", "temp", "rest"…): it picks the group's color.
    public var id: String
    public var title: String
    public var hint: String
    public var bytes: Int64
    /// What the published disk actions would free here; never more than bytes.
    public var freeableBytes: Int64
    /// Ids of the published disk actions that free space here, biggest share first.
    public var actions: [String]
    /// Biggest first, at most 6.
    public var children: [MapChild]
}

public struct MapChild: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
}

/// What `vpsmon act <id>` prints on success.
public struct ActResult: Codable, Equatable, Sendable {
    public var id: String
    public var freedBytes: Int64
    public var message: String
    public var dryRun: Bool?
    public var items: [ActionItem]?
    /// Only for workers.
    public var resumeCommand: String?

    public init(id: String, freedBytes: Int64, message: String, dryRun: Bool? = nil, items: [ActionItem]? = nil,
                resumeCommand: String? = nil) {
        self.id = id
        self.freedBytes = freedBytes
        self.message = message
        self.dryRun = dryRun
        self.items = items
        self.resumeCommand = resumeCommand
    }
}

public enum SnapshotDecoding {
    /// The schema this app was written against.
    public static let schema = 3

    /// Parses `status` output. A handled server error, another schema and a shape the contract doesn't describe
    /// throw `VPSError`.
    public static func snapshot(from data: Data) throws(VPSError) -> Snapshot {
        try envelope(data)
        struct Header: Decodable { var schema: Int }
        // The schema first: another schema may not decode at all, and that should read "update", not "broken".
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw .contract(.missing("schema"))
        }
        guard header.schema == schema else { throw .schema(header.schema) }
        let snapshot = try decode(Snapshot.self, from: data)
        guard snapshot.disks.first?.isRoot == true else { throw .contract(.missing("disks[/]")) }
        return snapshot
    }

    public static func actResult(from data: Data) throws(VPSError) -> ActResult {
        try envelope(data)
        return try decode(ActResult.self, from: data)
    }

    /// Every command prints `{"ok": …}`; `ok: false` carries the server's own error, in the language it was asked for.
    public static func envelope(_ data: Data) throws(VPSError) {
        struct Envelope: Decodable {
            var ok: Bool
            var error: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw .notJSON }
        guard envelope.ok else { throw envelope.error.map(VPSError.server) ?? .serverSilent }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(VPSError) -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw .contract(problem(error))
        }
    }

    private static func problem(_ error: any Error) -> ContractProblem {
        guard let error = error as? DecodingError else { return .corrupt("") }
        switch error {
        case .keyNotFound(let key, let context): return .missing(path(context.codingPath + [key]))
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return .type(path(context.codingPath))
        case .dataCorrupted(let context): return .corrupt(path(context.codingPath))
        @unknown default: return .corrupt("")
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: ["."])
    }
}
