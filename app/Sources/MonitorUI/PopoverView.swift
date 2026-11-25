import AppKit
import MonitorCore
import SwiftUI

/// The popover's size. A ScrollView has no minimum height of its own: without a definite height the popover would
/// open as just its header and footer.
public enum Popover {
    public static let width: CGFloat = 380
    /// Read once, from the screen the app starts on: 680 pt, or less on a short screen.
    public static let height = min(680, (NSScreen.main?.visibleFrame.height ?? .infinity) - 40)
}

public struct PopoverView: View {
    public enum Clock {
        /// The app: "40 s ago" moves with the clock, and the body scrolls.
        case live
        /// A render: this instant, everything laid out at full height.
        case fixed(Date)
    }

    /// What starts open: the app opens everything closed, a render opens what it shows.
    public struct Expansion {
        /// Disk-map groups, by id.
        public var mapGroups: Set<String>
        /// The RAM breakdown under the memory row.
        public var ram: Bool
        /// Programs in the RAM breakdown, by name.
        public var ramGroups: Set<String>

        public init(mapGroups: Set<String> = [], ram: Bool = false, ramGroups: Set<String> = []) {
            self.mapGroups = mapGroups
            self.ram = ram
            self.ramGroups = ramGroups
        }
    }

    let monitor: Monitor
    let clock: Clock
    let expansion: Expansion
    let openSettings: () -> Void
    let quit: () -> Void

    public init(monitor: Monitor, clock: Clock = .live, expansion: Expansion = Expansion(),
                openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}) {
        self.monitor = monitor
        self.clock = clock
        self.expansion = expansion
        self.openSettings = openSettings
        self.quit = quit
    }

    public var body: some View {
        Group {
            switch clock {
            case .live:
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    content(now: context.date)
                        .frame(width: Popover.width, height: Popover.height, alignment: .top)
                }
            case .fixed(let now):
                content(now: now)
                    .frame(width: Popover.width, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.isStill, true)
            }
        }
        .environment(\.strings, monitor.strings)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(spacing: 0) {
            Header(monitor: monitor, now: now, openSettings: openSettings)
            Hairline()
            Scrolling {
                Dashboard(monitor: monitor, expansion: expansion, openSettings: openSettings)
            }
            Hairline()
            Footer(monitor: monitor, quit: quit)
        }
        .font(Typo.ui())
        .foregroundStyle(Tok.text)
        .background(Tok.bg)
        .overlay(alignment: .bottom) {
            if let toast = monitor.toast { Toast(text: toast) }
        }
    }
}

/// A ScrollView in the app; the plain content in a render, which can't draw a scroll view.
private struct Scrolling<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.isStill) private var isStill

    var body: some View {
        if isStill { content } else { ScrollView { content } }
    }
}

// MARK: - Header and footer

private struct Header: View {
    let monitor: Monitor
    let now: Date
    let openSettings: () -> Void
    @Environment(\.isStill) private var isStill
    @Environment(\.strings) private var s

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "server.rack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.ui(size: 12, weight: .semibold))
                Text(subline.text).font(Typo.ui(size: 10)).foregroundStyle(subline.color)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if monitor.connection != .noServer {
                IconButton(systemName: "arrow.clockwise", help: s.popover.refresh,
                           isSpinning: monitor.isFetching && !isStill) {
                    Task { await monitor.refresh() }
                }
            }
            IconButton(systemName: "slider.horizontal.3", help: s.popover.settings, action: openSettings)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 10))
    }

    private var title: String {
        monitor.snapshot?.host ?? (monitor.hostName.isEmpty ? "VPS Monitor" : monitor.hostName)
    }

    private var tint: Color {
        switch monitor.menuBar.tint {
        case .critical: return Tok.error
        case .warning: return Tok.warning
        case .normal, .neutral: return Tok.claude
        case .offline: return Tok.muted
        }
    }

    private var subline: (text: String, color: Color) {
        switch monitor.connection {
        case .noServer: return (s.popover.noServerSubline, Tok.muted)
        case .connecting: return (s.popover.connectingSubline, Tok.muted)
        case .unreachable: return (s.popover.offlineSubline, Tok.error)
        case .live(_, let at): return (s.popover.updated(s.format.ago(seconds: now.timeIntervalSince(at))), Tok.muted)
        case .stale(_, let at, _):
            return (s.popover.staleSubline(s.format.ago(seconds: now.timeIntervalSince(at))), Tok.error)
        }
    }
}

