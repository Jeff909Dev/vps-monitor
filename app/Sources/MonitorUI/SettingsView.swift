import AppKit
import MonitorCore
import SwiftUI

/// Open at login, as the app reads and changes it. The app gives the real login item; a render gives a fixed one.
public struct LoginItem: Sendable {
    public var isEnabled: @Sendable () -> Bool
    /// Registered, but waiting for the user to allow it in System Settings.
    public var needsApproval: @Sendable () -> Bool
    public var set: @Sendable (Bool) throws -> Void
    public var openSystemSettings: @Sendable () -> Void

    public init(isEnabled: @escaping @Sendable () -> Bool, needsApproval: @escaping @Sendable () -> Bool,
                set: @escaping @Sendable (Bool) throws -> Void, openSystemSettings: @escaping @Sendable () -> Void) {
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
        self.set = set
        self.openSystemSettings = openSystemSettings
    }

    public static let off = LoginItem(isEnabled: { false }, needsApproval: { false }, set: { _ in },
                                      openSystemSettings: {})
}

/// Settings: the server and how to reach it (Connect, then Install or Update when vpsmon needs it), and the app's
/// own preferences.
public struct SettingsView: View {
    public static let width: CGFloat = 480

    @Bindable var monitor: Monitor
    @State private var setup: ServerSetup
    @State private var form: ServerForm
    @State private var launchAtLogin: Bool
    @State private var loginProblem: String?
    private let loginItem: LoginItem
    private let configHosts: [SSHConfigHost]

    /// `form` and `state` start the window somewhere else than the saved server, for a render.
    public init(monitor: Monitor, loginItem: LoginItem, configHosts: [SSHConfigHost] = SSHConfigHost.load(),
                form: ServerForm? = nil, state: SetupState = .idle) {
        self.monitor = monitor
        self.loginItem = loginItem
        self.configHosts = configHosts
        let form = form ?? ServerForm(monitor.settings.server)
        _form = State(initialValue: form)
        _setup = State(initialValue: ServerSetup(monitor: monitor, address: try? form.address(fileExists: { _ in true }),
                                                 state: state))
        _launchAtLogin = State(initialValue: loginItem.isEnabled())
    }

    public var body: some View {
        let s = monitor.strings
        VStack(alignment: .leading, spacing: 14) {
            server(s)
            Hairline()
            general(s)
            Text(s.settings.version(monitor.appVersion)).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
        }
        .font(Typo.ui())
        .foregroundStyle(Tok.text)
        .padding(20)
        .frame(width: Self.width, alignment: .topLeading)
        .background(Tok.bg)
        .environment(\.strings, s)
    }

    // MARK: Server

    private func server(_ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: s.settings.server)
                Menu {
                    if configHosts.isEmpty {
                        Text(s.settings.noConfigHosts)
                    }
                    ForEach(configHosts) { host in
                        Button(host.hostName.map { "\(host.alias)  (\($0))" } ?? host.alias) {
                            form = ServerForm(host.address)
                        }
                    }
                } label: {
                    Text(s.settings.fromConfig).font(Typo.ui(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            field(s.settings.host) {
                TextField(s.settings.hostPlaceholder, text: $form.host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
            }
            field(s.settings.user) {
                HStack(spacing: 8) {
                    TextField(s.settings.userPlaceholder, text: $form.user)
                        .textFieldStyle(.roundedBorder)
                    Text(s.settings.port).foregroundStyle(Tok.text2)
                    TextField(s.settings.portPlaceholder, text: $form.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                }
            }
            field(s.settings.key) {
                HStack(spacing: 8) {
                    TextField(s.settings.keyPlaceholder, text: $form.identityFile)
                        .textFieldStyle(.roundedBorder)
                    Button(s.settings.choose) { chooseKey(s) }
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                        .fixedSize()
                }
            }
            // What it needs beside Connect; once Connect ran, what came of it below, across the whole width.
            HStack(alignment: .top, spacing: 10) {
                if setup.state == .idle { status.frame(maxWidth: .infinity, alignment: .leading) }
                Spacer(minLength: 0)
                Button(s.settings.connect, action: connect)
                    .buttonStyle(ClaudeButtonStyle(kind: isConnectPrimary ? .primary : .secondary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.state.isBusy)
                    .fixedSize()
            }
            .padding(.top, 2)
            if setup.state != .idle { status }
            if setup.timerSkipped, case .connected = setup.state {
                Text(s.setup.noTimer).font(Typo.ui(size: 10)).foregroundStyle(Tok.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: some View {
        SetupStatus(state: setup.state, host: setup.address?.host ?? form.host,
                    install: { Task { await setup.install() } },
                    checkAgain: { Task { await setup.checkAgain() } },
                    copy: { monitor.copy($0) })
    }

    /// Connect is the next step until it worked; then the install buttons and the summary take the eye.
    private var isConnectPrimary: Bool {
        switch setup.state {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(Tok.text2).frame(width: 72, alignment: .leading)
            control()
        }
    }

    private func connect() {
        let form = form
        Task { await setup.connect(form) }
    }

    private func chooseKey(_ s: Strings) {
        let panel = NSOpenPanel()
        panel.message = s.settings.chooseKeyTitle
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { form.identityFile = url.path }
    }

    // MARK: General

    private func general(_ s: Strings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: s.settings.general)
            row(s.settings.language) {
                Segmented(options: [(.system, s.settings.languageSystem), (.english, "English"), (.spanish, "Español")],
                          selection: $monitor.settings.language)
            }
            row(s.settings.interval) {
                Segmented(options: PollInterval.allCases.map { ($0, $0.label) }, selection: $monitor.settings.interval)
            }
            row(s.settings.notifications) { toggle($monitor.settings.notifications) }
            row(s.settings.launchAtLogin) {
                toggle(Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0, s) }))
            }
            if let loginProblem {
                Text(loginProblem).font(Typo.ui(size: 10)).foregroundStyle(Tok.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row(s.settings.iconOnly) { toggle($monitor.settings.iconOnly) }
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Tok.claude)
    }

    private func setLaunchAtLogin(_ enabled: Bool, _ s: Strings) {
        loginProblem = nil
        do {
            try loginItem.set(enabled)
            if enabled && loginItem.needsApproval() {
                loginProblem = s.settings.loginApprove
                loginItem.openSystemSettings()
            }
        } catch {
            loginProblem = enabled ? s.settings.loginNeedsApplications
                                   : s.settings.loginRemoveFailed(error.localizedDescription)
        }
        launchAtLogin = loginItem.isEnabled()
    }
}
