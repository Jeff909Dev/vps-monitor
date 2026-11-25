import CryptoKit
import Foundation

/// Everything the app can ask the server. The SSH client and the test fakes both implement it.
public protocol VPSBackend: Sendable {
    func status() async throws(VPSError) -> Snapshot
    /// `scan --background`: starts a disk scan, or finds one already running.
    func startScan() async throws(VPSError)
    /// Applies one action the server published. Deletes data, closes a session or ends a process.
    func act(_ id: String) async throws(VPSError) -> ActResult
    /// Runs `vpsmon-install.sh` on the server, fed on stdin.
    func install(script: Data) async throws(VPSError) -> InstallOutcome
}

/// What the installer said, when it said something the contract knows.
public enum InstallOutcome: Equatable, Sendable {
    /// `{"ok":true,"version":"0.2.0","changed":[…]}`
    case installed(version: String, changed: [String])
    /// `{"ok":false,"error":"sudo-password","user":"deploy"}`: sudo needs a password the app can't type.
    case needsPassword(user: String)

    /// In `changed` on a host without systemd: vpsmon works, but no timer samples its history.
    public static let timerSkipped = "no-systemd-timer-skipped"
}

/// An installer error code other than `sudo-password`, which has its own setup state.
public enum InstallerFailure: Equatable, Sendable {
    /// No sudo at all, and the SSH user isn't root.
    case sudoMissing
    /// No Python 3.10 or newer.
    case python3
    case badUser, badUnit, usage
    case noSuchUser
    case visudoMissing
    /// visudo rejected the rule; nothing changed.
    case sudoersInvalid
    /// A code this app doesn't know, shown as is.
    case other(String)

    init(code: String) {
        switch code {
        case "sudo-missing": self = .sudoMissing
        case "python3": self = .python3
        case "bad-user": self = .badUser
        case "bad-unit": self = .badUnit
        case "usage": self = .usage
        case "no-such-user": self = .noSuchUser
        case "visudo-missing": self = .visudoMissing
        case "sudoers-invalid": self = .sudoersInvalid
        default: self = .other(code)
        }
    }
}

/// Why a request failed. Structured, so each language words it at the moment it is shown.
public enum VPSError: Error, Equatable, Sendable {
    /// A server address that fails validation; never sent.
    case invalidServer(ServerAddress.Problem)
    /// An id the server would never publish; never sent.
    case invalidActionID(String)
    case timedOut(seconds: Int)
    /// SSH itself failed (exit 255): no route, refused key, unknown host.
    case ssh(SSHFailure)
    /// vpsmon answered `{"ok": false, "error": …}`, in the language it was asked for.
    case server(String)
    /// `{"ok": false}` with no error.
    case serverSilent
    /// `/usr/local/bin/vpsmon` isn't there.
    case notInstalled
    /// vpsmon couldn't become root: sudo wants a password, so the sudoers rule is missing.
    case sudoPassword
    /// vpsmon speaks another schema.
    case schema(Int)
    /// Something answered, but not with JSON.
    case notJSON
    /// JSON that doesn't fit the contract.
    case contract(ContractProblem)
    /// The command failed with neither JSON nor a known reason; the last line of stderr, if any.
    case failed(status: Int32, detail: String)
    /// This copy of the app carries no installer (a development build).
    case noInstaller
    /// The installer stopped before changing anything.
    case installer(InstallerFailure)
    /// Anything else, verbatim.
    case other(String)

    /// The request never got an answer from vpsmon; worth stopping a batch over.
    public var isTransport: Bool {
        switch self {
        case .timedOut, .ssh, .invalidServer: return true
        default: return false
        }
    }

    /// Any error, as a VPSError.
    public init(_ error: any Error) {
        if let error = error as? VPSError { self = error } else { self = .other(error.localizedDescription) }
    }
}

public enum SSHFailure: Equatable, Sendable {
    case unresolved, timedOut, noRoute, refused, keyRefused, hostKeyChanged
    case silent
    case other(String)

    /// Known ssh failures by what ssh prints; anything else verbatim.
    static let needles: [(needle: String, failure: SSHFailure)] = [
        ("Could not resolve hostname", .unresolved),
        ("Operation timed out", .timedOut),
        ("Connection timed out", .timedOut),
        ("No route to host", .noRoute),
        ("Connection refused", .refused),
        ("Permission denied", .keyRefused),
        ("Host key verification failed", .hostKeyChanged),
    ]