private struct Footer: View {
    let monitor: Monitor
    let quit: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        HStack(spacing: 8) {
            Text(note).foregroundStyle(Tok.muted).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: quit) {
                HStack(spacing: 5) {
                    Text(s.popover.quit)
                    KeyCap(text: "⌘Q")
                }
            }
            .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
            .keyboardShortcut("q")
        }
        .font(Typo.ui(size: 10))
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
    }

    private var note: String {
        guard monitor.connection != .noServer else { return "VPS Monitor \(monitor.appVersion)" }
        let parts = [s.popover.every(monitor.settings.interval.label)]
            + (monitor.snapshot.map { [Presentation.uptime($0, s)] } ?? [])
        return parts.joined(separator: " · ")
    }
}

private struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typo.ui(size: 10))
            .foregroundStyle(Tok.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface3))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.borderStrong, lineWidth: 0.5))
            .padding(.horizontal, 12)
            // Above the footer, which keeps Quit reachable.
            .padding(.bottom, 42)
            .transition(.opacity)
    }
}

// MARK: - Body

private struct Dashboard: View {
    let monitor: Monitor
    let expansion: PopoverView.Expansion
    let openSettings: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        switch monitor.connection {
        case .noServer:
            Welcome(connect: openSettings)
        case .connecting:
            Placeholder {
                Spinner(size: 18)
                Text(s.popover.connecting(monitor.hostName)).foregroundStyle(Tok.text2)
            }
        case .unreachable(let error):
            // vpsmon missing, too old to read, or without its sudo rule: installing is the cure, so offer it.
            let setup = monitor.updater?.state ?? SetupState.tested(.failure(error), appVersion: monitor.appVersion)
            if case .failed = setup, monitor.updater == nil {
                Placeholder {
                    Image(systemName: "network.slash").font(.system(size: 20)).foregroundStyle(Tok.muted)
                    Text(s.popover.cantReach(monitor.hostName)).fontWeight(.medium)
                    Text(error.message(s)).font(Typo.ui(size: 10)).foregroundStyle(Tok.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(s.popover.retry) { Task { await monitor.refresh() } }
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                        .padding(.top, 4)
                }
            } else {
                Placeholder {
                    Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(Tok.claude)
                    ServerUpdate(monitor: monitor, state: setup, stacked: true)
                }
            }
        case .live(let snapshot, _), .stale(let snapshot, _, _):
            let alerts = Health.alerts(for: snapshot, s)
            VStack(alignment: .leading, spacing: 0) {
                if let error = monitor.connection.error {
                    Notice(title: s.popover.offline, detail: error.message(s), actionTitle: s.popover.retry) {
                        Task { await monitor.refresh() }
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
                }
                // While vpsmon is older than the app, and while an update runs (it ends with a newer vpsmon).
                if monitor.isOutdated || monitor.updater?.state.isBusy == true {
                    OutdatedBanner(monitor: monitor, snapshot: snapshot)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
                }
                if !alerts.isEmpty { AlertList(alerts: alerts) }
                Metrics(monitor: monitor, snapshot: snapshot, alerts: alerts, expansion: expansion)
                if !snapshot.workers.isEmpty {
                    Hairline()
                    Sessions(monitor: monitor, snapshot: snapshot)
                }
                if !snapshot.scan.map.groups.isEmpty {
                    Hairline()
                    DiskMapSection(monitor: monitor, snapshot: snapshot, open: expansion.mapGroups)
                }
                Hairline()
                FreeSpace(monitor: monitor, snapshot: snapshot)
            }
        }
    }

}

/// The first run: what the app does, what it needs, and the way to Settings.
private struct Welcome: View {
    let connect: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tok.claude)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Tok.claudeTint))
            VStack(alignment: .leading, spacing: 6) {
                Text(s.welcome.title).font(Typo.ui(size: 12, weight: .semibold))
                Text(s.welcome.body).foregroundStyle(Tok.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: s.welcome.needsTitle)
                ForEach(s.welcome.needs, id: \.self) { need in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tok.claude)
                        Text(need).foregroundStyle(Tok.text2)
                    }
                }
            }
            Button(s.welcome.connect, action: connect)
                .buttonStyle(ClaudeButtonStyle(kind: .primary, fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            Text(s.welcome.note).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 24, trailing: 20))
    }
}

