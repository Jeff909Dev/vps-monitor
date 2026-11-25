import AppKit
import Foundation
import MonitorCore
import MonitorUI

/// `vpsmon-mac` runs what the app runs, with the app's own code: `status` prints what the popover would say,
/// `install` connects and installs as Settings does, `act` applies one published action, and `render` draws the
/// popover or Settings into a PNG. Only `install` and `act` change anything on the server.
@main
@MainActor
enum CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "status" : args.removeFirst()
        let options = Options(args)
        switch command {
        case "status": await status(options)
        case "install": await install(options)
        case "act": await act(options)
        case "render": await render(options)
        default: usage()
        }
    }

    struct Options {
        var positional: [String] = []
        var form = ServerForm()
        var language: Language = AppLanguage.system.resolved(preferred: Locale.preferredLanguages)
        var fixture: String?
        var installer: String?
        var dryRun = false
        var dark = false
        var confirm: String?
        var fail: String?
        var connection: String?
        var open: Set<String> = []
        var openRAM: String?
        var welcome = false
        var outdated = false
        var settings: String?

        init(_ args: [String]) {
            var rest = args[...]
            func value() -> String {
                guard let next = rest.popFirst() else { CLI.usage() }
                return next
            }
            while let arg = rest.popFirst() {
                switch arg {
                case "--host": form.host = value()
                case "--user": form.user = value()
                case "--port": form.port = value()
                case "--identity": form.identityFile = value()
                case "--lang":
                    guard let language = Language(rawValue: value()) else { CLI.usage() }
                    self.language = language
                case "--fixture": fixture = value()
                case "--installer": installer = value()
                case "--dry-run": dryRun = true
                case "--dark": dark = true
                case "--confirm": confirm = value()
                case "--fail": fail = value()
                case "--stale": connection = "stale"
                case "--unreachable": connection = "unreachable"
                case "--schema-error": connection = "schema"
                case "--open": open.insert(value())
                case "--open-ram": openRAM = value()
                case "--welcome": welcome = true
                case "--outdated": outdated = true
                case "--settings": settings = value()
                case let flag where flag.hasPrefix("--"): CLI.usage()
                default: positional.append(arg)
                }
            }
        }

        var strings: Strings { Strings.for(language) }

        /// The setting that makes the Monitor speak `language` whatever the Mac's.
        var appLanguage: AppLanguage { language == .es ? .spanish : .english }
    }

    nonisolated static func usage() -> Never {
        print(Strings.for(AppLanguage.system.resolved(preferred: Locale.preferredLanguages)).cli.usage)
        exit(2)
    }

    nonisolated static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    /// The server from --host and friends, validated as Settings validates it.
    static func server(_ options: Options) -> ServerAddress {
        let s = options.strings
        guard !options.form.host.isEmpty else { fail(s.cli.needsServer) }
        do { return try options.form.address() } catch { fail(error.message(s)) }
    }

    /// A Monitor wired as the app wires it, but with nothing to save or notify.
    static func monitor(_ options: Options, backend: @escaping @Sendable (ServerAddress, Language) -> any VPSBackend,
                        installer: Data? = nil, server: ServerAddress?, connection: Connection? = nil) -> Monitor {
        var settings = Settings()
        settings.server = server
        settings.language = options.appLanguage
        return Monitor(settings: settings,
                       environment: Monitor.Environment(backend: backend, installer: { installer },
                                                        appVersion: AppInfo.version()),
                       connection: connection)
    }

    /// One `status`, from the fixture or the server. Nothing here polls, so nothing starts a scan.
    static func snapshot(_ options: Options) async -> Snapshot {
        let s = options.strings
        do {
            if let fixture = options.fixture {
                return try FixtureBackend(contentsOf: URL(fileURLWithPath: fixture)).snapshot
            }
            return try await SSHBackend(server: server(options), language: options.language).status()
        } catch {
            fail(error.message(s))
        }
    }

    // MARK: Commands

    static func status(_ options: Options) async {
        let snapshot = await snapshot(options)
        print(Presentation.text(.live(snapshot, at: Date()), host: snapshot.host, now: Date(), options.strings))
    }

    /// Settings' Connect, then Install: every state on its own line, through the same ServerSetup.
    static func install(_ options: Options) async {
        let s = options.strings
        let server = server(options)
        let script: Data
        if let path = options.installer {
            guard let data = FileManager.default.contents(atPath: path) else { fail(s.cli.noInstaller) }
            script = data
        } else {
            guard let data = AppInfo.bundledInstaller() else { fail(s.cli.noInstaller) }
            script = data
        }
        let monitor = monitor(options, backend: { SSHBackend(server: $0, language: $1) }, installer: script,
                              server: nil)
        let setup = ServerSetup(monitor: monitor)
        func say() { print(Presentation.setupLine(setup.state, host: server.host, s)) }
        print(Presentation.setupLine(.testing, host: server.host, s))
        await setup.connect(server)
        say()
        if case .failed = setup.state { exit(1) }
        print(Presentation.setupLine(.installing, host: server.host, s))
        await setup.install()
        say()
        if setup.timerSkipped { print(s.setup.noTimer) }
        switch setup.state {
        case .connected: exit(0)
        case .needsPassword(let command):
            print(command)
            exit(1)
        default: exit(1)
        }
    }

    static func act(_ options: Options) async {
        let s = options.strings
        guard let id = options.positional.first else { usage() }
        let backend = SSHBackend(server: server(options), language: options.language)
        do {
            let result = options.dryRun ? try await backend.dryRun(id) : try await backend.act(id)
            // The server's message names what it did; the app adds the amount, as the popover does.
            let line = result.dryRun == true || result.freedBytes == 0
                ? result.message : s.disk.freed(s.format.bytes(result.freedBytes), result.message)
            print("\(result.id) · \(line)"
                + (result.dryRun == true ? " · \(s.cli.dryRun)" : ""))
            for item in result.items ?? [] {
                print("  " + s.format.bytes(item.bytes).padding(toLength: 9, withPad: " ", startingAt: 0) + item.label)
            }
            if let resume = result.resumeCommand { print(resume) }
        } catch {
            fail(error.message(s))
        }
    }

    static func render(_ options: Options) async {
        guard let out = options.positional.first else { usage() }
        let s = options.strings
        let png: Data?
        if let name = options.settings {
            png = await renderSettings(options, state: name)
        } else if options.welcome {
            let backend = FixtureBackend(snapshot: placeholder)
            let monitor = monitor(options, backend: { _, _ in backend }, server: nil)
            png = Renderer.popover(monitor: monitor, now: Date(timeIntervalSince1970: backend.snapshot.at),
                                   dark: options.dark)
        } else {
            png = await renderPopover(options)
        }
        guard let png else { fail(s.cli.renderFailed) }
        do { try png.write(to: URL(fileURLWithPath: out)) } catch { fail("\(error)") }
        print(out)
    }

    /// The popover over a snapshot, as if the poll had arrived 40 s ago. Its monitor only ever talks to a fixture
    /// backend, which refuses every act, whatever the snapshot's source.
    static func renderPopover(_ options: Options) async -> Data? {
        let s = options.strings
        var snapshot = await snapshot(options)
        // An older server than the app: the update banner.
        if options.outdated { snapshot.version = "0.1.0" }
        let now = Date(timeIntervalSince1970: snapshot.at + 40)
        let received = Date(timeIntervalSince1970: snapshot.at)
        let connection: Connection = switch options.connection {
        case "stale": .stale(snapshot, at: received, error: .timedOut(seconds: 30))
        case "unreachable": .unreachable(error: .ssh(.unresolved))
        case "schema": .unreachable(error: .schema(SnapshotDecoding.schema - 1))
        default: .live(snapshot, at: received)
        }
        let backend = FixtureBackend(snapshot: snapshot, refusal: .server(s.cli.sampleRefusal))
        let monitor = monitor(options, backend: { _, _ in backend },
                              server: ServerAddress(host: snapshot.host, user: "deploy"), connection: connection)
        if let id = options.fail {
            // The fixture backend refuses every act, so this shows the failed row (and refreshes back to live).
            monitor.confirm(id)
            await monitor.perform(id)
        }
        if let id = options.confirm {
            let inOpenGroup = snapshot.scan.map.groups.contains { options.open.contains($0.id) && $0.actions.contains(id) }
            monitor.confirm(id, in: inOpenGroup ? .map : .list)
        }
        let expansion = PopoverView.Expansion(mapGroups: options.open, ram: options.openRAM != nil,
                                              ramGroups: options.openRAM.map { [$0] } ?? [])
        return Renderer.popover(monitor: monitor, now: now, dark: options.dark, expansion: expansion)
    }

    /// Settings in one setup state, with the form filled from --host and friends (or an invented server).
    static func renderSettings(_ options: Options, state name: String) async -> Data? {
        let form = options.form.host.isEmpty ? ServerForm(host: "web-1.example.com", user: "deploy") : options.form
        let version = AppInfo.version()
        let snapshot = options.fixture == nil ? placeholder : await snapshot(options)
        let state: SetupState
        switch name {
        case "idle": state = .idle
        case "testing": state = .testing
        case "connected": state = .connected(snapshot)
        case "missing": state = .needsInstall(.missing)
        case "outdated": state = .needsInstall(.outdated(server: "0.1.0", app: version))
        case "schema": state = .needsInstall(.schema(SnapshotDecoding.schema - 1))
        case "installing": state = .installing
        case "password":
            state = .needsPassword(command: SetupState.installCommand(version: version,
                                                                      user: form.user.isEmpty ? "deploy" : form.user))
        case "failed": state = .failed(.ssh(.keyRefused))
        default: usage()
        }
        let backend = FixtureBackend(snapshot: snapshot)
        let monitor = monitor(options, backend: { _, _ in backend },
                              server: name == "connected" ? try? form.address(fileExists: { _ in true }) : nil)
        return Renderer.settings(monitor: monitor, form: form, state: state, dark: options.dark)
    }

    /// The repo's English fixture, for renders that need a snapshot but were given none.
    static var placeholder: Snapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/status.json")
        do { return try FixtureBackend(contentsOf: url).snapshot } catch { fail(error.message(.en)) }
    }
}
