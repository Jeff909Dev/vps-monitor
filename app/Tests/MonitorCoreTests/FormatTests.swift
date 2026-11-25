import Foundation
import Testing
@testable import MonitorCore

struct FormatTests {
    @Test(arguments: [
        (22_655_952_486, "21.1 GB", "21,1 GB"),       // the fixture's free disk
        (8_164_732_811, "7.6 GB", "7,6 GB"),          // tmp-stale
        (161_061_273_600, "150 GB", "150 GB"),        // the disk
        (17_179_869_184, "16.0 GB", "16,0 GB"),       // the RAM
        (966_367_641, "922 MB", "922 MB"),
        (2_048, "2 KB", "2 KB"),
        (512, "512 B", "512 B"),
        (0, "0 B", "0 B"),
        (-3 * 1_073_741_824 / 2, "-1.5 GB", "-1,5 GB"),
    ] as [(Int64, String, String)])
    func bytesUseEachLanguagesDecimalMark(_ value: Int64, _ english: String, _ spanish: String) {
        #expect(en.format.bytes(value) == english)
        #expect(es.format.bytes(value) == spanish)
    }

    @Test(arguments: [
        (40.0, "40 s"), (59.9, "59 s"), (60, "1 min"), (720, "12 min"), (7 * 3_600, "7 h"),
        (30 * 3_600, "30 h"), (2 * 86_400, "2 d"), (9 * 86_400 - 1, "8 d"), (-5, "0 s"),
    ] as [(Double, String)])
    func durationsAreTheSameInBoth(_ seconds: Double, _ expected: String) {
        #expect(en.format.duration(seconds) == expected)
        #expect(es.format.duration(seconds) == expected)
    }

    @Test func agoAndForecast() {
        #expect(en.format.ago(seconds: 40) == "40 s ago")
        #expect(es.format.ago(seconds: 40) == "hace 40 s")
        #expect(en.format.ago(seconds: 2) == "now")
        #expect(es.format.ago(seconds: 2) == "ahora")
        #expect(en.format.forecast(hours: 6.91) == "~7 h")
        #expect(en.format.forecast(hours: 0.4) == "~24 min")
        #expect(en.format.forecast(hours: 60) == "~3 d")
    }

    @Test func numbersAndPercents() {
        #expect(en.format.number(5.41, decimals: 2) == "5.41")
        #expect(es.format.number(5.41, decimals: 2) == "5,41")
        #expect(en.format.percent(0.987) == "99%")
        #expect(es.format.percent(0.987) == "99%")
    }

    @Test func shortPaths() {
        #expect(Format.shortPath("/home/deploy/code/api") == "code/api")
        #expect(Format.shortPath("/srv") == "srv")
    }
}

struct PresentationTests {
    /// The server lists at most 25 items of an action; "and N more" counts every item it would free.
    @Test func confirmationCountsItemsTheServerDidNotList() {
        let labels = (1...25).map { "/tmp/entry-\($0)" }
        #expect(Presentation.confirmationList(labels, total: 30).more == 22)
        #expect(Presentation.confirmationList(labels).more == 17)
        #expect(Presentation.confirmationList(["a", "b"], total: 2).more == 0)
    }