private struct Placeholder<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
    }
}

private struct Notice: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Tok.error)
                Text(detail).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(actionTitle, action: action).buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.error.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.error.opacity(0.35), lineWidth: 0.5))
    }
}

/// Install or update vpsmon on the watched server, with what came of it.
private struct ServerUpdate: View {
    let monitor: Monitor
    let state: SetupState
    var prominent = true
    var stacked = false

    var body: some View {
        SetupStatus(state: state, host: monitor.hostName,
                    install: { Task { await monitor.updateServer() } },
                    checkAgain: { Task { await monitor.checkServerAgain() } },
                    copy: { monitor.copy($0) },
                    retry: { Task { await monitor.updateServer() } },
                    prominent: prominent, stacked: stacked)
    }
}

/// The server runs an older vpsmon than the app carries: a quiet line and the button that updates it.
private struct OutdatedBanner: View {
    let monitor: Monitor
    let snapshot: Snapshot

    var body: some View {
        let state = monitor.updater?.state
            ?? .needsInstall(.outdated(server: snapshot.version, app: monitor.appVersion))
        ServerUpdate(monitor: monitor, state: state, prominent: false)
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

private struct AlertList: View {
    let alerts: [MonitorCore.Alert]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(alerts) { alert in
                let color = Tok.level(alert.level)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: alert.level == .critical ? "exclamationmark.octagon.fill"
                                                               : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                    Text(alert.sentence)
                        .foregroundStyle(Tok.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35), lineWidth: 0.5))
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
    }
}

// MARK: - Metrics

private struct Metrics: View {
    let monitor: Monitor
    let snapshot: Snapshot
    let alerts: [MonitorCore.Alert]
    @State private var ramOpen: Bool
    @State private var openPrograms: Set<String>
    @Environment(\.strings) private var s

    init(monitor: Monitor, snapshot: Snapshot, alerts: [MonitorCore.Alert], expansion: PopoverView.Expansion) {
        self.monitor = monitor
        self.snapshot = snapshot
        self.alerts = alerts
        _ramOpen = State(initialValue: expansion.ram)
        _openPrograms = State(initialValue: expansion.ramGroups)
    }

