import Foundation
import Testing
@testable import MonitorCore

struct DiskMapTests {
    /// 270 GB used and 18 GB free now; the scan saw 268 GB in use.
    func snapshot() throws -> Snapshot {
        var s = try Fixture.snapshot()
        s.disk.usedBytes = 270 * GB
        s.disk.freeBytes = 18 * GB
        s.disk.totalBytes = 300 * GB
        s.scan.map = DiskMap(usedBytes: 268 * GB, groups: [
            MapGroup(id: "home", title: "Home folders", hint: "/home/* and /root", bytes: 80 * GB,
                     freeableBytes: 2 * GB, actions: ["claude-versions"],
                     children: [MapChild(path: "/home/deploy/code", bytes: 30 * GB)]),
            MapGroup(id: "docker", title: "Docker", hint: "Images", bytes: 30 * GB, freeableBytes: 0, actions: [],
                     children: []),
            MapGroup(id: "swap", title: "Swap", hint: "RAM overflow", bytes: GB, freeableBytes: 0, actions: [],
                     children: []),
            MapGroup(id: "rest", title: "Everything else", hint: "The rest", bytes: 157 * GB, freeableBytes: 0,
                     actions: [], children: []),
        ])
        return s
    }

    @Test func theBarSplitsWhatIsUsedNowByTheMapThenShowsTheFreeSpace() throws {
        let s = try snapshot()
        let bar = Presentation.diskBar(s)
        #expect(bar.map(\.group?.id) == ["home", "docker", "swap", "rest", nil])
        #expect(abs(bar.reduce(0) { $0 + $1.fraction } - 1) < 1e-12)
        #expect(abs(bar[0].fraction - 270.0 / 288 * 80 / 268) < 1e-12)
        #expect(abs(bar[4].fraction - 18.0 / 288) < 1e-12)
    }

    @Test func sharesAreOfWhatDfCountsAndFreeableOnlyWhenThereIsSome() throws {
        let s = try snapshot()
        #expect(Presentation.share(80 * GB, of: s.disk) == "28%")
        #expect(Presentation.share(GB, of: s.disk) == "<1%")
        #expect(Presentation.share(0, of: s.disk) == "0%")
        #expect(Presentation.freeable(s.scan.map.groups[0], en) == "2.0 GB can be freed")
        #expect(Presentation.freeable(s.scan.map.groups[0], es) == "2,0 GB liberables")
        #expect(Presentation.freeable(s.scan.map.groups[1], en) == nil)
        #expect(Presentation.mapTitle(s, en) == "where the 300 GB go")
        #expect(Presentation.mapTitle(s, es) == "en qué se van los 300 GB")
    }

    /// An open group offers the disk actions that free space in it, so temp files empty from where they show.
    @Test func aGroupOffersTheActionsThatFreeItsSpace() throws {
        let s = try Fixture.snapshot()
        let temp = try #require(s.scan.map.groups.first { $0.id == "temp" })
        #expect(Presentation.actions(of: temp, in: s.scan).map(\.id) == ["tmp-stale", "claude-tmp"])
        #expect(Presentation.freeable(temp, en) == "9.9 GB can be freed")
        let system = try #require(s.scan.map.groups.first { $0.id == "system" })
        #expect(Presentation.actions(of: system, in: s.scan).isEmpty)
        // An action that already ran is gone from the scan, so its group stops offering it.
        var after = s.scan
        after.actions.removeAll { $0.id == "tmp-stale" }
        #expect(Presentation.actions(of: temp, in: after).map(\.id) == ["claude-tmp"])
    }

    @Test func statusTextListsEveryGroupItsFoldersAndItsActions() throws {
        let s = try snapshot()
        let now = Date(timeIntervalSince1970: s.at + 40)
        let lines = Presentation.text(.live(s, at: now), host: "web-1", now: now, en).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "where the 300 GB go · 268 GB used"))
        #expect(Array(lines[(start + 1)...]) == [
            "  80.0 GB  28%  Home folders · 2.0 GB can be freed",
            "                  30.0 GB  /home/deploy/code",
            "                  635 MB   Free: Old Claude Code versions  (claude-versions)",
            "  30.0 GB  10%  Docker",
            "  1.0 GB   <1%  Swap",
            "  157 GB   55%  Everything else",
        ])
    }
}

