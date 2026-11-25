import Foundation
import Testing
@testable import MonitorCore

@MainActor
struct MonitorTests {
    let fixture: Snapshot

    init() throws { fixture = try Fixture.snapshot() }

    var critical: Snapshot {
        var s = fixture
        s.disks[0].freeBytes = 4 * GB
        return s
    }

    @Test func aPollGoesLiveAndNotifiesEachCriticalAlertOnce() async {
        let backend = FakeBackend(status: .success(critical))
        let (monitor, recorder) = makeMonitor(backend)
        await monitor.refresh()
        #expect(monitor.connection.snapshot == critical)
        #expect(monitor.menuBar.title == "Disk 97%")
        #expect(recorder.notifications.map(\.id) == ["alert-disk:/"])
        await monitor.refresh()
        #expect(recorder.notifications.count == 1)
    }

    @Test func notificationsOffDeliversNothing() async {
        var settings = Settings()
        settings.server = web1
        settings.notifications = false
        let (monitor, recorder) = makeMonitor(FakeBackend(status: .success(critical)), settings: settings)
        await monitor.refresh()
        #expect(recorder.notifications.isEmpty)
    }

    @Test func failuresKeepTheLastSnapshotAndNotifyOnTheThird() async {
        let backend = FakeBackend(status: .success(fixture), .failure(.ssh(.noRoute)), .failure(.ssh(.noRoute)),
                                  .failure(.ssh(.noRoute)))
        let (monitor, recorder) = makeMonitor(backend)
        await monitor.refresh()
        await monitor.refresh()
        #expect(monitor.connection.snapshot == fixture)
        #expect(monitor.connection.error == .ssh(.noRoute))
        #expect(monitor.menuBar.tint == .offline)
        await monitor.refresh()
        await monitor.refresh()
        #expect(recorder.notifications.last == NotificationEvent(
            id: "unreachable", title: "Can't reach web-1",
            body: "No route to the server: check your network or your VPN."))
    }

    /// The first run: no server, nothing polled, the plain icon.
    @Test func withoutAServerNothingIsAsked() async {
        let backend = FakeBackend(status: .success(fixture))
        let (monitor, _) = makeMonitor(backend, settings: Settings())
        #expect(monitor.connection == .noServer)
        await monitor.refresh()
        #expect(backend.calls.isEmpty)
        #expect(monitor.menuBar.tint == .neutral)
        #expect(monitor.menuBar.title == "")
    }

    @Test func nothingRunsWithoutAConfirmation() async {
        let backend = FakeBackend(status: .success(fixture))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        await monitor.perform("tmp-stale")
        await monitor.perform("proc:41822:303100000")
        await monitor.performBulk()
        #expect(!backend.calls.contains { if case .act = $0 { true } else { false } })
    }

    @Test func aConfirmedDiskActionRunsOnceAndRefreshes() async {
        let backend = FakeBackend(status: .success(fixture))
        backend.actResults["tmp-stale"] = .success(ActResult(id: "tmp-stale", freedBytes: 8_164_732_811,
                                                             message: "Removed 38 entries"))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        monitor.confirm("tmp-stale", in: .map)
        #expect(monitor.state(of: "tmp-stale") == .confirming(.map))
        await monitor.perform("tmp-stale")
        #expect(backend.calls == [.status, .act("tmp-stale"), .status])
        #expect(monitor.toast == "Freed 7.6 GB · Removed 38 entries")
    }

    /// End: `act proc:…`, a toast with what it freed, and a refresh.
    @Test func endingAProcessActsOnItsIdAndSaysWhatItFreed() async {
        let backend = FakeBackend(status: .success(fixture))
        let id = "proc:58840:326860000"
        backend.actResults[id] = .success(ActResult(id: id, freedBytes: 1_373_634_560, message: "Ended 17 processes"))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        monitor.confirm(id)
        await monitor.perform(id)
        #expect(backend.calls == [.status, .act(id), .status])
        #expect(monitor.toast == "Ended chrome (pid 58840) · freed 1.3 GB")
    }

    @Test func aRefusedEndShowsTheServersError() async {
        let backend = FakeBackend(status: .success(fixture))
        let id = "proc:41822:303100000"
        backend.actResults[id] = .failure(.server("The process is no longer the one listed"))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        monitor.confirm(id)
        await monitor.perform(id)
        #expect(monitor.state(of: id) == .failed(.server("The process is no longer the one listed")))
    }

    @Test func onlyOneConfirmationIsOpen() async {
        let (monitor, _) = makeMonitor(FakeBackend(status: .success(fixture)))
        await monitor.refresh()
        monitor.confirm("tmp-stale")
        monitor.confirm("proc:41822:303100000")
        #expect(monitor.state(of: "tmp-stale") == .idle)
        #expect(monitor.state(of: "proc:41822:303100000") == .confirming(.list))
        monitor.cancel("proc:41822:303100000")
        #expect(monitor.state(of: "proc:41822:303100000") == .idle)
    }

    @Test func closingASessionCopiesItsResumeCommand() async {
        let worker = fixture.workers[1]
        let backend = FakeBackend(status: .success(fixture))
        backend.actResults[worker.id] = .success(ActResult(id: worker.id, freedBytes: worker.memBytes,
                                                           message: "Closed", resumeCommand: "claude --resume abc"))
        let (monitor, recorder) = makeMonitor(backend)
        await monitor.refresh()
        monitor.confirm(worker.id)
        await monitor.perform(worker.id)
        #expect(backend.calls.contains(.act(worker.id)))
        #expect(recorder.clipboard == ["claude --resume abc"])
        #expect(monitor.toast == "Closed billing-tests · 379 MB · resume command copied")
    }

    @Test func bulkCloseActsOnePerSessionInOrderAndCopiesEveryCommand() async {
        let backend = FakeBackend(status: .success(fixture))
        let selection = BulkClose.selection(in: fixture)
        let (monitor, recorder) = makeMonitor(backend)
        await monitor.refresh()
        monitor.confirm(BulkClose.id)
        await monitor.performBulk()
        let acts = backend.calls.compactMap { if case .act(let id) = $0 { id } else { nil } }
        #expect(acts == selection.map(\.id))
        // The fake's results carry no resume command: the snapshot's are used.
        #expect(recorder.clipboard == [selection.map(\.resumeCommand).joined(separator: "\n")])
        #expect(backend.calls.last == .status)
    }

    @Test func bulkCloseSkipsARefusalButStopsWhenTheConnectionDrops() async {
        let selection = BulkClose.selection(in: fixture)
        let refused = FakeBackend(status: .success(fixture))
        refused.actResults[selection[0].id] = .failure(.server("No longer idle"))
        let (monitor, _) = makeMonitor(refused)
        await monitor.refresh()
        monitor.confirm(BulkClose.id)
        await monitor.performBulk()
        #expect(refused.calls.filter { if case .act = $0 { true } else { false } }.count == selection.count)
        #expect(monitor.state(of: BulkClose.id) == .failed(.other("Closed 1 of 2. billing-tests: No longer idle")))

        let dropped = FakeBackend(status: .success(fixture))
        dropped.actResults[selection[0].id] = .failure(.timedOut(seconds: 180))
        let (second, _) = makeMonitor(dropped)
        await second.refresh()
        second.confirm(BulkClose.id)
        await second.performBulk()
        #expect(dropped.calls.filter { if case .act = $0 { true } else { false } }.count == 1)
    }

    @Test func asksForAScanOnceWhenTheCachedOneIsOld() async {
        var old = fixture
        old.scan.at = old.at - 7 * 3_600
        let backend = FakeBackend(status: .success(old))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        await monitor.refresh()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(backend.calls.filter { $0 == .startScan }.count == 1)
    }

    @Test func aFreshScanIsLeftAlone() async {
        let backend = FakeBackend(status: .success(fixture))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!backend.calls.contains(.startScan))
    }

    @Test func changingTheServerStartsOver() async {
        let backend = FakeBackend(status: .success(fixture))
        let (monitor, recorder) = makeMonitor(backend)
        await monitor.refresh()
        monitor.settings.server = ServerAddress(host: "web-2")
        #expect(monitor.connection == .connecting)
        #expect(recorder.saved.last?.server == ServerAddress(host: "web-2"))
    }

    /// The server words its titles in the language it is asked for, so a new language asks again, in it.
    @Test func changingTheLanguageAsksTheServerAgainInIt() async {
        let backend = FakeBackend(status: .success(fixture))
        let log = BackendLog()
        let (monitor, _) = makeMonitor(backend, log: log)
        await monitor.refresh()
        #expect(monitor.strings.language == .en)
        monitor.settings.language = .spanish
        #expect(monitor.strings.language == .es)
        #expect(monitor.menuBar.title == "Disco 85%")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.requests.map(\.1) == [.en, .es])
        #expect(backend.calls == [.status, .status])
        #expect(monitor.connection.snapshot != nil)
    }

    @Test func systemFollowsTheMac() {
        var settings = Settings()
        settings.server = web1
        let (monitor, _) = makeMonitor(FakeBackend(status: .success(fixture)), settings: settings,
                                       preferred: ["es-ES", "en-US"])
        #expect(monitor.language == .es)
        #expect(monitor.strings.popover.quit == "Salir")
    }

    @Test func anOlderServerIsOutdatedAndUpdatesInPlace() async {
        var old = fixture
        old.version = "0.1.0"
        let backend = FakeBackend(status: .success(old), .success(fixture))
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        #expect(monitor.isOutdated)
        await monitor.updateServer()
        #expect(backend.calls == [.status, .install, .status])
        #expect(backend.scripts == [Data("#!/bin/sh\n".utf8)])
        #expect(monitor.updater?.state == .connected(fixture))
        #expect(!monitor.isOutdated)
        #expect(monitor.connection.snapshot == fixture)
        #expect(monitor.toast == nil)
    }

    @Test func anUpdateWithoutSystemdSaysHistoryStaysEmpty() async {
        var old = fixture
        old.version = "0.1.0"
        let backend = FakeBackend(status: .success(old), .success(fixture))
        backend.installResults = [.success(.installed(version: "0.2.0", changed: [InstallOutcome.timerSkipped]))]
        let (monitor, _) = makeMonitor(backend)
        await monitor.refresh()
        await monitor.updateServer()
        #expect(monitor.toast == "This server has no systemd, so vpsmon records no history: the 24 h charts stay empty.")
    }
}