    var body: some View {
        let memory = Presentation.memory(snapshot, alerts: alerts, s)
        let cpu = Presentation.cpu(snapshot, s)
        VStack(spacing: 12) {
            ForEach(snapshot.disks) { disk in
                let metric = Presentation.disk(disk, alerts: alerts, s)
                let free = Presentation.freeHistory(disk, snapshot.history)
                VStack(alignment: .leading, spacing: 7) {
                    MetricRow(metric: metric) {
                        Sparkline(values: free, maximum: (free.max() ?? Double(disk.totalBytes)) * 1.08,
                                  color: Tok.level(metric.level, otherwise: Tok.claude))
                    }
                    .help(Presentation.diskTooltip(disk))
                    DiskBar(segments: Presentation.diskBar(disk, in: snapshot)).padding(.leading, 54)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                MetricRow(metric: memory, isOpen: snapshot.memory.groups.isEmpty ? nil : ramOpen,
                          toggle: { ramOpen.toggle() }) {
                    Sparkline(values: snapshot.history.map { Double($0.memAvailableBytes) },
                              maximum: Double(snapshot.memory.totalBytes),
                              color: Tok.level(memory.level, otherwise: Tok.claude))
                }
                if !snapshot.memory.groups.isEmpty {
                    RamBar(segments: Presentation.ramBar(snapshot.memory)).padding(.leading, 54)
                }
                if ramOpen && !snapshot.memory.groups.isEmpty {
                    RamSection(monitor: monitor, snapshot: snapshot, open: $openPrograms)
                        .padding(.top, 4)
                }
            }
            MetricRow(metric: cpu) {
                let load = snapshot.cpu.load1 / Double(max(snapshot.cpu.cores, 1))
                Meter(fraction: load, color: load > 1 ? Tok.warning : Tok.claude)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }
}

private struct MetricRow<Chart: View>: View {
    let metric: MetricText
    /// nil: the row doesn't open. Otherwise whether what it opens shows.
    var isOpen: Bool?
    var toggle: () -> Void = {}
    @ViewBuilder let chart: Chart
    @Environment(\.strings) private var s

    var body: some View {
        if let isOpen {
            Button(action: toggle) { row(isOpen: isOpen).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(s.metrics.showRAM)
        } else {
            row(isOpen: nil)
        }
    }

    private func row(isOpen: Bool?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(metric.label).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
                        .truncationMode(.middle)
                        .frame(width: 54, alignment: .leading)
                    Text(metric.value).fontWeight(.medium)
                    if let isOpen {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Tok.faint)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .padding(.leading, 6)
                    }
                }
                Text(metric.detail)
                    .font(Typo.ui(size: 10))
                    .foregroundStyle(Tok.level(metric.level, otherwise: Tok.muted))
                    .padding(.leading, 54)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            chart.frame(width: 84, height: 26)
        }
    }
}

// MARK: - RAM

/// Where the RAM goes: each program, its share, and once open its biggest processes with End.
private struct RamSection: View {
    let monitor: Monitor
    let snapshot: Snapshot
    @Binding var open: Set<String>
    @Environment(\.strings) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: Presentation.ramTitle(snapshot, s),
                         trailing: s.ram.inProcesses(s.format.bytes(snapshot.memory.processBytes)))
                .padding(.bottom, 4)
            ForEach(Array(snapshot.memory.groups.enumerated()), id: \.element.name) { index, group in
                ProgramRow(monitor: monitor, snapshot: snapshot, group: group, color: Tok.program(index),
                           isOpen: open.contains(group.name)) {
                    if open.contains(group.name) { open.remove(group.name) } else { open.insert(group.name) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

private struct ProgramRow: View {
    let monitor: Monitor
    let snapshot: Snapshot
    let group: MemGroup
    let color: Color
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                    Text(Presentation.groupName(group)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(s.format.bytes(group.bytes)).fontWeight(.medium).fixedSize()
                    Text(Presentation.share(group.bytes, ofRAM: snapshot.memory))
                        .font(Typo.ui(size: 10))
                        .foregroundStyle(Tok.muted)
                        .frame(width: 30, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tok.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.processes) { process in
                        ProcessRow(monitor: monitor, group: group, process: process)
                    }
                    if group.processes.contains(where: { process in snapshot.workers.contains { $0.pid == process.pid } }) {
                        Text(s.ram.sessionsClose).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProcessRow: View {
    let monitor: Monitor
    let group: MemGroup
    let process: MemProcess
    @Environment(\.strings) private var s

    var body: some View {
        let state = monitor.state(of: process.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    // Program and first arguments tell processes apart; the rest is in the help tag.
                    Text(Presentation.command(process)).foregroundStyle(Tok.text2).truncationMode(.tail)
                    Text(verbatim: "\(process.user) · pid \(process.pid)").foregroundStyle(Tok.muted)
                }
                .lineLimit(1)
                .help(process.command)
                Spacer(minLength: 4)
                Text(s.format.bytes(process.bytes)).foregroundStyle(Tok.text2).fixedSize()
                trailing(state).frame(minWidth: 64, alignment: .trailing)
            }
            .font(Typo.ui(size: 10))
            .padding(.vertical, 2)
            switch state {
            case .confirming:
                ConfirmPanel(question: Presentation.endQuestion(process, in: group, s),
                             confirmTitle: s.ram.endConfirm(s.format.bytes(process.treeBytes)),
                             cancel: { monitor.cancel(process.id) },
                             confirm: { Task { await monitor.perform(process.id) } })
                    .padding(.bottom, 4)
            case .failed(let error):
                Outcome(text: error.message(s), ok: false) { monitor.cancel(process.id) }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func trailing(_ state: ActionState) -> some View {
        switch state {
        case .running:
            Spinner()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.success)
        case .idle where process.killable, .failed where process.killable:
            endButton.disabled(monitor.isActing)
        case .confirming:
            // Keeps the button's width, so the size stays in its column while the row confirms.
            endButton.hidden()
        default:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var endButton: some View {
        Button(s.ram.end) { monitor.confirm(process.id) }
            .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true, destructive: true))
            .fixedSize()
    }
}

// MARK: - Claude Code sessions

private struct Sessions: View {
    let monitor: Monitor
    let snapshot: Snapshot
    @Environment(\.strings) private var s

    var body: some View {
        let selection = BulkClose.selection(in: snapshot)
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: s.sessions.title, trailing: Presentation.sessionsSummary(snapshot.workers, s))
                .padding(.bottom, 8)
            if !selection.isEmpty || monitor.state(of: BulkClose.id) != .idle {
                BulkCloseRow(monitor: monitor, selection: selection)
                    .padding(.bottom, 6)
            }
            ForEach(snapshot.workers) { worker in
                WorkerRow(monitor: monitor, worker: worker, at: snapshot.at)
            }
        }
        .padding(12)
    }
}

private struct BulkCloseRow: View {
    let monitor: Monitor
    let selection: [Worker]
    @Environment(\.strings) private var s

    var body: some View {
        let state = monitor.state(of: BulkClose.id)
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle:
                Button(Presentation.bulkCloseLabel(selection, s)) { monitor.confirm(BulkClose.id) }
                    .buttonStyle(ClaudeButtonStyle(kind: .secondary, fullWidth: true, compact: true, destructive: true))
                    .disabled(monitor.isActing)
            case .confirming:
                let names = Presentation.confirmationList(selection.map(\.name))
                let freed = s.format.bytes(selection.reduce(0) { $0 + $1.memBytes })
                ConfirmPanel(
                    question: s.sessions.bulkQuestion(selection.count),
                    lines: zip(names.shown, selection).map { ($0, s.format.bytes($1.memBytes)) }, more: names.more,
                    note: s.sessions.bulkNote,
                    confirmTitle: s.sessions.bulkConfirm(selection.count, freed),
                    cancel: { monitor.cancel(BulkClose.id) },
                    confirm: { Task { await monitor.performBulk() } })
            case .running:
                let finished = selection.filter {
                    switch monitor.state(of: $0.id) {
                    case .done, .failed: true
                    default: false
                    }
                }.count
                Working(text: s.sessions.bulkRunning(min(finished + 1, selection.count), selection.count))
            case .done(let freed, let message):
                Outcome(text: "\(message) · \(s.format.bytes(freed))", ok: true) { monitor.cancel(BulkClose.id) }
            case .failed(let error):
                Outcome(text: error.message(s), ok: false) { monitor.cancel(BulkClose.id) }
            }
        }
    }
}

private struct WorkerRow: View {
    let monitor: Monitor
    let worker: Worker
    let at: Double
    @Environment(\.strings) private var s

    var body: some View {
        let state = monitor.state(of: worker.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(worker.name).truncationMode(.middle)
                    HStack(spacing: 0) {
                        Text(Format.shortPath(worker.workspace)).truncationMode(.middle)
                        Text(" · ")
                        Text(Presentation.workerState(worker, at: at, s))
                            .foregroundStyle(worker.state == .busy ? Tok.success : Tok.muted)
                            .fixedSize()
                    }
                    .font(Typo.ui(size: 10))
                    .foregroundStyle(Tok.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Text(s.format.bytes(worker.memBytes))
                    .font(Typo.ui(size: 10))
                    .foregroundStyle(Tok.text2)
                    .fixedSize()
                trailing(state)
                    .frame(minWidth: 68, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                Button(s.sessions.copyResume) { monitor.copyResume(worker) }
            }
            .help(String("\(worker.user) · \(worker.workspace)"))
            switch state {
            case .confirming:
                ConfirmPanel(
                    question: s.sessions.closeQuestion(worker.name, Presentation.workerState(worker, at: at, s),
                                                       s.format.bytes(worker.memBytes)),
                    note: s.sessions.closeNote,
                    confirmTitle: s.sessions.closeConfirm,
                    cancel: { monitor.cancel(worker.id) },
                    confirm: { Task { await monitor.perform(worker.id) } })
                    .padding(.bottom, 4)
            case .failed(let error):
                Outcome(text: error.message(s), ok: false) { monitor.cancel(worker.id) }
                    .padding(.bottom, 4)
            default:
                EmptyView()
            }
        }
    }

    private var dotColor: Color {
        switch worker.state {
        case .busy: return Tok.success
        case .idle: return Tok.faint
        case .unknown: return Tok.warning
        }
    }

    @ViewBuilder
    private func trailing(_ state: ActionState) -> some View {
        switch state {
        case .running:
            Spinner()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.success)
        case .idle where worker.closable:
            Button(s.sessions.close) { monitor.confirm(worker.id) }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
                .disabled(monitor.isActing)
        default:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

// MARK: - Free space

private struct FreeSpace: View {
    let monitor: Monitor
    let snapshot: Snapshot
    @Environment(\.strings) private var s

    var body: some View {
        let scan = snapshot.scan
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: s.disk.freeSection,
                         trailing: scan.actions.isEmpty ? nil
                             : s.disk.recoverable(s.format.bytes(Presentation.recoverable(scan))))
                .padding(.bottom, 6)
            if scan.actions.isEmpty {
                Text(scan.running ? s.disk.scanningLong : scan.at == nil ? s.disk.noScanYet : s.disk.nothingToFree)
                    .foregroundStyle(Tok.muted)
                    .padding(.vertical, 4)
            }
            ForEach(scan.actions) { action in
                ActionRow(monitor: monitor, action: action, place: .list)
            }
            HStack(spacing: 0) {
                Text(monitor.isStartingScan && !scan.running ? s.disk.startingScan
                                                             : Presentation.scanAge(scan, at: snapshot.at, s))
                    .foregroundStyle(Tok.muted)
                if !scan.running && !monitor.isStartingScan {
                    Text(" · ").foregroundStyle(Tok.faint)
                    Button(s.disk.scanAgain) { Task { await monitor.rescan() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tok.claude)
                }
                Spacer(minLength: 0)
            }
            .font(Typo.ui(size: 10))
            .padding(.top, 8)
        }
        .padding(12)
    }
}

/// One disk action: in the list of everything that can be freed, or inside its group of the disk map, where only
/// its title, size and Free show. A confirmation opens only in the place it was asked from.
private struct ActionRow: View {
    let monitor: Monitor
    let action: DiskAction
    let place: Place
    @Environment(\.strings) private var s

    var body: some View {
        let state = monitor.state(of: action.id)
        let confirmingHere = state == .confirming(place)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // In the map the size and Free share the title's line, so a long title wraps instead.
                    Text(action.title).lineLimit(place == .map ? 2 : 1).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: place == .map)
                    if action.risk == .review { Badge(text: s.disk.review, color: Tok.warning) }
                    Spacer(minLength: 6)
                    Text(s.format.bytes(action.bytes)).fontWeight(.medium).fixedSize()
                    if place == .map { trailing(state, confirmingHere).frame(minWidth: 68, alignment: .trailing) }
                }
                if place == .list {
                    HStack(alignment: .top, spacing: 8) {
                        Text(action.detail)
                            .font(Typo.ui(size: 10))
                            .foregroundStyle(Tok.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        trailing(state, confirmingHere)
                            .frame(minWidth: 68, alignment: .trailing)
                    }
                }
            }
            switch state {
            case .confirming where confirmingHere:
                let items = Presentation.confirmationList(action.items.map(\.label), total: action.count)
                ConfirmPanel(
                    question: action.risk == .review ? s.disk.sureReview : s.disk.sure,
                    lines: zip(items.shown, action.items).map { ($0, s.format.bytes($1.bytes)) },
                    more: items.more,
                    confirmTitle: s.disk.freeConfirm(s.format.bytes(action.bytes)),
                    cancel: { monitor.cancel(action.id) },
                    confirm: { Task { await monitor.perform(action.id) } })
            case .done(let freed, let message):
                Outcome(text: freed > 0 ? s.disk.freed(s.format.bytes(freed), message) : message, ok: true) {
                    monitor.cancel(action.id)
                }
            case .failed(let error):
                Outcome(text: error.message(s), ok: false) { monitor.cancel(action.id) }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, place == .list ? 5 : 2)
    }

    private var freeButton: some View {
        Button(s.disk.freeButton) { monitor.confirm(action.id, in: place) }
            .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
            .fixedSize()
    }

    @ViewBuilder
    private func trailing(_ state: ActionState, _ confirmingHere: Bool) -> some View {
        switch state {
        case .running:
            Spinner()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tok.success)
        case .confirming where confirmingHere:
            // Keeps the button's width, so the size stays in its column while the row confirms.
            freeButton.hidden()
        case .idle, .failed, .confirming:
            freeButton.disabled(monitor.isActing)
        }
    }
}

// MARK: - Disk map

/// The used space at scan time, in groups that add up to all of it; a row opens to show its biggest folders and the
/// actions that free space in it.
private struct DiskMapSection: View {
    let monitor: Monitor
    let snapshot: Snapshot
    @State private var open: Set<String>
    @Environment(\.strings) private var s

    init(monitor: Monitor, snapshot: Snapshot, open: Set<String>) {
        self.monitor = monitor
        self.snapshot = snapshot
        self._open = State(initialValue: open)
    }

    var body: some View {
        let map = snapshot.scan.map
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: Presentation.mapTitle(snapshot, s), trailing: s.disk.used(s.format.bytes(map.usedBytes)))
                .padding(.bottom, 4)
            ForEach(map.groups) { group in
                MapGroupRow(monitor: monitor, group: group, snapshot: snapshot, isOpen: open.contains(group.id)) {
                    if open.contains(group.id) { open.remove(group.id) } else { open.insert(group.id) }
                }
            }
        }
        .padding(12)
    }
}

