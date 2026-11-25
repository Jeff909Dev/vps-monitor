import Foundation

public enum AlertLevel: Int, Comparable, Codable, Sendable {
    case warning = 1
    case critical = 2

    public static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct Alert: Equatable, Sendable, Identifiable {
    /// Stable across polls ("disk", "swap", "service:docker"), so a notification fires once per alert.
    public var id: String
    public var level: AlertLevel
    /// For the menu bar: "Disk 99%".
    public var short: String
    /// For the popover: one sentence.
    public var sentence: String
}

/// Judges a snapshot. A table of rules, each with its tiers from most to least severe; the first tier that holds sets
/// the level. Rules earlier in the table win ties for the menu bar label. The words come from `Strings`.
public enum Health {
    public static func alerts(for snapshot: Snapshot, _ s: Strings) -> [Alert] {
        rules(for: snapshot).compactMap { $0.evaluate(snapshot, s) }
    }

    /// The alert the menu bar shows: the most severe, and of those the first in the table.
    public static func worst(_ alerts: [Alert]) -> Alert? {
        alerts.first { $0.level == .critical } ?? alerts.first
    }

    struct Tier: Sendable {
        let level: AlertLevel
        let holds: @Sendable (Snapshot) -> Bool

        static func critical(_ holds: @escaping @Sendable (Snapshot) -> Bool) -> Tier { Tier(level: .critical, holds: holds) }
        static func warning(_ holds: @escaping @Sendable (Snapshot) -> Bool) -> Tier { Tier(level: .warning, holds: holds) }
    }

    struct Rule: Sendable {
        let id: String
        let tiers: [Tier]
        let short: @Sendable (Snapshot, Strings) -> String
        let sentence: @Sendable (Snapshot, Strings) -> String

        func evaluate(_ snapshot: Snapshot, _ s: Strings) -> Alert? {
            guard let tier = tiers.first(where: { $0.holds(snapshot) }) else { return nil }
            return Alert(id: id, level: tier.level, short: short(snapshot, s), sentence: sentence(snapshot, s))
        }
    }

    /// An OOM kill this recent is news.
    static let oomWindow: Double = 3_600

    /// One rule per service, then the fixed table.
    static func rules(for snapshot: Snapshot) -> [Rule] {
        snapshot.services.map(serviceRule) + table
    }

    static func serviceRule(_ service: Service) -> Rule {
        Rule(id: "service:\(service.name)",
             tiers: [.critical { s in s.services.contains { $0.name == service.name && !$0.active } }],
             short: { _, s in s.health.serviceShort(service.name) },
             sentence: { _, s in s.health.serviceSentence(service.name) })
    }

    static let table: [Rule] = [
        Rule(id: "disk",
             tiers: [
                // Shares, not sizes, so a 25 GB disk and a 2 TB disk both warn when they are nearly full.
                .critical { $0.disk.freeFraction < 0.05 },
                .warning { $0.disk.freeFraction < 0.15 },
             ],
             short: { snap, s in s.health.diskShort(s.format.percent(snap.disk.usedFraction)) },
             sentence: { snap, s in
                 s.health.diskSentence(s.format.percent(snap.disk.usedFraction), s.format.bytes(snap.disk.freeBytes),
                                       s.format.bytes(snap.disk.totalBytes))
             }),
        Rule(id: "disk-fill",
             tiers: [.critical { ($0.disk.fullInHours ?? .infinity) < 24 }],
             short: { snap, s in s.health.fillShort(s.format.forecast(hours: snap.disk.fullInHours ?? 0)) },
             sentence: { snap, s in
                 s.health.fillSentence(snap.disk.growthBytesPerHour.map { s.format.bytes(Int64($0)) },
                                       s.format.forecast(hours: snap.disk.fullInHours ?? 0))
             }),
        Rule(id: "ram",
             tiers: [
                // 2 GB and 4 GB on a 32 GB server, and the same shares on a 4 GB one.
                .critical { $0.memory.availableFraction < 0.0625 },
                .warning { $0.memory.availableFraction < 0.125 },
             ],
             short: { snap, s in s.health.ramShort(s.format.bytes(snap.memory.availableBytes)) },
             sentence: { snap, s in
                 s.health.ramSentence(s.format.bytes(snap.memory.availableBytes),
                                      s.format.bytes(snap.memory.totalBytes))
             }),
        Rule(id: "swap",
             tiers: [.warning { $0.memory.swapFraction > 0.9 }],
             short: { snap, s in s.health.swapShort(s.format.percent(snap.memory.swapFraction)) },
             sentence: { snap, s in
                 s.health.swapSentence(s.format.percent(snap.memory.swapFraction),
                                       s.format.bytes(snap.memory.swapUsedBytes),
                                       s.format.bytes(snap.memory.swapTotalBytes))
             }),
        Rule(id: "oom",
             tiers: [.warning { recentKill(in: $0) != nil }],
             short: { snap, s in s.health.oomShort(recentKill(in: snap)?.process ?? "") },
             sentence: { snap, s in
                 guard let kill = recentKill(in: snap) else { return "" }
                 return s.health.oomSentence(kill.process, kill.pid, s.format.ago(seconds: snap.at - kill.at))
             }),
    ]

    /// The newest OOM kill of the last hour, on the server's clock.
    static func recentKill(in snapshot: Snapshot) -> OOMKill? {
        snapshot.oomKills.first { snapshot.at - $0.at <= oomWindow }
    }
}
