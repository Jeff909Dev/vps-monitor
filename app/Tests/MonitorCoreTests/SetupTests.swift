import Foundation
import Testing
@testable import MonitorCore

/// The transitions themselves, as pure functions.
struct SetupStateTests {
    @Test func whatAStatusAnswerMeans() throws {
        var s = try Fixture.snapshot()
        #expect(SetupState.tested(.success(s), appVersion: "0.2.0") == .connected(s))
        s.version = "0.1.0"
        #expect(SetupState.tested(.success(s), appVersion: "0.2.0")
            == .needsInstall(.outdated(server: "0.1.0", app: "0.2.0")))
        #expect(SetupState.tested(.failure(.notInstalled), appVersion: "0.2.0") == .needsInstall(.missing))
        #expect(SetupState.tested(.failure(.schema(1)), appVersion: "0.2.0") == .needsInstall(.schema(1)))
        #expect(SetupState.tested(.failure(.sudoPassword), appVersion: "0.2.0") == .needsInstall(.noSudoRule))
        #expect(SetupState.tested(.failure(.ssh(.keyRefused)), appVersion: "0.2.0") == .failed(.ssh(.keyRefused)))
    }

    @Test func whatTheInstallersAnswerMeans() {
        #expect(SetupState.installed(.success(.installed(version: "0.2.0", changed: [])), appVersion: "0.2.0")
            == .testing)
        #expect(SetupState.installed(.success(.needsPassword(user: "deploy")), appVersion: "0.2.0")
            == .needsPassword(command: "curl -fsSL https://github.com/Jeff909Dev/vps-monitor/releases/download/"
                + "v0.2.0/vpsmon-install.sh | sudo sh -s -- --user deploy"))
        #expect(SetupState.installed(.failure(.installer(.sudoMissing)), appVersion: "0.2.0")
            == .failed(.installer(.sudoMissing)))
    }
}

/// Settings' Connect and Install against fake servers, start to end.
@MainActor
struct ServerSetupTests {
    let fixture: Snapshot

    init() throws { fixture = try Fixture.snapshot() }

    func setup(_ backend: FakeBackend, installer: Data? = Data("#!/bin/sh\n".utf8)) -> (ServerSetup, Monitor, Recorder) {
        let (monitor, recorder) = makeMonitor(backend, settings: Settings(), installer: installer)
        return (ServerSetup(monitor: monitor), monitor, recorder)
    }