private struct MapGroupRow: View {
    let monitor: Monitor
    let group: MapGroup
    let snapshot: Snapshot
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        let color = Tok.group(group.id)
        let actions = Presentation.actions(of: group, in: snapshot.scan)
        let opens = !group.children.isEmpty || !actions.isEmpty
        VStack(alignment: .leading, spacing: 5) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(group.title).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(s.format.bytes(group.bytes)).fontWeight(.medium).fixedSize()
                            Text(Presentation.share(group.bytes, of: snapshot.rootDisk))
                                .font(Typo.ui(size: 10))
                                .foregroundStyle(Tok.muted)
                                .frame(width: 30, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(opens ? Tok.faint : Color.clear)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .frame(width: 8)
                        }
                        Text(group.hint)
                            .font(Typo.ui(size: 10))
                            .foregroundStyle(Tok.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let freeable = Presentation.freeable(group, s) {
                            Text(freeable).font(Typo.ui(size: 10)).foregroundStyle(Tok.claude)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!opens)
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(group.children, id: \.path) { child in
                        HStack(spacing: 8) {
                            Text(child.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(s.format.bytes(child.bytes)).foregroundStyle(Tok.text2).fixedSize()
                        }
                        .font(Typo.ui(size: 10))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(alignment: .leading) {
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.16))
                                    .frame(width: geo.size.width * Double(child.bytes) / Double(max(group.bytes, 1)))
                            }
                        }
                    }
                    if !actions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(actions) { action in
                                ActionRow(monitor: monitor, action: action, place: .map)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 5)
    }
}
