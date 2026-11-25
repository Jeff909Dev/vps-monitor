import Foundation

public enum MenuBarTint: Equatable, Sendable {
    case normal, warning, critical
    /// No answer from the server: gray.
    case offline
    /// No server connected yet: the plain icon.
    case neutral
}

public struct MenuBarState: Equatable, Sendable {
    public var tint: MenuBarTint
    /// Empty for icon only.
    public var title: String
    public var tooltip: String
}

/// A metric as the popover and the CLI show it: the headline, a detail line, and the alert that colors it.
public struct MetricText: Equatable, Sendable {
    public var label: String
    public var value: String
    public var detail: String
    public var level: AlertLevel?
}

/// Every string the popover, the menu bar and `vpsmon-mac status` show, so the CLI proves what the UI says. Each
/// function takes the `Strings` of the language to show.
public enum Presentation {
    // MARK: Menu bar

    public static func menuBar(_ connection: Connection, host: String, iconOnly: Bool, now: Date, _ s: Strings)
        -> MenuBarState {
        switch connection {
        case .noServer:
            return MenuBarState(tint: .neutral, title: "", tooltip: s.menuBar.noServer)
        case .connecting:
            return MenuBarState(tint: .offline, title: "", tooltip: s.menuBar.connecting(host))
        case .unreachable(let error):
            return MenuBarState(tint: .offline, title: iconOnly ? "" : "—",
                                tooltip: s.menuBar.unreachable(host, error.message(s)))
        case .live(let snapshot, _):
            let alerts = Health.alerts(for: snapshot, s)
            let worst = Health.worst(alerts)
            let tint: MenuBarTint = switch worst?.level {
            case .critical: .critical
            case .warning: .warning
            case nil: .normal
            }
            return MenuBarState(tint: tint, title: iconOnly ? "" : (worst?.short ?? sessionRatio(snapshot)),
                                tooltip: tooltip(snapshot, alerts: alerts, s))
        case .stale(let snapshot, let at, let error):
            let alerts = Health.alerts(for: snapshot, s)
            return MenuBarState(
                tint: .offline,
                title: iconOnly ? "" : (Health.worst(alerts)?.short ?? sessionRatio(snapshot)),
                tooltip: s.menuBar.stale(host, error.message(s), s.format.ago(seconds: now.timeIntervalSince(at)))
                    + "\n" + tooltip(snapshot, alerts: alerts, s))
        }
    }

    /// "1/4": busy of all Claude Code sessions; nothing on a host that runs none.
    public static func sessionRatio(_ snapshot: Snapshot) -> String {
        guard !snapshot.workers.isEmpty else { return "" }
        return "\(snapshot.workers.filter { $0.state == .busy }.count)/\(snapshot.workers.count)"
    }

    static func tooltip(_ snapshot: Snapshot, alerts: [Alert], _ s: Strings) -> String {
        let busy = snapshot.workers.filter { $0.state == .busy }.count
        let head = s.menuBar.summary(snapshot.host, s.format.percent(snapshot.rootDisk.usedFraction),
                                     s.format.bytes(snapshot.rootDisk.freeBytes))
            + (snapshot.workers.isEmpty ? "" : " · " + s.menuBar.sessions(busy, snapshot.workers.count))
        return ([head] + alerts.map(\.sentence)).joined(separator: "\n")
    }

    // MARK: Metrics

    /// Root is "disk"; another disk goes by its name.
    public static func disk(_ disk: Disk, alerts: [Alert], _ s: Strings) -> MetricText {
        var detail: [String] = []
        if let growth = disk.growthBytesPerHour {
            detail.append(growth >= 0 ? "+\(s.format.bytes(Int64(growth)))/h" : "\(s.format.bytes(Int64(growth)))/h")
        } else {
            detail.append(s.metrics.noTrend)
        }
        if let hours = disk.fullInHours { detail.append(s.metrics.fullIn(s.format.forecast(hours: hours))) }
        return MetricText(label: disk.isRoot ? s.metrics.disk : disk.name,
                          value: s.metrics.freeOf(s.format.bytes(disk.freeBytes), s.format.bytes(disk.totalBytes)),
                          detail: detail.joined(separator: " · "),
                          level: level(of: ["disk:\(disk.mount)", "disk-fill:\(disk.mount)"], in: alerts))
    }

