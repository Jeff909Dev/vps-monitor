import Foundation
import Observation

/// A dotted version, compared part by part as numbers: "0.10.0" is newer than "0.9.1". Anything after the numbers
/// ("0.2.0-dev") is ignored.
public struct Version: Comparable, Sendable {
    public let parts: [Int]

    public init(_ text: String) {
        parts = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// "1.0" and "1.0.0" are the same version.
    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// The Settings form as typed: four text fields. `address()` is the boundary where they become a `ServerAddress`.
public struct ServerForm: Equatable, Sendable {
    public var host = ""
    public var user = ""
    public var port = ""
    public var identityFile = ""

    public init(host: String = "", user: String = "", port: String = "", identityFile: String = "") {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    public init(_ address: ServerAddress?) {
        self.init(host: address?.host ?? "", user: address?.user ?? "", port: address?.port.map(String.init) ?? "",
                  identityFile: address?.identityFile ?? "")
    }

    /// Trimmed; an empty field is "not set", a port that isn't a number fails as port 0, and `~/` expands.
    public func address(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws(VPSError) -> ServerAddress {
        func field(_ text: String) -> String? {
            let text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let address = ServerAddress(host: field(host) ?? "", user: field(user),
                                    port: field(port).map { Int($0) ?? 0 },
                                    identityFile: field(identityFile).map(ServerAddress.expandingTilde))
        return try address.validated(fileExists: fileExists)
    }
}

/// Why connecting stopped short of a working server, when installing vpsmon is the cure.
public enum InstallReason: Equatable, Sendable {
    case missing
    case outdated(server: String, app: String)
    /// The server's vpsmon speaks this schema; the app speaks `SnapshotDecoding.schema`.
    case schema(Int)
    /// vpsmon is there but can't become root without a password: its sudoers rule is missing.
    case noSudoRule
}

/// Connecting a server from Settings, and updating vpsmon from the popover.
///
///     idle → testing → connected | needsInstall | failed
///     needsInstall → installing → testing | needsPassword | failed
///     needsPassword → testing (check again)
public enum SetupState: Equatable, Sendable {
    case idle
    case testing
    case connected(Snapshot)
    case needsInstall(InstallReason)
    case installing
    /// sudo on the server wants a password: this command, pasted into Terminal, installs it instead.
    case needsPassword(command: String)
    case failed(VPSError)

    /// What a `status` answer means for setup.
    public static func tested(_ result: Result<Snapshot, VPSError>, appVersion: String) -> SetupState {
        switch result {
        case .success(let snapshot):
            return Presentation.isOutdated(snapshot, appVersion: appVersion)
                ? .needsInstall(.outdated(server: snapshot.version, app: appVersion)) : .connected(snapshot)
        case .failure(.notInstalled): return .needsInstall(.missing)
        case .failure(.schema(let schema)): return .needsInstall(.schema(schema))
        case .failure(.sudoPassword): return .needsInstall(.noSudoRule)
        case .failure(let error): return .failed(error)
        }
    }

    /// What the installer's answer means: test again, paste a command, or a failure.
    public static func installed(_ result: Result<InstallOutcome, VPSError>, appVersion: String) -> SetupState {
        switch result {
        case .success(.installed): return .testing
        case .success(.needsPassword(let user)): return .needsPassword(command: installCommand(version: appVersion,
                                                                                             user: user))
        case .failure(let error): return .failed(error)
        }
    }

    /// The contract's paste-into-Terminal install, for the release that matches this app.
    public static func installCommand(version: String, user: String) -> String {
        "curl -fsSL https://github.com/Jeff909Dev/vps-monitor/releases/download/v\(version)/vpsmon-install.sh"
            + " | sudo sh -s -- --user \(user)"
    }

    /// The state offers Install / Update server.
    public var reason: InstallReason? {
        if case .needsInstall(let reason) = self { return reason }
        return nil
    }

    /// A request is on its way.
    public var isBusy: Bool { self == .testing || self == .installing }
}

/// Drives `SetupState` against one server through the Monitor's backend. Settings owns one for what is typed; the
/// Monitor owns one for "Update server" on the server it watches. A connected server becomes the Monitor's server.
@MainActor
@Observable
public final class ServerSetup {
    public private(set) var state: SetupState
    /// The server being set up: the last one `connect` was given.
    public private(set) var address: ServerAddress?
    /// The last install skipped the sample timer (no systemd): the server keeps no history.
    public private(set) var timerSkipped = false

    /// Held strongly: a setup that lost its monitor would do nothing. The monitor's own updater makes a cycle that
    /// lasts until the server changes, which is as long as it is needed.
    @ObservationIgnored private let monitor: Monitor
    /// Bumped by every request, so an answer that arrives after a newer request started is dropped.
    @ObservationIgnored private var generation = 0

    public init(monitor: Monitor, address: ServerAddress? = nil, state: SetupState = .idle) {
        self.monitor = monitor
        self.address = address
        self.state = state
    }

    /// Connect: parse the form, then read `status`.
    public func connect(_ form: ServerForm) async {
        let address: ServerAddress
        do { address = try form.address() } catch {
            generation += 1
            state = .failed(error)
            return
        }
        await connect(address)
    }

    public func connect(_ address: ServerAddress) async {
        self.address = address
        timerSkipped = false
        await test()
    }

    /// Check again, after the user ran the install command in Terminal.
    public func checkAgain() async {
        await test()
    }

    /// Install on server / Update server: the bundled installer over `sh -s`, then `status` again.
    public func install() async {
        guard let address else { return }
        generation += 1
        let mine = generation
        guard let script = monitor.installerScript() else {
            state = .failed(.noInstaller)
            return
        }
        state = .installing
        let result: Result<InstallOutcome, VPSError>
        do { result = .success(try await monitor.backend(for: address).install(script: script)) } catch {
            result = .failure(error)
        }
        guard mine == generation else { return }
        if case .success(.installed(_, let changed)) = result {
            timerSkipped = changed.contains(InstallOutcome.timerSkipped)
        }
        state = .installed(result, appVersion: monitor.appVersion)
        if state == .testing { await test() }
    }

    private func test() async {
        guard let address else { return }
        generation += 1
        let mine = generation
        state = .testing
        let result: Result<Snapshot, VPSError>
        do { result = .success(try await monitor.backend(for: address).status()) } catch { result = .failure(error) }
        guard mine == generation else { return }
        state = .tested(result, appVersion: monitor.appVersion)
        if case .connected(let snapshot) = state { monitor.serverConnected(address, snapshot) }
    }
}