struct RAMTests {
    @Test func theBarIsEachProgramThenTheRestOfTheUsedRAMThenWhatIsAvailable() throws {
        let m = try Fixture.snapshot().memory
        let bar = Presentation.ramBar(m)
        #expect(bar.count == 10)
        #expect(bar.prefix(8).map { if case .group(let g, _) = $0.kind { g.name } else { "" } }
            == m.groups.map(\.name))
        #expect(bar[8].kind == .other)
        #expect(bar[9].kind == .available)
        #expect(abs(bar.reduce(0) { $0 + $1.fraction } - 1) < 1e-12)
        #expect(abs(bar[0].fraction - Double(m.groups[0].bytes) / Double(m.totalBytes)) < 1e-12)
        #expect(abs(bar[9].fraction - Double(m.availableBytes) / Double(m.totalBytes)) < 1e-12)
    }

    /// Bytes count swap too: programs that add up to more than the used RAM shrink to fit, with no "other".
    @Test func programsThatOverflowTheUsedRAMShrinkToFit() throws {
        var m = try Fixture.snapshot().memory
        m.availableBytes = m.totalBytes / 2
        m.groups[0].bytes = m.totalBytes
        let bar = Presentation.ramBar(m)
        #expect(!bar.contains { $0.kind == .other })
        #expect(abs(bar.dropLast().reduce(0) { $0 + $1.fraction } - 0.5) < 1e-12)
        #expect(abs(bar.reduce(0) { $0 + $1.fraction } - 1) < 1e-12)
    }

    @Test func groupsAndShares() throws {
        let s = try Fixture.snapshot()
        let node = s.memory.groups[0]
        #expect(Presentation.groupName(node) == "node ×23")
        #expect(Presentation.share(node.bytes, ofRAM: s.memory) == "24%")
        #expect(Presentation.ramTitle(s, en) == "where the 16.0 GB of RAM go")
        #expect(Presentation.ramTitle(s, es) == "en qué se van los 16,0 GB de RAM")
    }

    @Test func endNamesTheProcessItsChildrenAndWhatItFrees() throws {
        let s = try Fixture.snapshot()
        let node = s.memory.groups[0]
        #expect(Presentation.endQuestion(node.processes[0], in: node, en)
            == "End node (pid 41822)? It also ends 3 child processes. Frees 1.4 GB.")
        #expect(Presentation.endQuestion(node.processes[0], in: node, es)
            == "¿Terminar node (pid 41822)? También termina 3 procesos hijos. Libera 1,4 GB.")
        #expect(Presentation.endQuestion(node.processes[1], in: node, en)
            == "End node (pid 41907)? Frees 860 MB.")
        #expect(en.ram.endConfirm(en.format.bytes(node.processes[0].treeBytes)) == "End · frees 1.4 GB")
    }

    @Test func commandsLeadWithTheProgramsName() throws {
        let m = try Fixture.snapshot().memory
        let chrome = try #require(m.groups.first { $0.name == "chrome" })
        #expect(Presentation.command(chrome.processes[1]) == "chrome --type=renderer --headless=new --lang=en-US")
        #expect(Presentation.command(m.groups[0].processes[0]) == "node /srv/api/dist/server.js --port 3000")
        let postgres = try #require(m.groups.first { $0.name == "postgres" })
        #expect(Presentation.command(postgres.processes[0]).hasPrefix("postgres: 16/main"))
    }

    @Test func statusTextShowsEachProgramAndWhatEndingAProcessFrees() throws {
        let s = try Fixture.snapshot()
        let now = Date(timeIntervalSince1970: s.at + 40)
        let lines = Presentation.text(.live(s, at: now), host: "web-1", now: now, en).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "where the 16.0 GB of RAM go"))
        #expect(lines[start + 1] == "  3.9 GB   24%  node ×23")
        #expect(lines[start + 2] == "                  1.2 GB   deploy    node /srv/api/dist/server.js --port 3000"
            + "  · end frees 1.4 GB (proc:41822:303100000)")
        // Not killable: no End.
        let claude = try #require(lines.firstIndex { $0.hasSuffix("claude ×4") })
        #expect(!lines[claude + 1].contains("end frees"))
    }
}