    @Test func aWorkingServerConnectsAndIsSaved() async {
        let backend = FakeBackend(status: .success(fixture))
        let (setup, monitor, recorder) = setup(backend)
        await setup.connect(ServerForm(host: "web-1", user: "deploy"))
        #expect(setup.state == .connected(fixture))
        #expect(monitor.settings.server == web1)
        #expect(recorder.saved.last?.server == web1)
        // Live at once, without waiting for the next poll.
        #expect(monitor.connection.snapshot == fixture)
        #expect(Presentation.setupLine(setup.state, host: "web-1", en)
            == "Connected to web-1 · vpsmon 0.3.0 · disk 85% full · 4 Claude Code sessions")
    }

    @Test func aMistypedFormFailsWithoutAsking() async {
        let backend = FakeBackend(status: .success(fixture))
        let (setup, monitor, _) = setup(backend)
        await setup.connect(ServerForm(host: "-oProxyCommand=evil"))
        #expect(setup.state == .failed(.invalidServer(.host("-oProxyCommand=evil"))))
        #expect(backend.calls.isEmpty)
        #expect(monitor.settings.server == nil)
    }

    /// Missing: Install on server, then it tests again and connects.
    @Test func aServerWithoutVpsmonInstallsThenConnects() async {
        let backend = FakeBackend(status: .failure(.notInstalled), .success(fixture))
        let (setup, monitor, _) = setup(backend)
        await setup.connect(web1)
        #expect(setup.state == .needsInstall(.missing))
        #expect(monitor.settings.server == nil)
        await setup.install()
        #expect(backend.calls == [.status, .install, .status])
        #expect(setup.state == .connected(fixture))
        #expect(monitor.settings.server == web1)
    }

    @Test func anOutdatedServerUpdates() async {
        var old = fixture
        old.version = "0.1.0"
        let backend = FakeBackend(status: .success(old), .success(fixture))
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        #expect(setup.state == .needsInstall(.outdated(server: "0.1.0", app: "0.2.0")))
        #expect(Presentation.setupLine(setup.state, host: "web-1", en) == "web-1 runs vpsmon 0.1.0; this app brings 0.2.0.")
        await setup.install()
        #expect(setup.state == .connected(fixture))
    }

    /// Another schema is not a dead end: it is a server to update.
    @Test func anotherSchemaUpdates() async {
        let backend = FakeBackend(status: .failure(.schema(1)), .success(fixture))
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        #expect(setup.state == .needsInstall(.schema(1)))
        await setup.install()
        #expect(setup.state == .connected(fixture))
    }

    /// sudo wants a password: the command to paste, then Check again.
    @Test func sudoAskingForAPasswordShowsTheCommandThenChecksAgain() async {
        let backend = FakeBackend(status: .failure(.notInstalled), .success(fixture))
        backend.installResults = [.success(.needsPassword(user: "deploy"))]
        let (setup, monitor, _) = setup(backend)
        await setup.connect(web1)
        await setup.install()
        guard case .needsPassword(let command) = setup.state else {
            Issue.record("expected needsPassword, got \(setup.state)")
            return
        }
        #expect(command.hasSuffix("| sudo sh -s -- --user deploy"))
        #expect(monitor.settings.server == nil)
        await setup.checkAgain()
        #expect(backend.calls == [.status, .install, .status])
        #expect(setup.state == .connected(fixture))
        #expect(monitor.settings.server == web1)
    }

    /// Without systemd the install works but keeps no history: setup says so.
    @Test func aHostWithoutSystemdConnectsWithANote() async {
        let backend = FakeBackend(status: .failure(.notInstalled), .success(fixture))
        backend.installResults = [.success(.installed(version: "0.2.0", changed: [InstallOutcome.timerSkipped]))]
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        await setup.install()
        #expect(setup.state == .connected(fixture))
        #expect(setup.timerSkipped)
        await setup.connect(web1)
        #expect(!setup.timerSkipped)
    }

    @Test func anInstallerErrorReadsInBothLanguages() async {
        let backend = FakeBackend(status: .failure(.notInstalled))
        backend.installResults = [.failure(.installer(.python3))]
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        await setup.install()
        #expect(setup.state == .failed(.installer(.python3)))
        #expect(Presentation.setupLine(setup.state, host: "web-1", en) == "vpsmon needs Python 3.10 or newer on the server.")
        #expect(Presentation.setupLine(setup.state, host: "web-1", es)
            == "vpsmon necesita Python 3.10 o posterior en el servidor.")
    }

    @Test func aFailedInstallSaysWhy() async {
        let backend = FakeBackend(status: .failure(.notInstalled))
        backend.installResults = [.failure(.installer(.sudoersInvalid))]
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        await setup.install()
        #expect(setup.state == .failed(.installer(.sudoersInvalid)))
    }

    @Test func aBuildWithoutAnInstallerSaysSo() async {
        let backend = FakeBackend(status: .failure(.notInstalled))
        let (setup, _, _) = setup(backend, installer: nil)
        await setup.connect(web1)
        await setup.install()
        #expect(setup.state == .failed(.noInstaller))
        #expect(!backend.calls.contains(.install))
    }

    @Test func anUnreachableServerFails() async {
        let backend = FakeBackend(status: .failure(.ssh(.unresolved)))
        let (setup, _, _) = setup(backend)
        await setup.connect(web1)
        #expect(setup.state == .failed(.ssh(.unresolved)))
        #expect(Presentation.setupLine(setup.state, host: "web-1", es)
            == "No encuentro el servidor: revisa el nombre, tu red o tu VPN.")
    }

    /// The same machine runs over the real SSH backend: what Settings does is what ssh is asked.
    @Test func installRunsOverSshWithTheBundledScript() async throws {
        let runner = SequenceRunner([
            FakeRunner(127, stderr: "sh: 1: /usr/local/bin/vpsmon: not found").output,
            FakeRunner(0, stdout: #"{"ok":true,"version":"0.2.0","changed":["vpsmon","timer"]}"#).output,
            CommandOutput(status: 0, stdout: try Fixture.data(), stderr: Data()),
        ])
        let env = Monitor.Environment(backend: { SSHBackend(server: $0, language: $1, runner: runner) },
                                      installer: { Data("payload".utf8) }, appVersion: "0.2.0",
                                      preferredLanguages: { ["en"] })
        let monitor = Monitor(settings: Settings(), environment: env)
        let setup = ServerSetup(monitor: monitor)
        await setup.connect(web1)
        #expect(setup.state == .needsInstall(.missing))
        await setup.install()
        #expect(setup.state == .connected(fixture))
        #expect(runner.calls.map { Array($0.arguments.suffix(2)) } == [["en", "status"], ["sh", "-s"], ["en", "status"]])
        #expect(runner.calls.map(\.stdin) == [nil, Data("payload".utf8), nil])
    }
}

/// Answers each run with the next output.
final class SequenceRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        var arguments: [String]
        var stdin: Data?
    }

    private let lock = NSLock()
    private var outputs: [CommandOutput]
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    init(_ outputs: [CommandOutput]) { self.outputs = outputs }

    func run(_ executable: URL, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> CommandOutput {
        lock.withLock {
            _calls.append(Call(arguments: arguments, stdin: stdin))
            return outputs.count > 1 ? outputs.removeFirst() : outputs[0]
        }
    }
}
