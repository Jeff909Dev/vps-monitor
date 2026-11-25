import AppKit
import MonitorCore
import SwiftUI

/// One `SetupState` as words and the buttons that move it on: Settings under Connect, and the popover's Update
/// server banner.
struct SetupStatus: View {
    let state: SetupState
    let host: String
    let install: () -> Void
    let checkAgain: () -> Void
    let copy: (String) -> Void
    /// Offered after a failure; nil hides it.
    var retry: (() -> Void)?
    /// The install button is the step everyone takes (Settings, an empty popover) rather than a quiet offer.
    var prominent = true
    /// The words above the buttons, centered: the popover's placeholder.
    var stacked = false
    @Environment(\.strings) private var s

    var body: some View {
        let line = Presentation.setupLine(state, host: host, s)
        switch state {
        case .idle:
            Text(line).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted).fixedSize(horizontal: false, vertical: true)
        case .testing, .installing:
            HStack(spacing: 6) {
                Spinner()
                Text(line).foregroundStyle(Tok.text2).fixedSize(horizontal: false, vertical: true)
            }
            .font(Typo.ui(size: 10))
        case .connected:
            Mark(symbol: "checkmark.circle.fill", color: Tok.success, text: line)
        case .needsInstall(let reason):
            let button = Button(Presentation.installButton(reason, s), action: install)
                .buttonStyle(ClaudeButtonStyle(kind: prominent ? .primary : .secondary, compact: true))
                .fixedSize()
            if stacked {
                VStack(spacing: 10) {
                    Text(line).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    button
                }
                .font(Typo.ui(size: 11))
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Mark(symbol: "arrow.down.circle", color: Tok.claude, text: line)
                    Spacer(minLength: 0)
                    button
                }
            }
        case .needsPassword(let command):
            VStack(alignment: .leading, spacing: 7) {
                Mark(symbol: "lock", color: Tok.warning, text: line)
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tok.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tok.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tok.border, lineWidth: 0.5))
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(s.common.copy) { copy(command) }
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                    Button(s.setup.checkAgain, action: checkAgain)
                        .buttonStyle(ClaudeButtonStyle(kind: .primary, compact: true))
                }
            }
        case .failed:
            HStack(alignment: .center, spacing: 8) {
                Mark(symbol: "xmark.octagon.fill", color: Tok.error, text: line, textColor: Tok.error)
                Spacer(minLength: 0)
                if let retry {
                    Button(s.setup.tryAgain, action: retry)
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                        .fixedSize()
                }
            }
        }
    }
}

/// A symbol and a sentence that wraps beside it.
private struct Mark: View {
    let symbol: String
    let color: Color
    let text: String
    var textColor = Tok.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
            Text(text).foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.ui(size: 10))
    }
}
