import Foundation
import Testing
@testable import MonitorCore

struct HealthTests {
    /// The fixture with one change.
    func snapshot(_ change: (inout Snapshot) -> Void = { _ in }) throws -> Snapshot {
        var s = try Fixture.snapshot()
        change(&s)
        return s
    }

    /// A calm machine: half the disk free, no growth, RAM and swap fine, no kills.
    func healthy(_ change: (inout Snapshot) -> Void = { _ in }) throws -> Snapshot {
        try snapshot { s in
            s.disk.totalBytes = 300 * GB
            s.disk.usedBytes = 150 * GB
            s.disk.freeBytes = 150 * GB
            s.disk.growthBytesPerHour = nil
            s.disk.fullInHours = nil
            s.memory.availableBytes = 12 * GB
            s.memory.swapUsedBytes = 1 * GB
            s.oomKills = []
            change(&s)
        }
    }

    @Test func theFixtureWarnsOnDiskInBothLanguages() throws {
        let s = try snapshot()
        let alerts = Health.alerts(for: s, en)
        #expect(alerts.map(\.id) == ["disk"])
        #expect(alerts.map(\.level) == [.warning])
        #expect(alerts[0].short == "Disk 85%")
        #expect(alerts[0].sentence == "Disk 85% full: 21.1 GB free of 150 GB.")
        let avisos = Health.alerts(for: s, es)
        #expect(avisos.map(\.id) == ["disk"])
        #expect(avisos[0].sentence == "Disco al 85%: quedan 21,1 GB libres de 150 GB.")
    }

    @Test func aHealthyMachineHasNoAlerts() throws {
        #expect(Health.alerts(for: try healthy(), en).isEmpty)
    }

    @Test(arguments: [
        // (free GB, total GB, expected level)
        (9.0, 1_000.0, AlertLevel.critical),   // 0.9%
        (40.0, 1_000.0, .critical),            // 4%: under 5%
        (29.0, 150.0, nil),                    // 19%: plenty on a small disk
        (100.0, 1_000.0, .warning),            // 10%: under 15%
        (31.0, 200.0, nil),                    // 15.5%
        (3.0, 25.0, .warning),                 // 12% of a small disk
        (33.1, 37.2, nil),                     // a fresh 40 GB server
    ] as [(Double, Double, AlertLevel?)])
    func diskThresholds(free: Double, total: Double, expected: AlertLevel?) throws {
        let s = try healthy {
            $0.disk.totalBytes = Int64(total * Double(GB))
            $0.disk.freeBytes = Int64(free * Double(GB))
            $0.disk.usedBytes = $0.disk.totalBytes - $0.disk.freeBytes
        }
        #expect(Health.alerts(for: s, en).first { $0.id == "disk" }?.level == expected)
    }

    @Test func fillingWithinADayIsCritical() throws {
        let filling = try healthy {
            $0.disk.fullInHours = 23
            $0.disk.growthBytesPerHour = 555_000_000
        }
        let alerts = Health.alerts(for: filling, en)
        #expect(alerts.map(\.id) == ["disk-fill"])
        #expect(alerts[0].short == "Full in ~23 h")
        #expect(alerts[0].sentence == "At the last 24 h's rate (+529 MB/h), the disk fills up in ~23 h.")
        #expect(Health.alerts(for: filling, es)[0].short == "Se llena en ~23 h")
        #expect(Health.alerts(for: try healthy { $0.disk.fullInHours = 25 }, en).isEmpty)
    }

    @Test func ramThresholds() throws {
        let critical = try healthy { $0.memory.totalBytes = 32 * GB; $0.memory.availableBytes = GB * 3 / 2 }
        let warning = try healthy { $0.memory.totalBytes = 32 * GB; $0.memory.availableBytes = 3 * GB }
        #expect(Health.alerts(for: critical, en).map(\.level) == [.critical])
        #expect(Health.alerts(for: critical, en).first?.short == "RAM 1.5 GB")
        #expect(Health.alerts(for: critical, es).first?.short == "RAM 1,5 GB")
        #expect(Health.alerts(for: warning, en).map(\.level) == [.warning])
    }

    /// A 4 GB server with 3.2 GB available is fine; it warns under 512 MB and is critical under 256 MB.
    @Test func ramThresholdsScaleWithTheServer() throws {
        func level(_ available: Int64) throws -> AlertLevel? {
            let s = try healthy { $0.memory.totalBytes = 4 * GB; $0.memory.availableBytes = available }
            return Health.alerts(for: s, en).first { $0.id == "ram" }?.level
        }
        #expect(try level(GB * 32 / 10) == nil)
        #expect(try level(400 * 1024 * 1024) == .warning)
        #expect(try level(200 * 1024 * 1024) == .critical)
    }

    @Test func swapOverNinetyPercentWarns() throws {
        let total = Int64(4) * GB
        #expect(Health.alerts(for: try healthy { $0.memory.swapUsedBytes = total * 95 / 100 }, en).map(\.id)
            == ["swap"])
        #expect(Health.alerts(for: try healthy { $0.memory.swapUsedBytes = total * 80 / 100 }, en).isEmpty)
    }

    @Test func aStoppedServiceIsCriticalAndComesFirst() throws {
        let s = try snapshot { $0.services[1].active = false }
        let alerts = Health.alerts(for: s, en)
        #expect(alerts.first?.id == "service:postgresql")
        #expect(alerts.first?.level == .critical)
        #expect(Health.worst(alerts)?.short == "postgresql down")
        #expect(Health.worst(Health.alerts(for: s, es))?.short == "postgresql caído")
    }

    @Test func anOOMKillWarnsForAnHour() throws {
        let recent = try healthy { $0.oomKills = [OOMKill(at: $0.at - 1_800, process: "node", pid: 42)] }
        let old = try healthy { $0.oomKills = [OOMKill(at: $0.at - 5_400, process: "node", pid: 42)] }
        #expect(Health.alerts(for: recent, en).map(\.short) == ["OOM: node"])
        #expect(Health.alerts(for: recent, en).first?.sentence
            == "The out-of-memory killer ended node (pid 42) 30 min ago.")
        #expect(Health.alerts(for: recent, es).first?.sentence.contains("hace 30 min") == true)
        #expect(Health.alerts(for: old, en).isEmpty)
    }

    @Test func anOldScanIsNotAnAlert() throws {
        #expect(Health.alerts(for: try healthy { $0.scan.at = $0.at - 3 * 86_400 }, en).isEmpty)
    }
}
