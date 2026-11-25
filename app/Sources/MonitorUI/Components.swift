import MonitorCore
import SwiftUI

/// A lowercase section label, with an optional faint note on the right, or under it when both don't fit on one line.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).fixedSize()
                Spacer(minLength: 0)
                if let trailing { Text(trailing).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let trailing { Text(trailing) }
            }
        }
        .lineLimit(1)
        .foregroundStyle(Tok.muted)
        .font(Typo.ui(size: 10))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Tok.border).frame(height: 0.5) }
}

struct Badge: View {
    let text: String
    var color: Color = Tok.text2

    var body: some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
            .fixedSize()
    }
}

/// Claude Usage's buttons. `destructive` turns a primary button red and a plain one's text red.
public struct ClaudeButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost }
    var kind = Kind.secondary
    var fullWidth = false
    /// 22 pt tall with small text, for buttons inside rows.
    var compact = false
    var destructive = false

    public init(kind: Kind = .secondary, fullWidth: Bool = false, compact: Bool = false, destructive: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
        self.compact = compact
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        ClaudeButton(configuration: configuration, kind: kind, fullWidth: fullWidth, compact: compact,
                     destructive: destructive)
    }
}

private struct ClaudeButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: ClaudeButtonStyle.Kind
    let fullWidth: Bool
    let compact: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8)
        configuration.label
            .font(Typo.ui(size: compact ? 10 : 11, weight: kind == .primary ? .medium : .regular))
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: compact ? 22 : 26)
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.stroke(kind == .secondary ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }

    private var lit: Bool { hovering && isEnabled }

    private var foreground: Color {
        if destructive && kind != .primary { return Tok.error }
        switch kind {
        case .primary: return .white
        case .secondary: return Tok.text
        case .ghost: return lit ? Tok.text : Tok.text2
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return (destructive ? Tok.errorStrong : Tok.claudeStrong).opacity(configuration.isPressed ? 0.85 : 1)
        case .secondary: return configuration.isPressed || lit ? Tok.surface3 : Tok.surface2
        case .ghost: return configuration.isPressed || lit ? Tok.surface2 : Color.clear
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    /// Turns the symbol while the work it started runs.
    var isSpinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !isSpinning)) { context in
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .rotationEffect(.degrees(isSpinning ? context.date.timeIntervalSinceReferenceDate * 450 : 0))
            }
            .foregroundStyle(hovering ? Tok.text : Tok.muted)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Tok.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

public struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    public init(options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(Typo.ui(size: 10))
                        .foregroundStyle(selected ? Tok.text : Tok.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Tok.bg : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

/// The CLI's ✻ spinner; still in a rendered PNG.
struct Spinner: View {
    var size: CGFloat = 11
    @Environment(\.isStill) private var isStill
    private static let frames = ["✻", "✽", "✶", "✳"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(!isStill ? Self.frames[Int(context.date.timeIntervalSinceReferenceDate * 4) % Self.frames.count] : "✻")
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(Tok.claude)
        }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Tok.muted)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(Tok.surface2))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Tok.borderStrong, lineWidth: 0.5))
    }
}

/// A 24 h line, from zero up, so a falling line toward the bottom reads "running out". Colored by the metric's
/// alert, in the accent otherwise.
struct Sparkline: View {
    /// Oldest first.
    let values: [Double]
    let maximum: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, maximum > 0 else { return }
            let inset: CGFloat = 2
            let height = size.height - inset * 2
            let step = (size.width - inset) / CGFloat(values.count - 1)
            let points = values.enumerated().map { i, value in
                CGPoint(x: CGFloat(i) * step,
                        y: inset + height * (1 - CGFloat(min(max(value / maximum, 0), 1))))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                                         lineJoin: .round))
            let end = points.last!
            context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                         with: .color(color))
            var floor = Path()
            floor.move(to: CGPoint(x: 0, y: size.height - 0.25))
            floor.addLine(to: CGPoint(x: size.width, y: size.height - 0.25))
            context.stroke(floor, with: .color(Tok.borderStrong), lineWidth: 0.5)
        }
    }
}

