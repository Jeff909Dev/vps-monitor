import Foundation
import Testing
@testable import MonitorCore

struct ConnectionTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_060)

    @Test func connectingThenLive() throws {
        let s = try Fixture.snapshot()
        let live = Connection.connecting.received(s, at: t0)
        #expect(live == .live(s, at: t0))
        #expect(live.snapshot == s)
        #expect(!live.isDown)
    }

    @Test func aFailureBeforeAnySnapshotIsUnreachable() {
        let down = Connection.connecting.failed(.ssh(.noRoute))
        #expect(down == .unreachable(error: .ssh(.noRoute)))
        #expect(down.snapshot == nil)
        #expect(down.failed(.notInstalled) == .unreachable(error: .notInstalled))
    }

    @Test func aFailureAfterASnapshotKeepsItAsStale() throws {
        let s = try Fixture.snapshot()
        let stale = Connection.live(s, at: t0).failed(.timedOut(seconds: 30))
        #expect(stale == .stale(s, at: t0, error: .timedOut(seconds: 30)))
        // Still the time the snapshot arrived, with the newest error.
        #expect(stale.failed(.ssh(.noRoute)) == .stale(s, at: t0, error: .ssh(.noRoute)))
        #expect(stale.isDown)
    }

    @Test func aSuccessRecoversFromAnyState() throws {
        let s = try Fixture.snapshot()
        #expect(Connection.unreachable(error: .notJSON).received(s, at: t1) == .live(s, at: t1))
        #expect(Connection.stale(s, at: t0, error: .notJSON).received(s, at: t1) == .live(s, at: t1))
        #expect(Connection.noServer.snapshot == nil)
        #expect(!Connection.noServer.isDown)
    }
}

struct ActionTargetTests {
    @Test func anIdPointsAtItsRow() throws {
        let s = try Fixture.snapshot()
        #expect(ActionTarget(id: "worker:52310:326136400", in: s) == .worker(s.workers[0]))
        #expect(ActionTarget(id: "tmp-stale", in: s) == .disk(s.scan.actions[0]))
        let chrome = try #require(s.memory.groups.first { $0.name == "chrome" })
        #expect(ActionTarget(id: "proc:58840:326860000", in: s) == .process(chrome.processes[0], group: chrome))
        #expect(ActionTarget(id: "proc:1:1", in: s) == nil)
    }
}

struct BulkCloseTests {
    @Test func selectsIdleClosableSessionsSilentForADay() throws {
        let s = try Fixture.snapshot()
        // Busy, and idle under 24 h (docs-site, 42 min) stay; server order is kept.
        #expect(BulkClose.selection(in: s).map(\.name) == ["billing-tests", "infra-notes"])
    }

    @Test func neverSelectsASessionTheServerWontClose() throws {
        var s = try Fixture.snapshot()
        s.workers[1].closable = false
        #expect(BulkClose.selection(in: s).map(\.name) == ["infra-notes"])
    }
}

struct ScanPolicyTests {
    @Test func asksForAScanWhenTheLastIsOlderThanSixHours() throws {
        let s = try Fixture.snapshot()
        #expect(!ScanPolicy.isStale(s.scan, at: s.at))  // 2 h old
        #expect(ScanPolicy.isStale(s.scan, at: s.at + 5 * 3_600))
        var never = s.scan
        never.at = nil
        #expect(ScanPolicy.isStale(never, at: s.at))
        never.running = true
        #expect(!ScanPolicy.isStale(never, at: s.at))
    }
}

struct NotificationGateTests {
    let disk = Alert(id: "disk", level: .critical, short: "Disk 99%", sentence: "Disk 99% full.")
    let swap = Alert(id: "swap", level: .warning, short: "Swap 100%", sentence: "Swap 100% full.")

    @Test func eachCriticalAlertOnceUntilItClears() {
        var gate = NotificationGate()
        #expect(gate.pollSucceeded(host: "web-1", alerts: [disk, swap], en).map(\.id) == ["alert-disk"])
        #expect(gate.pollSucceeded(host: "web-1", alerts: [disk, swap], en).isEmpty)
        #expect(gate.pollSucceeded(host: "web-1", alerts: [swap], en).isEmpty)
        #expect(gate.pollSucceeded(host: "web-1", alerts: [disk], en).map(\.title) == ["web-1: Disk 99%"])
    }

