import Foundation
import Observation

/// The app's state and everything the popover can do. It polls `status`, judges it, and runs the actions the user
/// confirmed, one `act` at a time.
@MainActor
@Observable
public final class Monitor {
    /// The world outside: how to reach a server, the installer this app carries, and the Mac's notifications,
    /// clipboard, storage, languages and clock.
    public struct Environment {
        public var backend: @Sendable (ServerAddress, Language) -> any VPSBackend
        /// `vpsmon-install.sh`, or nil in a build that carries none.
        public var installer: @Sendable () -> Data?
        /// This app's version, which is also the version of the vpsmon it installs.
        public var appVersion: String
        /// The Mac's preferred languages, first first: what "System" follows.
        public var preferredLanguages: @Sendable () -> [String]
        public var notify: @MainActor ([NotificationEvent]) -> Void
        public var copy: @MainActor (String) -> Void
        public var save: @MainActor (Settings) -> Void
        public var now: @MainActor () -> Date

        public init(backend: @escaping @Sendable (ServerAddress, Language) -> any VPSBackend,
                    installer: @escaping @Sendable () -> Data? = { nil },
                    appVersion: String = "0.0.0",
                    preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
                    notify: @escaping @MainActor ([NotificationEvent]) -> Void = { _ in },
                    copy: @escaping @MainActor (String) -> Void = { _ in },
                    save: @escaping @MainActor (Settings) -> Void = { _ in },
                    now: @escaping @MainActor () -> Date = { Date() }) {
            self.backend = backend
            self.installer = installer
            self.appVersion = appVersion
            self.preferredLanguages = preferredLanguages
            self.notify = notify
            self.copy = copy
            self.save = save
            self.now = now
        }
    }

    public static let toastSeconds: Double = 8