/// A thin bar, for CPU load against the cores.
struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3).fill(Tok.track)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 6)
    }
}

/// A thin bar of parts that add up to 1: fully rounded ends, a 2 pt gap between parts. The disk by map group, the
/// RAM by program.
struct SegmentBar: View {
    struct Part {
        var color: Color
        var fraction: Double
        var help: String
    }

    let parts: [Part]
    let label: String
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let parts = self.parts.filter { $0.fraction > 0 }
            let width = max(0, geo.size.width - gap * CGFloat(max(parts.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(parts.indices, id: \.self) { i in
                    Rectangle()
                        .fill(parts[i].color)
                        .frame(width: max(1, width * parts[i].fraction))
                        .help(parts[i].help)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// The disk split into the map's groups, then the free space.
struct DiskBar: View {
    let segments: [Presentation.BarSegment]
    @Environment(\.strings) private var s

    var body: some View {
        SegmentBar(parts: segments.map { segment in
            SegmentBar.Part(color: segment.group.map { Tok.group($0.id) } ?? Tok.track, fraction: segment.fraction,
                            help: segment.group.map { "\($0.title) · \(s.format.bytes($0.bytes))" } ?? s.disk.freeSpace)
        }, label: s.disk.barLabel)
    }
}

/// The RAM split into programs, the rest of the used RAM, then what is available.
struct RamBar: View {
    let segments: [Presentation.RamSegment]
    @Environment(\.strings) private var s

    var body: some View {
        SegmentBar(parts: segments.map { segment in
            switch segment.kind {
            case .group(let group, let index):
                SegmentBar.Part(color: Tok.program(index), fraction: segment.fraction,
                                help: "\(Presentation.groupName(group)) · \(s.format.bytes(group.bytes))")
            case .other: SegmentBar.Part(color: Tok.neutral, fraction: segment.fraction, help: s.ram.other)
            case .available: SegmentBar.Part(color: Tok.track, fraction: segment.fraction, help: s.ram.available)
            }
        }, label: s.ram.barLabel)
    }
}

// MARK: - Inline confirmation and results

/// The row expanded into "Sure? … Cancel / Free": a system alert or sheet misbehaves in a popover.
struct ConfirmPanel: View {
    let question: String
    var lines: [(String, String?)] = []
    var more = 0
    var note: String?
    let confirmTitle: String
    let cancel: () -> Void
    let confirm: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(question).fixedSize(horizontal: false, vertical: true)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Text(lines[i].0).lineLimit(1).truncationMode(.middle).foregroundStyle(Tok.text2)
                            Spacer(minLength: 4)
                            if let size = lines[i].1 { Text(size).foregroundStyle(Tok.muted).fixedSize() }
                        }
                    }
                    if more > 0 { Text(s.common.more(more)).foregroundStyle(Tok.muted) }
                }
                .font(Typo.ui(size: 10))
            }
            if let note {
                Text(note).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(s.common.cancel, action: cancel)
                    .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(ClaudeButtonStyle(kind: .primary, compact: true, destructive: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.error.opacity(0.35), lineWidth: 0.5))
    }
}

struct Working: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Spinner()
            Text(text).foregroundStyle(Tok.text2)
        }
        .font(Typo.ui(size: 10))
        .frame(height: 22)
    }
}

struct Outcome: View {
    let text: String
    let ok: Bool
    let dismiss: () -> Void
    @Environment(\.strings) private var s

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark" : "xmark.octagon.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ok ? Tok.success : Tok.error)
            Text(text)
                .foregroundStyle(ok ? Tok.text2 : Tok.error)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(s.common.ok, action: dismiss).buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
        }
        .font(Typo.ui(size: 10))
    }
}

// MARK: - Environment

private struct StringsKey: EnvironmentKey {
    static let defaultValue = Strings.en
}

/// Whether the view is drawn once into a PNG: no scrolling (the whole content shows) and nothing animates.
private struct StillKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The words of the language the app shows; the popover and Settings set it from the Monitor.
    public var strings: Strings {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }

    var isStill: Bool {
        get { self[StillKey.self] }
        set { self[StillKey.self] = newValue }
    }
}