    /// The disk's free space at each history point that recorded it, oldest first: its sparkline.
    public static func freeHistory(_ disk: Disk, _ history: [HistoryPoint]) -> [Double] {
        let capacity = Double(disk.usedBytes + disk.freeBytes)
        return history.compactMap { $0.disks[disk.mount] }.map { max(0, capacity - Double($0)) }
    }

    /// "/mnt/data · /dev/sdb · ext4": where a disk row's name comes from.
    public static func diskTooltip(_ disk: Disk) -> String {
        [disk.mount, disk.device, disk.fstype].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func memory(_ snapshot: Snapshot, alerts: [Alert], _ s: Strings) -> MetricText {
        let m = snapshot.memory
        return MetricText(label: s.metrics.memory,
                          value: s.metrics.availableOf(s.format.bytes(m.availableBytes), s.format.bytes(m.totalBytes)),
                          detail: s.metrics.swap(s.format.bytes(m.swapUsedBytes), s.format.bytes(m.swapTotalBytes),
                                                 s.format.percent(m.swapFraction)),
                          level: level(of: ["ram", "swap"], in: alerts))
    }

    public static func cpu(_ snapshot: Snapshot, _ s: Strings) -> MetricText {
        let c = snapshot.cpu
        return MetricText(label: s.metrics.cpu,
                          value: s.metrics.load(s.format.number(c.load1, decimals: 2), c.cores),
                          detail: s.metrics.loadDetail(s.format.number(c.load5, decimals: 2),
                                                       s.format.number(c.load15, decimals: 2)),
                          level: nil)
    }

    /// "up 38 d"
    public static func uptime(_ snapshot: Snapshot, _ s: Strings) -> String {
        s.metrics.uptime(s.format.duration(snapshot.uptimeSec))
    }

    static func level(of ids: Set<String>, in alerts: [Alert]) -> AlertLevel? {
        alerts.filter { ids.contains($0.id) }.map(\.level).max()
    }

    // MARK: RAM

    /// "where the 16.0 GB of RAM go"
    public static func ramTitle(_ snapshot: Snapshot, _ s: Strings) -> String {
        s.ram.title(s.format.bytes(snapshot.memory.totalBytes))
    }

    /// "node ×23": the program and how many of its processes run.
    public static func groupName(_ group: MemGroup) -> String {
        "\(group.name) ×\(group.count)"
    }

    /// A share of all the RAM: "24%", "<1%".
    public static func share(_ bytes: Int64, ofRAM memory: Memory) -> String {
        shareText(Double(bytes) / Double(max(memory.totalBytes, 1)), bytes: bytes)
    }

    /// One part of the RAM bar.
    public struct RamSegment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A program, by its place in the list: that picks its color.
            case group(MemGroup, index: Int)
            /// In use by smaller programs, the kernel and its caches.
            case other
            case available
        }