    init(stderr: String) {
        self = Self.needles.first { stderr.contains($0.needle) }?.failure ?? (stderr.isEmpty ? .silent : .other(stderr))
    }
}

/// Where a JSON answer stopped matching the contract: a dotted path such as `disk.freeBytes`.
public enum ContractProblem: Equatable, Sendable {
    case missing(String)
    case type(String)
    case corrupt(String)
}

/// The only commands the app runs, as argument vectors. Nothing here builds a command from data except an action id,
/// and that id must look like one the server publishes.
public enum VPSCommand: Equatable, Sendable {
    case status
    case startScan
    case act(String, dryRun: Bool = false)
    /// `sh -s`, with `vpsmon-install.sh` on stdin.
    case install

    public static let vpsmon = "/usr/local/bin/vpsmon"

    /// `tmp-stale`, `docker-images`, `worker:170180:302344108`, `proc:12345:987654`.
    static var actionID: Regex<Substring> { /^(?:[a-z][a-z0-9-]*|worker:[0-9]+:[0-9]+|proc:[0-9]+:[0-9]+)$/ }

    public var timeout: TimeInterval {
        switch self {
        case .status, .startScan: return 30
        // The installer writes a few files and enables a timer.
        case .install: return 120
        // An act that empties a /tmp full of build leftovers removes millions of files and can run for many minutes.
        case .act: return 3_600
        }
    }

    /// What runs on the server, after the host. ssh joins these with spaces for the remote shell, so none may carry
    /// shell syntax: the only variable part is a validated action id.
    func remoteArguments(language: Language) throws(VPSError) -> [String] {
        let vpsmon = [Self.vpsmon, "--lang", language.rawValue]
        switch self {
        case .status: return vpsmon + ["status"]
        case .startScan: return vpsmon + ["scan", "--background"]
        case .act(let id, let dryRun):
            guard id.wholeMatch(of: Self.actionID) != nil else { throw .invalidActionID(id) }
            return vpsmon + ["act", id] + (dryRun ? ["--dry-run"] : [])
        case .install: return ["sh", "-s"]
        }
    }

    /// The full `ssh` argument vector of the contract. One SSH connection is shared for five minutes
    /// (ControlMaster), so a poll costs a round trip, not a handshake.
    public func sshArguments(server: ServerAddress, language: Language, controlPath: String) throws(VPSError)
        -> [String] {
        let server = try server.validated()
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
            "-o", "ConnectTimeout=8",
        ]
        if let port = server.port { arguments += ["-p", String(port)] }
        if let user = server.user { arguments += ["-l", user] }
        if let key = server.identityFile { arguments += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        return arguments + [server.host] + (try remoteArguments(language: language))
    }
}

public struct SSHBackend: VPSBackend {
    public static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    public let server: ServerAddress
    public let language: Language
    private let runner: any CommandRunning
    let controlPath: String

    /// The control socket lives in this user's temp folder. A Unix socket path must fit in 104 bytes and ssh adds a
    /// 17-character suffix while creating it. macOS's temp folder takes 49, so ssh's own `%C` (40 characters) would
    /// overflow it: the name is a 16-character hash instead.
    public init(server: ServerAddress, language: Language, runner: any CommandRunning = ProcessCommandRunner(),
                tempDirectory: String = NSTemporaryDirectory()) {
        self.server = server
        self.language = language
        self.runner = runner
        self.controlPath = (tempDirectory as NSString).appendingPathComponent("vpsmon-" + Self.socketName(server))
    }

