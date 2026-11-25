import Foundation
import Testing
@testable import MonitorCore

struct VPSCommandTests {
    let controlPath = "/var/folders/xx/T/vpsmon-0123456789abcdef"
    /// Validation wants a key file that exists; any absolute path that does will do.
    let key = "/etc/hosts"
    let base = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ControlMaster=auto",
                "-o", "ControlPath=/var/folders/xx/T/vpsmon-0123456789abcdef", "-o", "ControlPersist=300",
                "-o", "ConnectTimeout=8"]

    func arguments(_ command: VPSCommand, _ server: ServerAddress, _ language: Language = .en) throws -> [String] {
        try command.sshArguments(server: server, language: language, controlPath: controlPath)
    }

    /// Every combination of port, user and key, in the contract's order, then the host and vpsmon without sudo.
    @Test(arguments: [false, true], [false, true])
    func theVectorIsExactlyTheContracts(_ withPort: Bool, _ withUser: Bool) throws {
        for withKey in [false, true] {
            let server = ServerAddress(host: "web-1", user: withUser ? "deploy" : nil, port: withPort ? 2222 : nil,
                                       identityFile: withKey ? key : nil)
            let options = (withPort ? ["-p", "2222"] : []) + (withUser ? ["-l", "deploy"] : [])
                + (withKey ? ["-i", key, "-o", "IdentitiesOnly=yes"] : [])
            #expect(try arguments(.status, server)
                == base + options + ["web-1", "/usr/local/bin/vpsmon", "--lang", "en", "status"])
        }
    }

    @Test func theLanguageGoesToTheServer() throws {
        #expect(try arguments(.status, web1, .es).suffix(4) == ["/usr/local/bin/vpsmon", "--lang", "es", "status"])
        #expect(try !arguments(.status, web1).contains("sudo"))
    }

    @Test func scanActAndInstallTails() throws {
        #expect(try arguments(.startScan, web1).suffix(5)
            == ["/usr/local/bin/vpsmon", "--lang", "en", "scan", "--background"])
        #expect(try arguments(.act("worker:52310:326136400"), web1).suffix(2) == ["act", "worker:52310:326136400"])
        #expect(try arguments(.act("proc:41822:303100000"), web1).suffix(2) == ["act", "proc:41822:303100000"])
        #expect(try arguments(.act("tmp-stale", dryRun: true), web1).suffix(3) == ["act", "tmp-stale", "--dry-run"])
        // The installer reads itself from stdin; vpsmon may not exist yet.
        #expect(try arguments(.install, web1) == base + ["-l", "deploy", "web-1", "sh", "-s"])
    }

    /// ssh hands the remote command to a shell, so an id must never carry shell syntax or an option.
    @Test(arguments: ["tmp-stale; rm -rf /", "$(reboot)", "-rf", "worker:1:2 && x", "", "Tmp-Stale", "../x",
                      "proc:1", "proc:a:b", "proc:1:2:3", "worker:-1:2", "proc:1:2\n"])
    func refusesAnIdTheServerWouldNeverPublish(_ id: String) {
        #expect(throws: VPSError.invalidActionID(id)) { try arguments(.act(id), web1) }
    }

    @Test(arguments: ["tmp-stale", "docker-build-cache", "worker:52310:326136400", "proc:1:2"])
    func acceptsEveryKindOfPublishedId(_ id: String) throws {
        #expect(try arguments(.act(id), web1).last == id)
    }

    @Test func anInvalidServerIsNeverRun() {
        #expect(throws: VPSError.invalidServer(.host("-oProxyCommand=evil"))) {
            try arguments(.status, ServerAddress(host: "-oProxyCommand=evil"))
        }
        #expect(throws: VPSError.invalidServer(.user("-x"))) {
            try arguments(.status, ServerAddress(host: "web-1", user: "-x"))
        }
    }

    @Test func timeouts() {
        #expect(VPSCommand.status.timeout == 30)
        #expect(VPSCommand.install.timeout == 120)
        #expect(VPSCommand.act("journal").timeout == 3_600)
        #expect(VPSError.timedOut(seconds: 3_600).message(en) == "The server didn't answer within 1 h.")
        #expect(VPSError.timedOut(seconds: 30).message(es) == "El servidor no contestó en 30 s.")
    }
}

struct SSHBackendTests {
    func backend(_ runner: FakeRunner, language: Language = .en) -> SSHBackend {
        SSHBackend(server: web1, language: language, runner: runner, tempDirectory: "/tmp/x")
    }