        public var kind: Kind
        public var fraction: Double
    }

    /// The RAM bar: each program's share of all the RAM, then what the rest of the used RAM holds, then what is
    /// available. The fractions add up to 1. A program's bytes count its swap too, so when the programs add up to
    /// more than the used RAM they shrink together to fit.
    public static func ramBar(_ memory: Memory) -> [RamSegment] {
        guard memory.totalBytes > 0 else { return [] }
        let total = Double(memory.totalBytes)
        let available = min(1, max(0, Double(memory.availableBytes) / total))
        let used = 1 - available
        let programs = Double(memory.groups.reduce(0) { $0 + $1.bytes }) / total
        let scale = programs > used ? used / programs : 1
        let groups = memory.groups.enumerated().map { i, group in
            RamSegment(kind: .group(group, index: i), fraction: Double(group.bytes) / total * scale)
        }
        let other = max(0, used - groups.reduce(0) { $0 + $1.fraction })
        return groups + (other > 0 ? [RamSegment(kind: .other, fraction: other)] : [])
            + [RamSegment(kind: .available, fraction: available)]
    }

    /// A command line led by its program's name rather than its path, so a truncated row still says what it runs:
    /// "/opt/google/chrome/chrome --type=renderer" → "chrome --type=renderer".
    public static func command(_ process: MemProcess) -> String {
        let parts = process.command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let program = parts.first, program.hasPrefix("/"), let name = program.split(separator: "/").last else {
            return process.command
        }
        return ([String(name)] + parts.dropFirst().map(String.init)).joined(separator: " ")
    }

    /// The inline confirmation of a process's End.
    public static func endQuestion(_ process: MemProcess, in group: MemGroup, _ s: Strings) -> String {
        s.ram.endQuestion(group.name, process.pid, process.children, s.format.bytes(process.treeBytes))
    }

    // MARK: Claude Code sessions

    /// "1 working · 3 idle · 2.4 GB"
    public static func sessionsSummary(_ workers: [Worker], _ s: Strings) -> String {
        let busy = workers.filter { $0.state == .busy }.count
        let idle = workers.filter { $0.state == .idle }.count
        let unknown = workers.count - busy - idle
        var parts = [s.sessions.working(busy), s.sessions.idle(idle)]
        if unknown > 0 { parts.append(s.sessions.unknown(unknown)) }
        parts.append(s.format.bytes(workers.reduce(0) { $0 + $1.memBytes }))
        return parts.joined(separator: " · ")
    }

    /// "working", "idle 2 d", on the server's clock.
    public static func workerState(_ worker: Worker, at now: Double, _ s: Strings) -> String {
        switch worker.state {
        case .busy: return s.sessions.stateWorking
        case .idle: return s.sessions.stateIdle(s.format.duration(now - worker.lastActivity))
        case .unknown: return s.sessions.stateUnknown
        }
    }

    /// "Close idle over 24 h (2) · frees 0.6 GB"
    public static func bulkCloseLabel(_ selection: [Worker], _ s: Strings) -> String {
        s.sessions.bulkLabel(selection.count, s.format.bytes(selection.reduce(0) { $0 + $1.memBytes }))
    }

    // MARK: Disk actions

    public static func recoverable(_ scan: Scan) -> Int64 {
        scan.actions.reduce(0) { $0 + $1.bytes }
    }

    /// "Scanned 2 h ago", "Scanning…", "Not scanned yet".
    public static func scanAge(_ scan: Scan, at now: Double, _ s: Strings) -> String {
        if scan.running { return s.disk.scanning }
        guard let at = scan.at else { return s.disk.neverScanned }
        return s.disk.scanned(s.format.ago(seconds: now - at))
    }

    // MARK: Disk map

    /// "where the 150 GB go"
    public static func mapTitle(_ snapshot: Snapshot, _ s: Strings) -> String {
        s.disk.mapTitle(s.format.bytes(snapshot.rootDisk.totalBytes))
    }

    /// A group's share of the disk, as df counts it (used + free): "28%", "<1%".
    public static func share(_ bytes: Int64, of disk: Disk) -> String {
        shareText(Double(bytes) / Double(max(disk.usedBytes + disk.freeBytes, 1)), bytes: bytes)
    }

    static func shareText(_ fraction: Double, bytes: Int64) -> String {
        bytes > 0 && fraction < 0.005 ? "<1%" : "\(Int((fraction * 100).rounded()))%"
    }

    /// "9.9 GB can be freed", or nil when nothing here can be freed.
    public static func freeable(_ group: MapGroup, _ s: Strings) -> String? {
        group.freeableBytes > 0 ? s.disk.freeable(s.format.bytes(group.freeableBytes)) : nil
    }

    /// The published disk actions that free space in a group, in the group's order (biggest share first).
    public static func actions(of group: MapGroup, in scan: Scan) -> [DiskAction] {
        group.actions.compactMap { id in scan.actions.first { $0.id == id } }
    }

    /// One part of a disk bar.
    public struct BarSegment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A group of root's disk map.
            case group(MapGroup)
            /// The used space of a disk without a map, in bytes.
            case used(Int64)
            case free
        }

        public var kind: Kind
        public var fraction: Double
    }

    /// A disk's bar, whose fractions add up to 1 (used + free, df's Use%). Root, once scanned, splits what is in use
    /// now by each group's share of the map; any other disk, and root before its first scan, shows used and free.
    public static func diskBar(_ disk: Disk, in snapshot: Snapshot) -> [BarSegment] {
        let map = snapshot.scan.map
        let free = BarSegment(kind: .free, fraction: disk.freeFraction)
        guard disk.isRoot, map.usedBytes > 0, !map.groups.isEmpty else {
            return [BarSegment(kind: .used(disk.usedBytes), fraction: disk.usedFraction), free]
        }
        return map.groups.map {
            BarSegment(kind: .group($0), fraction: disk.usedFraction * Double($0.bytes) / Double(map.usedBytes))
        } + [free]
    }

    /// Up to `limit` labels for the inline confirmation, and how many more there are.
    /// The first `limit` labels, and how many of `total` (all of them, when the server listed only some) are not shown.
    public static func confirmationList(_ labels: [String], total: Int? = nil, limit: Int = 8) -> (shown: [String], more: Int) {
        let shown = Array(labels.prefix(limit))
        return (shown, max(0, max(total ?? 0, labels.count) - shown.count))
    }

    // MARK: Version

    /// The server runs an older vpsmon than the one this app carries.
    public static func isOutdated(_ snapshot: Snapshot, appVersion: String) -> Bool {
        Version(snapshot.version) < Version(appVersion)
    }

    // MARK: Setup

    /// One line for a setup state: what Settings shows under Connect, and what `vpsmon-mac install` prints.
    public static func setupLine(_ state: SetupState, host: String, _ s: Strings) -> String {
        switch state {
        case .idle: return s.settings.requirements
        case .testing: return s.setup.testing(host)
        case .connected(let snapshot):
            return s.setup.connected(snapshot.host, snapshot.version, s.format.percent(snapshot.rootDisk.usedFraction),
                                     snapshot.workers.count)
        case .needsInstall(.missing): return s.setup.missing(host)
        case .needsInstall(.outdated(let server, let app)): return s.setup.outdated(host, server, app)
        case .needsInstall(.schema(let schema)): return s.setup.schema(host, schema, SnapshotDecoding.schema)
        case .needsInstall(.noSudoRule): return s.setup.noSudoRule(host)
        case .installing: return s.setup.installing(host)
        case .needsPassword: return s.setup.needsPassword(host)
        case .failed(let error): return error.message(s)
        }
    }

    /// The button that cures a reason: Install on server, or Update server.
    public static func installButton(_ reason: InstallReason, _ s: Strings) -> String {
        switch reason {
        case .missing, .noSudoRule: return s.setup.install
        case .outdated, .schema: return s.setup.update
        }
    }

    // MARK: Plain text (vpsmon-mac status)

    public static func text(_ connection: Connection, host: String, now: Date, _ s: Strings) -> String {
        switch connection {
        case .noServer: return s.menuBar.noServer
        case .connecting: return s.menuBar.connecting(host)
        case .unreachable(let error): return s.menuBar.unreachable(host, error.message(s))
        case .live(let snapshot, let at):
            return text(snapshot, updated: s.popover.updated(s.format.ago(seconds: now.timeIntervalSince(at))), s)
        case .stale(let snapshot, let at, let error):
            return s.menuBar.stale(host, error.message(s), s.format.ago(seconds: now.timeIntervalSince(at))) + "\n"
                + text(snapshot, updated: s.popover.updated(s.format.ago(seconds: now.timeIntervalSince(at))), s)
        }
    }

    static func text(_ snap: Snapshot, updated: String, _ s: Strings) -> String {
        let f = s.format
        let alerts = Health.alerts(for: snap, s)
        var lines = ["\(snap.host) · \(updated) · \(uptime(snap, s)) · vpsmon \(snap.version)"]
        for alert in alerts {
            lines.append("\(alert.level == .critical ? "!!" : "! ") \(alert.sentence)")
        }
        lines.append("")
        for disk in snap.disks {
            let metric = self.disk(disk, alerts: alerts, s)
            lines.append(pad(metric.label, 9) + metric.value + " · " + metric.detail + " · " + diskTooltip(disk))
        }
        for metric in [memory(snap, alerts: alerts, s), cpu(snap, s)] {
            lines.append(pad(metric.label, 9) + metric.value + " · " + metric.detail)
        }
        if !snap.memory.groups.isEmpty {
            lines.append("")
            lines.append(ramTitle(snap, s))
            for group in snap.memory.groups {
                lines.append("  " + pad(f.bytes(group.bytes), 9) + pad(share(group.bytes, ofRAM: snap.memory), 5)
                    + groupName(group))
                for p in group.processes {
                    lines.append(String(repeating: " ", count: 18) + pad(f.bytes(p.bytes), 9) + pad(p.user, 10)
                        + command(p).prefix(48)
                        + (p.killable ? "  · \(s.ram.endFrees(f.bytes(p.treeBytes))) (\(p.id))" : ""))
                }
            }
        }
        if !snap.workers.isEmpty {
            lines.append("")
            lines.append(s.sessions.title + " · " + sessionsSummary(snap.workers, s))
            for w in snap.workers {
                let dot = w.state == .busy ? "●" : "○"
                lines.append("  \(dot) " + pad(w.name, 24) + pad(Format.shortPath(w.workspace), 20)
                    + pad(workerState(w, at: snap.at, s), 14) + pad(f.bytes(w.memBytes), 9)
                    + (w.closable ? s.sessions.closable : ""))
            }
            let bulk = BulkClose.selection(in: snap)
            if !bulk.isEmpty { lines.append("  " + bulkCloseLabel(bulk, s)) }
        }
        lines.append("")
        lines.append(s.disk.freeSection + " · " + s.disk.recoverable(f.bytes(recoverable(snap.scan))) + " · "
            + scanAge(snap.scan, at: snap.at, s))
        for action in snap.scan.actions {
            lines.append("  " + pad(f.bytes(action.bytes), 9) + action.title
                + (action.risk == .review ? " [\(s.disk.review)]" : "") + "  (\(action.id))")
        }
        if !snap.scan.map.groups.isEmpty {
            lines.append("")
            lines.append(mapTitle(snap, s) + " · " + s.disk.used(f.bytes(snap.scan.map.usedBytes)))
            for group in snap.scan.map.groups {
                lines.append("  " + pad(f.bytes(group.bytes), 9) + pad(share(group.bytes, of: snap.rootDisk), 5)
                    + group.title + (freeable(group, s).map { " · " + $0 } ?? ""))
                for child in group.children {
                    lines.append(String(repeating: " ", count: 18) + pad(f.bytes(child.bytes), 9) + child.path)
                }
                for action in actions(of: group, in: snap.scan) {
                    lines.append(String(repeating: " ", count: 18) + pad(f.bytes(action.bytes), 9)
                        + s.disk.freeButton + ": " + action.title + "  (\(action.id))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
}