    @Test func unreachableAfterThreeFailuresInARowOnce() {
        var gate = NotificationGate()
        #expect(gate.pollFailed(host: "web-1", error: "x", en).isEmpty)
        #expect(gate.pollFailed(host: "web-1", error: "x", en).isEmpty)
        #expect(gate.pollFailed(host: "web-1", error: "no route", en) == [
            NotificationEvent(id: "unreachable", title: "Can't reach web-1", body: "no route"),
        ])
        #expect(gate.pollFailed(host: "web-1", error: "x", en).isEmpty)
        _ = gate.pollSucceeded(host: "web-1", alerts: [], en)
        #expect(gate.pollFailed(host: "web-1", error: "x", es).isEmpty)
        #expect(gate.pollFailed(host: "web-1", error: "x", es).isEmpty)
        #expect(gate.pollFailed(host: "web-1", error: "x", es).map(\.title) == ["No llego a web-1"])
    }

    @Test func aSuccessInBetweenResetsTheCount() {
        var gate = NotificationGate()
        _ = gate.pollFailed(host: "h", error: "x", en)
        _ = gate.pollFailed(host: "h", error: "x", en)
        _ = gate.pollSucceeded(host: "h", alerts: [], en)
        #expect(gate.pollFailed(host: "h", error: "x", en).isEmpty)
    }
}

struct SettingsTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "vpsmonitor-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func aFreshInstallHasNoServer() throws {
        try withDefaults { defaults in
            let settings = Settings.load(from: defaults)
            #expect(settings == Settings())
            #expect(settings.server == nil)
            #expect(settings.language == .system)
        }
    }

    @Test func roundTripsEverySettingAndDefaultsWhatIsMissing() throws {
        try withDefaults { defaults in
            var settings = Settings()
            settings.server = ServerAddress(host: "web-1.example.com", user: "deploy", port: 2222,
                                            identityFile: "/Users/me/.ssh/id_ed25519")
            settings.language = .spanish
            settings.interval = .fifteenMinutes
            settings.notifications = false
            settings.iconOnly = true
            settings.save(to: defaults)
            #expect(Settings.load(from: defaults) == settings)
            settings.server = ServerAddress(host: "web-2")
            settings.save(to: defaults)
            #expect(Settings.load(from: defaults).server == ServerAddress(host: "web-2"))
            defaults.set(42, forKey: "intervalSeconds")
            defaults.set("klingon", forKey: "language")
            #expect(Settings.load(from: defaults).interval == .oneMinute)
            #expect(Settings.load(from: defaults).language == .system)
        }
    }

    /// Before 0.2 the server was one `user@host` string under "host": an existing install keeps its server.
    @Test(arguments: [
        ("deploy@web-1", ServerAddress(host: "web-1", user: "deploy")),
        ("web-1.example.com", ServerAddress(host: "web-1.example.com")),
        ("  ops@192.0.2.10 ", ServerAddress(host: "192.0.2.10", user: "ops")),
    ])
    func migratesTheOldHostSetting(_ legacy: String, _ expected: ServerAddress) throws {
        try withDefaults { defaults in
            defaults.set(legacy, forKey: "host")
            var settings = Settings.load(from: defaults)
            #expect(settings.server == expected)
            settings.iconOnly = true
            settings.save(to: defaults)
            #expect(defaults.string(forKey: "host") == nil)
            #expect(Settings.load(from: defaults).server == expected)
        }
    }

    @Test(arguments: ["-oProxyCommand=evil", "deploy@-x", "a b", "@web-1", ""])
    func anOldHostSshCouldMisreadIsDropped(_ legacy: String) throws {
        try withDefaults { defaults in
            defaults.set(legacy, forKey: "host")
            #expect(Settings.load(from: defaults).server == nil)
        }
    }

    @Test(arguments: [
        ([String](), Language.en), (["en-GB"], .en), (["es-ES", "en"], .es), (["es-419"], .es),
        (["fr-FR", "es-ES"], .en), (["ES"], .es),
    ])
    func systemFollowsTheMacsFirstLanguage(_ preferred: [String], _ expected: Language) {
        #expect(AppLanguage.system.resolved(preferred: preferred) == expected)
        #expect(AppLanguage.english.resolved(preferred: ["es-ES"]) == .en)
        #expect(AppLanguage.spanish.resolved(preferred: ["en-US"]) == .es)
    }
}

struct ServerAddressTests {
    let exists: (String) -> Bool = { $0 == "/Users/me/.ssh/id_ed25519" }