    @Test func statusDecodesWhatSshPrinted() async throws {
        let runner = FakeRunner(CommandOutput(status: 0, stdout: try Fixture.data(), stderr: Data()))
        #expect(try await backend(runner).status().workers.count == 4)
        #expect(runner.arguments.contains("ControlPath=/tmp/x/vpsmon-" + SSHBackend.socketName(web1)))
        #expect(runner.stdin == nil)
        #expect(runner.timeout == 30)
    }

    @Test func actSendsTheIdAndWaitsLonger() async throws {
        let runner = FakeRunner(0, stdout: #"{"ok":true,"id":"journal","freedBytes":5,"message":"Done"}"#)
        let result = try await backend(runner).act("journal")
        #expect(result.message == "Done")
        #expect(runner.arguments.suffix(2) == ["act", "journal"])
        #expect(runner.timeout == 3_600)
    }

    @Test func aHandledErrorExitsOneWithJSON() async {
        let runner = FakeRunner(1, stdout: #"{"ok": false, "error": "The session is no longer idle"}"#)
        await #expect(throws: VPSError.server("The session is no longer idle")) {
            try await backend(runner).act("worker:1:2")
        }
    }

    @Test(arguments: [
        ("ssh: Could not resolve hostname web-1: nodename nor servname provided", SSHFailure.unresolved),
        ("deploy@web-1: Permission denied (publickey).", .keyRefused),
        ("ssh: connect to host web-1 port 22: Connection refused", .refused),
        ("kex_exchange_identification: read: Connection reset", .other("kex_exchange_identification: read: Connection reset")),
    ])
    func sshFailuresAreKnownByWhatSshPrints(_ stderr: String, _ failure: SSHFailure) async {
        let runner = FakeRunner(255, stderr: "Warning: something\n" + stderr + "\n")
        await #expect(throws: VPSError.ssh(failure)) { try await backend(runner).status() }
    }

    /// The hints name what anyone can check: the host name, the network, a VPN, the key.
    @Test func sshHintsAreGeneric() {
        #expect(VPSError.ssh(.unresolved).message(en)
            == "Can't find that server: check the host name, your network or your VPN.")
        #expect(VPSError.ssh(.unresolved).message(es) == "No encuentro el servidor: revisa el nombre, tu red o tu VPN.")
        #expect(VPSError.ssh(.keyRefused).message(en)
            == "The server doesn't accept your SSH key: check the user and the key.")
    }

    @Test(arguments: [
        (CommandOutput(status: 127, stdout: Data(), stderr: Data("sh: 1: /usr/local/bin/vpsmon: not found\n".utf8)),
         VPSError.notInstalled),
        (CommandOutput(status: 127, stdout: Data(),
                       stderr: Data("bash: line 1: /usr/local/bin/vpsmon: No such file or directory\n".utf8)),
         .notInstalled),
        (CommandOutput(status: 1, stdout: Data(), stderr: Data("sudo: a password is required\n".utf8)), .sudoPassword),
        (CommandOutput(status: 3, stdout: Data(), stderr: Data("Traceback: boom\n".utf8)),
         .failed(status: 3, detail: "Traceback: boom")),
    ])
    func whatAFailureWithoutJSONMeans(_ output: CommandOutput, _ error: VPSError) async {
        await #expect(throws: error) { try await backend(FakeRunner(output)).status() }
    }

    @Test func aTimeoutSaysHowLong() async {
        let runner = FakeRunner(0)
        runner.throwsTimeout = true
        await #expect(throws: VPSError.timedOut(seconds: 30)) { try await backend(runner).status() }
    }

    @Test func installFeedsTheScriptOnStdinAndReadsItsLastJSONLine() async throws {
        let script = Data("#!/bin/sh\necho installer\n".utf8)
        let runner = FakeRunner(0, stdout: "Created symlink …\n{\"ok\":true,\"version\":\"0.2.0\",\"changed\":[\"vpsmon\"]}\n")
        #expect(try await backend(runner).install(script: script)
            == .installed(version: "0.2.0", changed: ["vpsmon"]))
        #expect(runner.stdin == script)
        #expect(runner.arguments.suffix(3) == ["web-1", "sh", "-s"])
        #expect(runner.timeout == 120)
    }

    @Test func installReportsSudoAskingForAPassword() async throws {
        let runner = FakeRunner(1, stdout: #"{"ok":false,"error":"sudo-password","user":"deploy"}"#)
        #expect(try await backend(runner).install(script: Data()) == .needsPassword(user: "deploy"))
        let refused = FakeRunner(1, stdout: #"{"ok":false,"error":"visudo-missing"}"#)
        await #expect(throws: VPSError.installer(.visudoMissing)) { try await backend(refused).install(script: Data()) }
        let lost = FakeRunner(255, stderr: "ssh: connect to host web-1 port 22: No route to host")
        await #expect(throws: VPSError.ssh(.noRoute)) { try await backend(lost).install(script: Data()) }
    }

    /// Every error code of the installer: sudo-password has its own state, the rest are failures with their reason.
    @Test(arguments: [
        ("sudo-missing", InstallerFailure.sudoMissing), ("python3", .python3), ("bad-user", .badUser),
        ("bad-unit", .badUnit), ("usage", .usage), ("no-such-user", .noSuchUser), ("visudo-missing", .visudoMissing),
        ("sudoers-invalid", .sudoersInvalid), ("disk-full", .other("disk-full")),
    ])
    func installerErrorCodes(_ code: String, _ failure: InstallerFailure) async {
        let status: Int32 = ["usage", "bad-user", "bad-unit"].contains(code) ? 2 : 1
        let runner = FakeRunner(status, stdout: #"{"ok":false,"error":"\#(code)","user":"deploy"}"#)
        await #expect(throws: VPSError.installer(failure)) { try await backend(runner).install(script: Data()) }
    }

    @Test func aHostWithoutSystemdInstallsWithoutItsTimer() async throws {
        let runner = FakeRunner(0, stdout: #"{"ok":true,"version":"0.2.0","changed":["vpsmon","no-systemd-timer-skipped"]}"#)
        #expect(try await backend(runner).install(script: Data())
            == .installed(version: "0.2.0", changed: ["vpsmon", InstallOutcome.timerSkipped]))
    }

    /// sudo's own message when it isn't there: installing can't cure it, so it isn't "vpsmon missing".
    @Test func noSudoIsNotAMissingVpsmon() async {
        let runner = FakeRunner(1, stderr: "vpsmon: sudo: command not found\n")
        await #expect(throws: VPSError.installer(.sudoMissing)) { try await backend(runner).status() }
        #expect(SetupState.tested(.failure(.installer(.sudoMissing)), appVersion: "0.2.0")
            == .failed(.installer(.sudoMissing)))
    }

    /// A Unix socket path must fit in 104 bytes, and ssh adds 17 while creating it. Measured in this Mac's real temp
    /// folder with a long cloud host name; the path holds no ssh token that would grow when ssh expands it.
    @Test func theControlSocketPathFits() throws {
        let long = ServerAddress(host: "ec2-203-0-113-25.eu-west-1.compute.amazonaws.com", user: "ubuntu", port: 2222,
                                 identityFile: "/Users/someone/.ssh/a-rather-long-key-name_ed25519")
        let path = SSHBackend(server: long, language: .en).controlPath
        #expect(!path.contains("%"))
        #expect(path.utf8.count + 17 <= 104)
    }

    @Test func eachServerGetsItsOwnSocket() {
        let other = ServerAddress(host: web1.host, user: web1.user, port: 2222, identityFile: web1.identityFile)
        #expect(SSHBackend.socketName(web1) != SSHBackend.socketName(other))
        #expect(SSHBackend.socketName(web1).count == 16)
    }
}

struct CommandRunnerTests {
    @Test func capturesBothStreamsAndTheStatus() async throws {
        let output = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sh"),
                                                          ["-c", "printf out; printf err >&2; exit 3"], stdin: nil,
                                                          timeout: 5)
        #expect(output == CommandOutput(status: 3, stdout: Data("out".utf8), stderr: Data("err".utf8)))
    }

    @Test func drainsALargeOutput() async throws {
        // Over a pipe buffer (64 KB): the child would block forever if stdout weren't read while it runs.
        let output = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sh"),
                                                          ["-c", "head -c 300000 /dev/zero"], stdin: nil, timeout: 5)
        #expect(output.stdout.count == 300_000)
    }

    /// The installer goes to `sh -s` on stdin: bigger than a pipe buffer, and it must arrive whole and end.
    @Test func feedsStdinWhole() async throws {
        let script = Data((0..<20_000).map { "echo line \($0)\n" }.joined().utf8)
        let output = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", "wc -c"],
                                                          stdin: script, timeout: 5)
        #expect(Int(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            == script.count)
        let shell = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-s"],
                                                         stdin: Data("echo $((6 * 7))\n".utf8), timeout: 5)
        #expect(String(decoding: shell.stdout, as: UTF8.self) == "42\n")
    }

    /// A child that exits without reading its stdin must not take the app down with SIGPIPE.
    @Test func survivesAChildThatIgnoresStdin() async throws {
        let output = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/usr/bin/true"), [],
                                                          stdin: Data(count: 1_000_000), timeout: 5)
        #expect(output.status == 0)
    }

    @Test func timesOut() async {
        await #expect(throws: CommandError.timedOut) {
            try await ProcessCommandRunner().run(URL(fileURLWithPath: "/bin/sleep"), ["10"], stdin: nil, timeout: 0.3)
        }
    }
}
