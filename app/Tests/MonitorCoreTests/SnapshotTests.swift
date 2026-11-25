import Foundation
import Testing
@testable import MonitorCore

struct SnapshotTests {
    @Test func decodesTheEnglishFixture() throws {
        let s = try Fixture.snapshot()
        #expect(s.schema == 3)
        #expect(s.version == "0.3.0")
        #expect(s.host == "web-1")
        #expect(s.cpu.cores == 8)
        #expect(s.rootDisk.freeBytes == 22_655_952_486)
        #expect(s.services.map(\.name) == ["nginx", "postgresql", "docker"])
        #expect(s.oomKills.first?.process == "chrome")
        #expect(s.workers.map(\.name) == ["api-refactor", "billing-tests", "infra-notes", "docs-site"])
        #expect(s.workers.map(\.user) == ["deploy", "deploy", "root", "deploy"])
        #expect(s.workers.first?.state == .busy)
        #expect(s.history.count == 288)
        #expect(s.scan.actions.map(\.id) == ["tmp-stale", "docker-images", "claude-tmp", "pkg-caches",
                                             "docker-build-cache", "big-logs", "journal", "claude-versions",
                                             "apt-cache"])
        #expect(s.scan.actions.first { $0.id == "big-logs" }?.risk == .review)
        #expect(s.scan.actions[0].title == "Old temporary files")
        #expect(s.scan.map.groups.reduce(0) { $0 + $1.bytes } == s.scan.map.usedBytes)
        #expect(s.scan.map.groups.last?.id == "rest")
        #expect(s.scan.map.groups.first { $0.id == "temp" }?.actions == ["tmp-stale", "claude-tmp"])
    }

    @Test func decodesWhereTheRAMGoes() throws {
        let m = try Fixture.snapshot().memory
        #expect(m.processBytes == 12_025_908_428)
        #expect(m.groups.map(\.name) == ["node", "postgres", "claude", "chrome", "dockerd", "python3", "redis-server",
                                         "nginx"])
        let node = try #require(m.groups.first)
        #expect(node.count == 23)
        #expect(node.processes.count == 6)
        let api = node.processes[0]
        #expect(api.id == "proc:41822:303100000")
        #expect(api.user == "deploy")
        #expect(api.command == "node /srv/api/dist/server.js --port 3000")
        #expect(api.treeBytes > api.bytes)
        #expect(api.children == 3)
        #expect(api.killable)
        // Claude Code sessions close from their own list; the server marks their processes not killable.
        #expect(m.groups.first { $0.name == "claude" }?.processes.allSatisfy { !$0.killable } == true)
    }

    /// The Spanish status is the same host: every number equal, only the server's own words translated.
    @Test func theSpanishFixtureIsTheSameHostInSpanish() throws {
        let en = try Fixture.snapshot(.en)
        let es = try Fixture.snapshot(.es)
        #expect(es.memory == en.memory)
        #expect(es.disks == en.disks)
        #expect(es.workers == en.workers)
        #expect(es.history == en.history)
        #expect(es.scan.actions.map(\.id) == en.scan.actions.map(\.id))
        #expect(es.scan.actions.map(\.bytes) == en.scan.actions.map(\.bytes))
        #expect(es.scan.map.groups.map(\.bytes) == en.scan.map.groups.map(\.bytes))
        #expect(es.scan.actions[0].title == "Temporales viejos")
        #expect(es.scan.map.groups.first { $0.id == "temp" }?.title == "Temporales")
        for (a, b) in zip(en.scan.actions, es.scan.actions) {
            #expect(a.title != b.title, "\(a.id) is not translated")
            #expect(a.items.map(\.bytes) == b.items.map(\.bytes))
        }
        // Paths are never translated.
        #expect(es.scan.actions[0].items == en.scan.actions[0].items)
    }

    @Test func diskUsageIsWhatDfCallsUsePercent() throws {
        let s = try Fixture.snapshot()
        // used / (used + free): root's reserved blocks don't count as free.
        #expect(en.format.percent(s.rootDisk.usedFraction) == "85%")
    }

    /// Root first, then the other disks by mount; each history point holds every disk it saw.
    @Test func decodesEveryDisk() throws {
        let s = try Fixture.snapshot()
        #expect(s.disks.map(\.mount) == ["/", "/mnt/data"])
        #expect(s.disks.map(\.device) == ["/dev/sda1", "/dev/sdb"])
        #expect(s.disks.map(\.fstype) == ["ext4", "ext4"])
        #expect(s.disks.map(\.isRoot) == [true, false])
        #expect(s.disks[1].name == "data")
        #expect(s.disks[1].totalBytes == 1_081_043_268_403)
        #expect(s.history.allSatisfy { Set($0.disks.keys) == ["/", "/mnt/data"] })
        #expect(s.history.last?.disks["/mnt/data"] == s.disks[1].usedBytes)
    }

    /// The decoder makes sure root is there and first, so everything past it can lean on `rootDisk`.
    @Test func statusWithoutRootFirstBreaksTheContract() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data()) as! [String: Any]
        json["disks"] = Array((json["disks"] as! [[String: Any]]).reversed())
        let reversed = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: VPSError.contract(.missing("disks[/]"))) { try SnapshotDecoding.snapshot(from: reversed) }
        json["disks"] = []
        let empty = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: VPSError.contract(.missing("disks[/]"))) { try SnapshotDecoding.snapshot(from: empty) }
    }

    /// What a 0.2.0 server prints (one `disk`, schema 2) is a server to update, not a broken answer.
    @Test func aSchema2ServerIsAServerToUpdate() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data()) as! [String: Any]
        json["schema"] = 2
        json["version"] = "0.2.0"
        json["disk"] = (json.removeValue(forKey: "disks") as! [[String: Any]])[0]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: VPSError.schema(2)) { try SnapshotDecoding.snapshot(from: data) }
        let state = SetupState.tested(.failure(.schema(2)), appVersion: "0.3.0")
        #expect(state == .needsInstall(.schema(2)))
        #expect(Presentation.setupLine(state, host: "web-1", en)
            == "web-1 runs a vpsmon that speaks schema 2; this app needs schema 3.")
        if case .needsInstall(let reason) = state { #expect(Presentation.installButton(reason, en) == en.setup.update) }
    }

    @Test func anUnknownWorkerStateOrRiskIsReadSafely() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data()) as! [String: Any]
        var workers = json["workers"] as! [[String: Any]]
        workers[0]["state"] = "compacting"
        json["workers"] = workers
        var scan = json["scan"] as! [String: Any]
        var actions = scan["actions"] as! [[String: Any]]
        actions[0]["risk"] = "dangerous"
        scan["actions"] = actions
        json["scan"] = scan
        let s = try SnapshotDecoding.snapshot(from: JSONSerialization.data(withJSONObject: json))
        #expect(s.workers[0].state == .unknown)
        #expect(s.scan.actions[0].risk == .review)
    }

    @Test func aNeverScannedHostWithoutSessionsDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data()) as! [String: Any]
        json["scan"] = ["at": NSNull(), "running": false, "actions": [], "map": ["usedBytes": 0, "groups": []]]
        json["workers"] = []
        json["disks"] = (json["disks"] as! [[String: Any]]).map { disk in
            disk.merging(["growthBytesPerHour": NSNull(), "fullInHours": NSNull()]) { $1 }
        }
        let s = try SnapshotDecoding.snapshot(from: JSONSerialization.data(withJSONObject: json))
        #expect(s.scan.at == nil)
        #expect(s.scan.map.groups.isEmpty)
        #expect(s.workers.isEmpty)
        #expect(Presentation.diskBar(s.rootDisk, in: s).map(\.kind) == [.used(s.rootDisk.usedBytes), .free])
        #expect(s.disks.allSatisfy { $0.fullInHours == nil })
    }

    @Test func aHandledServerErrorKeepsItsMessage() {
        let data = Data(#"{"ok": false, "error": "No such action: foo"}"#.utf8)
        #expect(throws: VPSError.server("No such action: foo")) { try SnapshotDecoding.snapshot(from: data) }
        #expect(throws: VPSError.serverSilent) { try SnapshotDecoding.snapshot(from: Data(#"{"ok": false}"#.utf8)) }
        #expect(throws: VPSError.notJSON) { try SnapshotDecoding.snapshot(from: Data("sudo: oops".utf8)) }
    }

    /// Another schema is not "broken": it is a server to update, even when the rest no longer decodes.
    @Test(arguments: [1, 2, 4])
    func anotherSchemaIsNamedBeforeAnythingElseIsRead(_ schema: Int) throws {
        let data = Data(#"{"ok": true, "schema": \#(schema), "host": "web-1"}"#.utf8)
        #expect(throws: VPSError.schema(schema)) { try SnapshotDecoding.snapshot(from: data) }
    }

    @Test func aMissingFieldIsNamed() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data()) as! [String: Any]
        var memory = json["memory"] as! [String: Any]
        memory.removeValue(forKey: "processBytes")
        json["memory"] = memory
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: VPSError.contract(.missing("memory.processBytes"))) {
            try SnapshotDecoding.snapshot(from: data)
        }
        #expect(VPSError.contract(.missing("memory.processBytes")).message(en)
            == "vpsmon's answer doesn't match the contract: memory.processBytes is missing.")
    }

    @Test func decodesAnActResult() throws {
        let data = Data(#"""
        {"ok": true, "id": "worker:52310:326136400", "freedBytes": 1210000000, "message": "Closed api-refactor",
         "dryRun": false, "items": [], "resumeCommand": "claude --resume 1f0e"}
        """#.utf8)
        let result = try SnapshotDecoding.actResult(from: data)
        #expect(result.freedBytes == 1_210_000_000)
        #expect(result.resumeCommand == "claude --resume 1f0e")
    }
}