    @Test func aFullAddressValidates() throws {
        let address = ServerAddress(host: "web-1.example.com", user: "deploy", port: 2222,
                                    identityFile: "/Users/me/.ssh/id_ed25519")
        #expect(try address.validated(fileExists: exists) == address)
        #expect(try ServerAddress(host: "192.0.2.10").validated(fileExists: exists).host == "192.0.2.10")
    }

    @Test(arguments: [
        (ServerAddress(host: "-oProxyCommand=evil"), ServerAddress.Problem.host("-oProxyCommand=evil")),
        (ServerAddress(host: "web 1"), .host("web 1")),
        (ServerAddress(host: "deploy@web-1"), .host("deploy@web-1")),
        (ServerAddress(host: ""), .host("")),
        (ServerAddress(host: "web-1", user: "Deploy"), .user("Deploy")),
        (ServerAddress(host: "web-1", user: "-l"), .user("-l")),
        (ServerAddress(host: "web-1", user: "a;b"), .user("a;b")),
        (ServerAddress(host: "web-1", port: 0), .port(0)),
        (ServerAddress(host: "web-1", port: 65_536), .port(65_536)),
        (ServerAddress(host: "web-1", identityFile: "id_ed25519"), .identityFile("id_ed25519")),
        (ServerAddress(host: "web-1", identityFile: "/nope/key"), .identityFile("/nope/key")),
    ])
    func refusesWhatSshCouldMisread(_ address: ServerAddress, _ problem: ServerAddress.Problem) {
        #expect(throws: VPSError.invalidServer(problem)) { try address.validated(fileExists: exists) }
    }

    @Test func theFormTrimsTreatsEmptyAsUnsetAndExpandsTilde() throws {
        let form = ServerForm(host: " web-1 ", user: "", port: " 2222", identityFile: "")
        #expect(try form.address(fileExists: exists) == ServerAddress(host: "web-1", port: 2222))
        let key = ServerForm(host: "web-1", identityFile: "~/.ssh/id_ed25519")
        #expect(try key.address(fileExists: { _ in true }).identityFile == NSHomeDirectory() + "/.ssh/id_ed25519")
        #expect(throws: VPSError.invalidServer(.port(0))) {
            try ServerForm(host: "web-1", port: "ssh").address(fileExists: exists)
        }
        #expect(ServerForm(ServerAddress(host: "web-1", user: "deploy", port: 22)).port == "22")
    }

    @Test func problemsReadInBothLanguages() {
        #expect(VPSError.invalidServer(.host("")).message(en) == "Type the server's host name.")
        #expect(VPSError.invalidServer(.port(0)).message(es) == "El puerto 0 está fuera de rango (1–65535).")
    }
}

struct SSHConfigTests {
    @Test func listsNamedHostsWithWhatTheySet() {
        let config = """
        # personal
        Host *
            ServerAliveInterval 30
        Host web-1 web-1-alt
            HostName 192.0.2.20
            User deploy
            Port 2222
            IdentityFile ~/.ssh/web_ed25519
        Host=db-*
            User postgres
        host  staging
          user=ops
          IdentityFile "/keys/staging key"
        Match host prod
            User root
        Host !nope backup
          HostName backup.example.com
          ProxyCommand ssh -W %h:%p bastion
          IdentityFile ~/.ssh/id_%h
        """
        let hosts = SSHConfigHost.parse(config)
        #expect(hosts.map(\.alias) == ["web-1", "web-1-alt", "staging", "backup"])
        #expect(hosts[0] == SSHConfigHost(alias: "web-1", hostName: "192.0.2.20", user: "deploy", port: 2222,
                                          identityFile: NSHomeDirectory() + "/.ssh/web_ed25519"))
        #expect(hosts[1].user == "deploy")
        #expect(hosts[2].user == "ops")
        #expect(hosts[2].identityFile == "/keys/staging key")
        #expect(hosts[3].hostName == "backup.example.com")
        #expect(hosts[3].identityFile == nil)
        #expect(hosts[0].address == ServerAddress(host: "web-1", user: "deploy", port: 2222,
                                                  identityFile: NSHomeDirectory() + "/.ssh/web_ed25519"))
    }

    @Test func aMissingFileIsNoHosts() {
        #expect(SSHConfigHost.load(from: URL(fileURLWithPath: "/nonexistent/config")).isEmpty)
    }
}
