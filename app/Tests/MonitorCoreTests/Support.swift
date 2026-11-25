import Foundation
@testable import MonitorCore

enum Fixture {
    /// The repo's fixtures: `web-1`, an invented host, as `vpsmon --lang en status` and `--lang es` print it.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")

    static func url(_ language: Language = .en) -> URL {
        directory.appendingPathComponent(language == .en ? "status.json" : "status.es.json")
    }

    static func data(_ language: Language = .en) throws -> Data { try Data(contentsOf: url(language)) }
    static func snapshot(_ language: Language = .en) throws -> Snapshot {
        try SnapshotDecoding.snapshot(from: data(language))
    }
}

let GB = Format.gib
let en = Strings.en
let es = Strings.es
let web1 = ServerAddress(host: "web-1", user: "deploy")

/// A backend that serves queued answers and records every call, in order.
final class FakeBackend: VPSBackend, @unchecked Sendable {
    enum Call: Equatable {
        case status, startScan, act(String), install
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var statusResults: [Result<Snapshot, VPSError>] = []
    var actResults: [String: Result<ActResult, VPSError>] = [:]
    var installResults: [Result<InstallOutcome, VPSError>] = [.success(.installed(version: "0.2.0", changed: []))]
    private(set) var scripts: [Data] = []

    var calls: [Call] { lock.withLock { _calls } }

    init(status: Result<Snapshot, VPSError>...) { statusResults = status }

    func status() async throws(VPSError) -> Snapshot {
        let result: Result<Snapshot, VPSError> = lock.withLock {
            _calls.append(.status)
            return statusResults.count > 1 ? statusResults.removeFirst() : statusResults[0]
        }
        return try result.get()
    }

    func startScan() async throws(VPSError) {
        lock.withLock { _calls.append(.startScan) }
    }

    func act(_ id: String) async throws(VPSError) -> ActResult {
        let result = lock.withLock {
            _calls.append(.act(id))
            return actResults[id] ?? .success(ActResult(id: id, freedBytes: 0, message: "Nothing to free"))
        }
        return try result.get()
    }

    func install(script: Data) async throws(VPSError) -> InstallOutcome {
        let result = lock.withLock {
            _calls.append(.install)
            scripts.append(script)
            return installResults.count > 1 ? installResults.removeFirst() : installResults[0]
        }
        return try result.get()
    }
}

/// What the Monitor did to the Mac, and which servers and languages it asked for backends.
@MainActor
final class Recorder {
    var notifications: [NotificationEvent] = []
    var clipboard: [String] = []
    var saved: [Settings] = []
}

final class BackendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(ServerAddress, Language)] = []
    var requests: [(ServerAddress, Language)] { lock.withLock { _requests } }
    func record(_ address: ServerAddress, _ language: Language) { lock.withLock { _requests.append((address, language)) } }
}

@MainActor
func makeMonitor(_ backend: FakeBackend, settings: Settings? = nil, installer: Data? = Data("#!/bin/sh\n".utf8),
                 appVersion: String = "0.2.0", preferred: [String] = ["en-US"], log: BackendLog = BackendLog(),
                 now: Date = Date(timeIntervalSince1970: 1_795_264_949)) -> (Monitor, Recorder) {
    let recorder = Recorder()
    var initial = Settings()
    initial.server = web1
    let env = Monitor.Environment(backend: { address, language in
                                      log.record(address, language)
                                      return backend
                                  },
                                  installer: { installer },
                                  appVersion: appVersion,
                                  preferredLanguages: { preferred },
                                  notify: { recorder.notifications += $0 },
                                  copy: { recorder.clipboard.append($0) },
                                  save: { recorder.saved.append($0) },
                                  now: { now })
    return (Monitor(settings: settings ?? initial, environment: env), recorder)
}

/// A runner that answers with a canned output and remembers what it was asked to run.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    var output: CommandOutput
    var arguments: [String] = []
    var stdin: Data?
    var timeout: TimeInterval = 0
    var throwsTimeout = false

    init(_ output: CommandOutput) { self.output = output }

    convenience init(_ status: Int32, stdout: String = "", stderr: String = "") {
        self.init(CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
    }

    func run(_ executable: URL, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> CommandOutput {
        self.arguments = arguments
        self.stdin = stdin
        self.timeout = timeout
        if throwsTimeout { throw CommandError.timedOut }
        return output
    }
}