    @Test func sessionsSummaryAndStates() throws {
        let s = try Fixture.snapshot()
        #expect(Presentation.sessionsSummary(s.workers, en) == "1 working · 3 idle · 2.5 GB")
        #expect(Presentation.sessionsSummary(s.workers, es) == "1 trabajando · 3 paradas · 2,5 GB")
        #expect(s.workers.map { Presentation.workerState($0, at: s.at, en) }
            == ["working", "idle 2 d", "idle 26 h", "idle 42 min"])
        #expect(Presentation.workerState(s.workers[1], at: s.at, es) == "parada 2 d")
        #expect(Presentation.sessionRatio(s) == "1/4")
        #expect(Presentation.bulkCloseLabel(BulkClose.selection(in: s), en)
            == "Close idle over 24 h (2) · frees 666 MB")
    }

    @Test func metricLinesInBothLanguages() throws {
        let s = try Fixture.snapshot()
        let disk = Presentation.disk(s.rootDisk, alerts: Health.alerts(for: s, en), en)
        #expect(disk.label == "disk")
        #expect(disk.value == "21.1 GB free of 150 GB")
        #expect(disk.detail == "+204 MB/h · full in ~4 d")
        #expect(disk.level == .warning)
        let memory = Presentation.memory(s, alerts: Health.alerts(for: s, en), en)
        #expect(memory.value == "4.7 GB available of 16.0 GB")
        #expect(memory.detail == "swap 922 MB of 4.0 GB (22%)")
        #expect(memory.level == nil)
        #expect(Presentation.cpu(s, en).value == "load 2.37 on 8 cores")
        #expect(Presentation.uptime(s, en) == "up 37 d")

        let data = Presentation.disk(s.disks[1], alerts: Health.alerts(for: s, en), en)
        #expect(data.label == "data")
        #expect(data.value == "895 GB free of 1007 GB")
        #expect(data.detail == "+114 MB/h · full in ~334 d")
        #expect(data.level == nil)
        #expect(Presentation.diskTooltip(s.disks[1]) == "/mnt/data · /dev/sdb · ext4")

        let disco = Presentation.disk(s.rootDisk, alerts: Health.alerts(for: s, es), es)
        #expect(disco.label == "disco")
        #expect(disco.value == "21,1 GB libres de 150 GB")
        #expect(disco.detail == "+204 MB/h · se llena en ~4 d")
        #expect(Presentation.memory(s, alerts: [], es).value == "4,7 GB libres de 16,0 GB")
        #expect(Presentation.cpu(s, es).value == "carga 2,37 de 8 núcleos")
    }

    @Test func menuBarStates() throws {
        let s = try Fixture.snapshot()
        let now = Date(timeIntervalSince1970: s.at + 40)
        let live = Presentation.menuBar(.live(s, at: now), host: "web-1", iconOnly: false, now: now, en)
        #expect(live.tint == .warning)
        #expect(live.title == "Disk 85%")
        #expect(live.tooltip == "web-1 · disk 85% full (21.1 GB free) · 1 of 4 Claude Code sessions working\n"
            + "Disk 85% full: 21.1 GB free of 150 GB.")
        #expect(Presentation.menuBar(.live(s, at: now), host: "web-1", iconOnly: false, now: now, es).title
            == "Disco 85%")
        #expect(Presentation.menuBar(.live(s, at: now), host: "web-1", iconOnly: true, now: now, en).title == "")

        var calm = s
        calm.disks[0].freeBytes = 80 * GB
        let normal = Presentation.menuBar(.live(calm, at: now), host: "web-1", iconOnly: false, now: now, en)
        #expect(normal.tint == .normal)
        #expect(normal.title == "1/4")

        // No sessions and no alert: just the icon.
        calm.workers = []
        let quiet = Presentation.menuBar(.live(calm, at: now), host: "web-1", iconOnly: false, now: now, en)
        #expect(quiet.title == "")
        #expect(!quiet.tooltip.contains("Claude Code"))

        let down = Presentation.menuBar(.unreachable(error: .ssh(.noRoute)), host: "web-1", iconOnly: false, now: now,
                                        en)
        #expect(down.tint == .offline)
        #expect(down.tooltip == "Can't reach web-1: No route to the server: check your network or your VPN.")
        let stale = Presentation.menuBar(.stale(s, at: now, error: .timedOut(seconds: 30)), host: "web-1",
                                         iconOnly: false, now: now, en)
        #expect(stale.tint == .offline)
        #expect(stale.title == "Disk 85%")

        let first = Presentation.menuBar(.noServer, host: "", iconOnly: false, now: now, en)
        #expect(first.tint == .neutral)
        #expect(first.title == "")
    }

    @Test func anOlderServerIsOutdated() throws {
        var s = try Fixture.snapshot()
        #expect(!Presentation.isOutdated(s, appVersion: "0.2.0"))
        #expect(Presentation.isOutdated(s, appVersion: "0.10.0"))
        s.version = "0.1.9"
        #expect(Presentation.isOutdated(s, appVersion: "0.2.0"))
        #expect(!Presentation.isOutdated(s, appVersion: "0.1.9-dev"))
        #expect(Version("1.0") == Version("1.0.0"))
    }
}