    /// 16 hex characters of SHA-256 over everything that picks the connection, so two servers never share a socket and
    /// a long host name can't lengthen the path.
    static func socketName(_ server: ServerAddress) -> String {
        let key = [server.user ?? "", server.host, server.port.map(String.init) ?? "", server.identityFile ?? ""]
        return SHA256.hash(data: Data(key.joined(separator: "\u{0}").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func status() async throws(VPSError) -> Snapshot {
        try SnapshotDecoding.snapshot(from: try await run(.status))
    }

    public func startScan() async throws(VPSError) {
        try SnapshotDecoding.envelope(try await run(.startScan))
    }

    public func act(_ id: String) async throws(VPSError) -> ActResult {
        try SnapshotDecoding.actResult(from: try await run(.act(id)))
    }

    /// `act <id> --dry-run`: what the server would do, changing nothing.
    public func dryRun(_ id: String) async throws(VPSError) -> ActResult {
        try SnapshotDecoding.actResult(from: try await run(.act(id, dryRun: true)))
    }

    public func install(script: Data) async throws(VPSError) -> InstallOutcome {
        let output = try await execute(.install, stdin: script)
        if output.status == 255 { throw .ssh(SSHFailure(stderr: Self.lastLine(output.stderr))) }
        return try Self.installOutcome(output)
    }

    /// Runs one command and returns stdout when vpsmon answered with JSON, whatever its exit code.
    func run(_ command: VPSCommand) async throws(VPSError) -> Data {
        try Self.interpret(try await execute(command, stdin: nil))
    }

    private func execute(_ command: VPSCommand, stdin: Data?) async throws(VPSError) -> CommandOutput {
        let arguments = try command.sshArguments(server: server, language: language, controlPath: controlPath)
        do {
            return try await runner.run(Self.ssh, arguments, stdin: stdin, timeout: command.timeout)
        } catch CommandError.timedOut {
            throw .timedOut(seconds: Int(command.timeout))
        } catch {
            throw VPSError(error)
        }
    }

    /// vpsmon exits 0 or 1 with one JSON object on stdout; 255 is ssh's own failure; 127 is the remote shell not
    /// finding vpsmon; anything else (sudo asking for a password) has only stderr to go on.
    static func interpret(_ output: CommandOutput) throws(VPSError) -> Data {
        let stdout = output.stdout
        let detail = lastLine(output.stderr)
        if output.status == 255 { throw .ssh(SSHFailure(stderr: detail)) }
        if output.status == 0 || output.status == 1,
           (try? JSONSerialization.jsonObject(with: stdout)) is [String: Any] {
            return stdout
        }
        if detail.contains("a password is required") || detail.contains("a terminal is required") {
            throw .sudoPassword
        }
        // vpsmon is there but sudo isn't: installing can't help, so this must not read as "vpsmon missing".
        if detail.contains("sudo"), detail.contains("not found") { throw .installer(.sudoMissing) }
        if output.status == 127 || detail.contains("command not found") || detail.contains("No such file") {
            throw .notInstalled
        }
        throw .failed(status: output.status, detail: detail)
    }

    /// The installer prints one JSON line; whatever a tool printed before it is ignored.
    static func installOutcome(_ output: CommandOutput) throws(VPSError) -> InstallOutcome {
        struct Line: Decodable {
            var ok: Bool
            var version: String?
            var changed: [String]?
            var error: String?
            var user: String?
        }
        let lines = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        let line = lines.reversed().lazy.compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }.first
        guard let line else {
            let detail = lastLine(output.stderr)
            throw detail.isEmpty ? .notJSON : .failed(status: output.status, detail: detail)
        }
        if line.ok { return .installed(version: line.version ?? "", changed: line.changed ?? []) }
        if line.error == "sudo-password", let user = line.user { return .needsPassword(user: user) }
        throw line.error.map { .installer(InstallerFailure(code: $0)) } ?? .serverSilent
    }

    static func lastLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// Serves a saved `status` output: the CLI's `--fixture` and the renderer. Never acts; `act` and `install` fail with
/// the error it was given.
public struct FixtureBackend: VPSBackend {
    public let snapshot: Snapshot
    public let refusal: VPSError

    public init(snapshot: Snapshot, refusal: VPSError = .serverSilent) {
        self.snapshot = snapshot
        self.refusal = refusal
    }

    public init(contentsOf url: URL) throws(VPSError) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VPSError(error) }
        self.init(snapshot: try SnapshotDecoding.snapshot(from: data))
    }

    public func status() async throws(VPSError) -> Snapshot { snapshot }
    public func startScan() async throws(VPSError) {}
    public func act(_ id: String) async throws(VPSError) -> ActResult { throw refusal }
    public func install(script: Data) async throws(VPSError) -> InstallOutcome { throw refusal }
}