    public private(set) var connection: Connection
    /// A `status` is in flight. A count, so a fetch abandoned by a server change can't end another's spinner.
    public var isFetching: Bool { fetchesInFlight > 0 }
    private var fetchesInFlight = 0
    /// Keyed by action id: a disk action, `worker:…`, `proc:…`, or `BulkClose.id`. A missing key is `.idle`.
    public private(set) var actionStates: [String: ActionState] = [:]
    /// `scan --background` was sent and the server hasn't reported it running yet.
    public private(set) var isStartingScan = false
    public private(set) var toast: String?
    /// "Update server" on the server this monitor watches; nil until it is asked for.
    public private(set) var updater: ServerSetup?

    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            env.save(settings)
            if settings.server != oldValue.server {
                // Another server: nothing known about the old one applies.
                connectBackend()
                connection = settings.server == nil ? .noServer : .connecting
                actionStates = [:]
                gate = NotificationGate()
                autoScannedFor = .none
                updater = nil
                if loop != nil { restartLoop() }
            } else if settings.language != oldValue.language {
                // The server words its titles and errors in the language it is asked for: ask again.
                connectBackend()
                if settings.server != nil { Task { await refresh() } }
            }
            if settings.interval != oldValue.interval, loop != nil { restartLoop() }
        }
    }

    public var appVersion: String { env.appVersion }

    @ObservationIgnored private let env: Environment
    @ObservationIgnored private var backend: (any VPSBackend)?
    /// Bumped with every new backend, so an answer from the previous one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var gate = NotificationGate()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// The scan (by its `at`; nil for "never scanned") the app already asked to replace, so it asks once.
    @ObservationIgnored private var autoScannedFor: Double?? = .none

    public init(settings: Settings, environment: Environment, connection: Connection? = nil) {
        self.settings = settings
        self.env = environment
        self.connection = connection ?? (settings.server == nil ? .noServer : .connecting)
        connectBackend()
    }

    private func connectBackend() {
        generation += 1
        inflight = nil
        backend = settings.server.map { env.backend($0, language) }
    }

    // MARK: Derived

    /// The language the app shows and asks the server for.
    public var language: Language { settings.language.resolved(preferred: env.preferredLanguages()) }
    public var strings: Strings { Strings.for(language) }
    public var hostName: String { settings.server?.host ?? "" }
    public var snapshot: Snapshot? { connection.snapshot }
    public var alerts: [Alert] { snapshot.map { Health.alerts(for: $0, strings) } ?? [] }
    public var bulkSelection: [Worker] { snapshot.map(BulkClose.selection) ?? [] }
    /// An `act` is running; every other destructive button waits for it.
    public var isActing: Bool { actionStates.values.contains(.running) }
    /// The server's vpsmon is older than the one this app carries.
    public var isOutdated: Bool { snapshot.map { Presentation.isOutdated($0, appVersion: appVersion) } ?? false }

    public func state(of id: String) -> ActionState { actionStates[id] ?? .idle }

    public var menuBar: MenuBarState {
        Presentation.menuBar(connection, host: hostName, iconOnly: settings.iconOnly, now: env.now(), strings)
    }

    /// A backend for any server, in the current language: Settings tests what is typed with it.
    public func backend(for address: ServerAddress) -> any VPSBackend {
        env.backend(address, language)
    }

    public func installerScript() -> Data? { env.installer() }

    // MARK: Polling

    public func start() {
        restartLoop()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Polls now and then every interval. The loop holds the model only during a poll, never while it sleeps.
    private func restartLoop() {
        loop?.cancel()
        let interval = settings.interval.seconds
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func popoverOpened() {
        Task { await refresh() }
    }

    /// One `status`. A call made while one is in flight waits for that one instead of starting another.
    public func refresh() async {
        if let inflight { return await inflight.value }
        let task = Task { await fetch() }
        inflight = task
        await task.value
        if inflight == task { inflight = nil }
    }

    private func fetch() async {
        guard let backend else { return }
        let mine = generation
        fetchesInFlight += 1
        defer { fetchesInFlight -= 1 }
        do {
            let snapshot = try await backend.status()
            guard mine == generation else { return }
            apply(snapshot)
        } catch {
            guard mine == generation else { return }
            connection = connection.failed(error)
            deliver(gate.pollFailed(host: hostName, error: error.message(strings), strings))
        }
    }

    private func apply(_ snapshot: Snapshot) {
        connection = connection.received(snapshot, at: env.now())
        deliver(gate.pollSucceeded(host: snapshot.host, alerts: Health.alerts(for: snapshot, strings), strings))
        pruneActionStates(snapshot)
        if snapshot.scan.running { isStartingScan = false }
        if ScanPolicy.isStale(snapshot.scan, at: snapshot.at), autoScannedFor != .some(snapshot.scan.at),
           let backend {
            autoScannedFor = .some(snapshot.scan.at)
            Task { try? await backend.startScan() }
        }
    }

    /// Finished results were shown (and toasted); rows that left the snapshot take their state with them. A
    /// confirmation, a running act and an error stay.
    private func pruneActionStates(_ snapshot: Snapshot) {
        let present = Set(snapshot.workers.map(\.id) + snapshot.scan.actions.map(\.id)
            + snapshot.memory.groups.flatMap { $0.processes.map(\.id) } + [BulkClose.id])
        actionStates = actionStates.filter { id, state in
            guard present.contains(id) else { return false }
            if case .done = state { return false }
            return true
        }
    }

    private func deliver(_ events: [NotificationEvent]) {
        if settings.notifications, !events.isEmpty { env.notify(events) }
    }

    // MARK: Server

    /// Setup reached a working server: it becomes the one this monitor watches, live at once.
    func serverConnected(_ address: ServerAddress, _ snapshot: Snapshot) {
        if settings.server != address { settings.server = address }
        apply(snapshot)
    }

    /// Install or update vpsmon on the server this monitor watches, then poll it.
    public func updateServer() async {
        guard let server = settings.server else { return }
        let setup = updater ?? ServerSetup(monitor: self, address: server)
        updater = setup
        await setup.install()
        // The banner goes away on success, so the one thing worth knowing about the install becomes a toast.
        if case .connected = setup.state, setup.timerSkipped { showToast(strings.setup.noTimer) }
    }

    /// "Check again" after the install command ran in Terminal.
    public func checkServerAgain() async {
        await updater?.checkAgain()
    }

    // MARK: Actions

    /// Expands the row into its inline confirmation; any other open confirmation closes.
    public func confirm(_ id: String, in place: Place = .list) {
        guard !isActing else { return }
        for (other, state) in actionStates where state.isConfirming { actionStates[other] = .idle }
        actionStates[id] = .confirming(place)
    }

    /// A confirmation left open isn't still meant when the popover opens again later.
    public func popoverClosed() {
        actionStates = actionStates.filter { !$0.value.isConfirming }
    }

    /// Cancel, or dismiss a result.
    public func cancel(_ id: String) {
        guard state(of: id) != .running else { return }
        actionStates[id] = nil
    }

    /// Runs a confirmed disk action, session close or process end, then refreshes.
    public func perform(_ id: String) async {
        guard state(of: id).isConfirming, let snapshot, let target = ActionTarget(id: id, in: snapshot) else { return }
        let s = strings
        switch target {
        case .worker(let worker):
            if case .success(let closed) = await close(worker) {
                env.copy(closed.resumeCommand)
                showToast(s.toasts.closed(worker.name, s.format.bytes(closed.freedBytes)))
            }
        case .process(let process, let group):
            if let result = await act(id) {
                showToast(s.toasts.ended(group.name, process.pid, s.format.bytes(result.freedBytes)))
            }
        case .disk:
            if let result = await act(id) {
                showToast(result.freedBytes > 0 ? s.toasts.freed(s.format.bytes(result.freedBytes), result.message)
                                                : result.message)
            }
        }
        await refresh()
    }

    /// One `act`, with its row's state.
    private func act(_ id: String) async -> ActResult? {
        guard let backend else { return nil }
        actionStates[id] = .running
        do {
            let result = try await backend.act(id)
            actionStates[id] = .done(freedBytes: result.freedBytes, message: result.message)
            return result
        } catch {
            actionStates[id] = .failed(error)
            return nil
        }
    }

    /// Closes every session in the bulk selection, one `act` each, then copies all their resume commands. A session
    /// the server refuses is skipped; losing the connection stops the batch.
    public func performBulk() async {
        guard state(of: BulkClose.id).isConfirming else { return }
        let s = strings
        let selection = bulkSelection
        actionStates[BulkClose.id] = .running
        var commands: [String] = []
        var freed: Int64 = 0
        var problem: (name: String, error: VPSError)?
        batch: for worker in selection {
            switch await close(worker) {
            case .success(let closed):
                commands.append(closed.resumeCommand)
                freed += closed.freedBytes
            case .failure(let error):
                problem = (worker.name, error)
                if error.isTransport { break batch }
            }
        }
        if !commands.isEmpty { env.copy(commands.joined(separator: "\n")) }
        if let problem {
            actionStates[BulkClose.id] = .failed(.other(s.toasts.bulkPartly(commands.count, selection.count,
                                                                           problem.name, problem.error.message(s))))
        } else {
            actionStates[BulkClose.id] = .done(freedBytes: freed, message: s.toasts.bulkClosed(commands.count))
        }
        if !commands.isEmpty {
            showToast(s.toasts.bulkCopied(commands.count, selection.count, s.format.bytes(freed)))
        }
        await refresh()
    }

    struct Closed {
        var resumeCommand: String
        var freedBytes: Int64
    }

    /// One `act worker:…`; the resume command falls back to the one the snapshot listed.
    private func close(_ worker: Worker) async -> Result<Closed, VPSError> {
        guard let backend else { return .failure(.invalidServer(.host(""))) }
        actionStates[worker.id] = .running
        do {
            let result = try await backend.act(worker.id)
            actionStates[worker.id] = .done(freedBytes: result.freedBytes, message: result.message)
            return .success(Closed(resumeCommand: result.resumeCommand ?? worker.resumeCommand,
                                   freedBytes: result.freedBytes))
        } catch {
            actionStates[worker.id] = .failed(error)
            return .failure(error)
        }
    }

    /// "Scan again".
    public func rescan() async {
        guard let backend else { return }
        isStartingScan = true
        do {
            try await backend.startScan()
            await refresh()
        } catch {
            isStartingScan = false
            showToast(strings.toasts.scanFailed(error.message(strings)))
        }
    }

    /// The context menu's "Copy resume command".
    public func copyResume(_ worker: Worker) {
        env.copy(worker.resumeCommand)
        showToast(strings.toasts.resumeCopied(worker.name))
    }

    /// Copies a text and says so: the install command of Settings and the popover.
    public func copy(_ text: String) {
        env.copy(text)
        showToast(strings.toasts.copied)
    }

    public func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
