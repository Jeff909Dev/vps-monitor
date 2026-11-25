import Foundation

/// The language the user picked in Settings.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system, english, spanish

    /// "System" follows the Mac: Spanish when its first preferred language is Spanish, English otherwise.
    public func resolved(preferred: [String]) -> Language {
        switch self {
        case .english: return .en
        case .spanish: return .es
        case .system: return (preferred.first?.lowercased().hasPrefix("es") ?? false) ? .es : .en
        }
    }
}

/// A language the app speaks; its raw value is what `vpsmon --lang` takes.
public enum Language: String, CaseIterable, Sendable {
    case en, es
}

/// A text with values in it: `badHost("web 1")`. A struct rather than a bare closure so that a test can find and
/// call every one of them through Mirror, which can't call a closure field it reflects.
public struct Phrase<each Argument>: Sendable {
    let make: @Sendable (repeat each Argument) -> String

    public init(_ make: @escaping @Sendable (repeat each Argument) -> String) { self.make = make }

    public func callAsFunction(_ argument: repeat each Argument) -> String { make(repeat each argument) }
}

/// Every word the app shows, in one language. Each field must be given in both `en` and `es`, so a missing
/// translation doesn't compile. Text with values in it is a closure.
public struct Strings: Sendable {
    public let language: Language
    public let format: Format
    public let common: Common
    public let errors: Errors
    public let health: HealthText
    public let notifications: Notifications
    public let menuBar: MenuBarText
    public let metrics: Metrics
    public let ram: RAM
    public let sessions: Sessions
    public let disk: DiskText
    public let toasts: Toasts
    public let popover: PopoverText
    public let welcome: Welcome
    public let setup: SetupText
    public let settings: SettingsText
    public let app: AppText
    public let cli: CLIText

    public static func `for`(_ language: Language) -> Strings {
        switch language {
        case .en: return .en
        case .es: return .es
        }
    }

    public struct Common: Sendable {
        public let cancel: String
        public let ok: String
        public let copy: String
        /// "and 3 more"
        public let more: Phrase<Int>
    }

    public struct Errors: Sendable {
        public let emptyHost: String
        public let badHost: Phrase<String>
        public let badUser: Phrase<String>
        public let badPort: Phrase<Int>
        public let badKey: Phrase<String>
        public let badActionID: Phrase<String>
        public let timedOut: Phrase<String>
        public let sshUnresolved: String
        public let sshTimedOut: String
        public let sshNoRoute: String
        public let sshRefused: String
        public let sshKeyRefused: String
        public let sshHostKey: String
        public let sshSilent: String
        public let ssh: Phrase<String>
        public let serverSilent: String
        public let notInstalled: String
        public let sudoPassword: String
        public let schema: Phrase<Int, Int>
        public let notJSON: String
        public let missing: Phrase<String>
        public let wrongType: Phrase<String>
        public let corrupt: Phrase<String>
        public let failed: Phrase<Int32>
        public let failedWith: Phrase<Int32, String>
        public let noInstaller: String
        public let sudoMissing: String
        public let python3: String
        public let installerBadUser: String
        public let badUnit: String
        public let installerUsage: String
        public let noSuchUser: String
        public let visudoMissing: String
        public let sudoersInvalid: String
        public let installerOther: Phrase<String>
    }

    public struct HealthText: Sendable {
        public let serviceShort: Phrase<String>
        public let serviceSentence: Phrase<String>
        public let diskShort: Phrase<String>
        /// percent, free, total
        public let diskSentence: Phrase<String, String, String>
        public let fillShort: Phrase<String>
        /// growth per hour (nil without a trend), forecast
        public let fillSentence: Phrase<String?, String>
        public let ramShort: Phrase<String>
        public let ramSentence: Phrase<String, String>
        public let swapShort: Phrase<String>
        /// percent, used, total
        public let swapSentence: Phrase<String, String, String>
        public let oomShort: Phrase<String>
        /// process, pid, ago
        public let oomSentence: Phrase<String, Int, String>
    }

    public struct Notifications: Sendable {
        public let alertTitle: Phrase<String, String>
        public let unreachableTitle: Phrase<String>
    }

    public struct MenuBarText: Sendable {
        public let noServer: String
        public let connecting: Phrase<String>
        /// host, error
        public let unreachable: Phrase<String, String>
        /// host, error, ago
        public let stale: Phrase<String, String, String>
        /// host, disk percent, free
        public let summary: Phrase<String, String, String>
        /// busy, total
        public let sessions: Phrase<Int, Int>
    }

    public struct Metrics: Sendable {
        public let disk: String
        public let memory: String
        public let cpu: String
        public let noTrend: String
        public let fullIn: Phrase<String>
        public let freeOf: Phrase<String, String>
        public let availableOf: Phrase<String, String>
        /// used, total, percent
        public let swap: Phrase<String, String, String>
        public let load: Phrase<String, Int>
        public let loadDetail: Phrase<String, String>
        public let uptime: Phrase<String>
        public let showRAM: String
    }

    public struct RAM: Sendable {
        public let title: Phrase<String>
        public let inProcesses: Phrase<String>
        public let other: String
        public let available: String
        public let barLabel: String
        public let end: String
        /// program, pid, children it also ends, what it frees
        public let endQuestion: Phrase<String, Int, Int, String>
        public let endConfirm: Phrase<String>
        public let endFrees: Phrase<String>
        public let sessionsClose: String
    }

    public struct Sessions: Sendable {
        public let title: String
        public let working: Phrase<Int>
        public let idle: Phrase<Int>
        public let unknown: Phrase<Int>
        public let stateWorking: String
        public let stateIdle: Phrase<String>
        public let stateUnknown: String
        public let closable: String
        /// count, frees
        public let bulkLabel: Phrase<Int, String>
        public let bulkQuestion: Phrase<Int>
        public let bulkNote: String
        public let bulkConfirm: Phrase<Int, String>
        public let bulkRunning: Phrase<Int, Int>
        public let close: String
        /// name, state, frees
        public let closeQuestion: Phrase<String, String, String>
        public let closeNote: String
        public let closeConfirm: String
        public let copyResume: String
    }

    public struct DiskText: Sendable {
        public let freeSection: String
        public let recoverable: Phrase<String>
        public let scanning: String
        public let neverScanned: String
        public let scanned: Phrase<String>
        public let scanningLong: String
        public let noScanYet: String
        public let nothingToFree: String
        public let startingScan: String
        public let scanAgain: String
        public let review: String
        public let freeButton: String
        public let sure: String
        public let sureReview: String
        public let freeConfirm: Phrase<String>
        /// freed, server message
        public let freed: Phrase<String, String>
        public let mapTitle: Phrase<String>
        public let used: Phrase<String>
        public let freeable: Phrase<String>
        public let barLabel: String
        public let freeSpace: String
    }

    public struct Toasts: Sendable {
        /// name, frees
        public let closed: Phrase<String, String>
        /// program, pid, freed
        public let ended: Phrase<String, Int, String>
        /// freed, server message
        public let freed: Phrase<String, String>
        /// closed, of, name, error
        public let bulkPartly: Phrase<Int, Int, String, String>
        public let bulkClosed: Phrase<Int>
        /// closed, of, freed
        public let bulkCopied: Phrase<Int, Int, String>
        public let scanFailed: Phrase<String>
        public let resumeCopied: Phrase<String>
        public let copied: String
    }

    public struct PopoverText: Sendable {
        public let noServerSubline: String
        public let connectingSubline: String
        public let offlineSubline: String
        public let updated: Phrase<String>
        public let staleSubline: Phrase<String>
        public let refresh: String
        public let settings: String
        public let quit: String
        public let connecting: Phrase<String>
        public let cantReach: Phrase<String>
        public let retry: String
        public let offline: String
        public let every: Phrase<String>
    }

    public struct Welcome: Sendable {
        public let title: String
        public let body: String
        public let needsTitle: String
        public let needs: [String]
        public let connect: String
        public let note: String
    }

    public struct SetupText: Sendable {
        public let testing: Phrase<String>
        /// host, vpsmon version, disk percent, Claude Code sessions
        public let connected: Phrase<String, String, String, Int>
        public let missing: Phrase<String>
        /// host, server version, app version
        public let outdated: Phrase<String, String, String>
        /// host, server schema, app schema
        public let schema: Phrase<String, Int, Int>
        public let noSudoRule: Phrase<String>
        public let install: String
        public let update: String
        public let installing: Phrase<String>
        public let needsPassword: Phrase<String>
        public let checkAgain: String
        public let tryAgain: String
        public let noTimer: String
    }

    public struct SettingsText: Sendable {
        public let windowTitle: String
        public let server: String
        public let host: String
        public let hostPlaceholder: String
        public let user: String
        public let userPlaceholder: String
        public let port: String
        public let portPlaceholder: String
        public let key: String
        public let keyPlaceholder: String
        public let choose: String
        public let chooseKeyTitle: String
        public let fromConfig: String
        public let noConfigHosts: String
        public let connect: String
        public let requirements: String
        public let general: String
        public let language: String
        public let languageSystem: String
        public let interval: String
        public let notifications: String
        public let launchAtLogin: String
        public let iconOnly: String
        public let version: Phrase<String>
        public let loginApprove: String
        public let loginNeedsApplications: String
        public let loginRemoveFailed: Phrase<String>
    }

    public struct AppText: Sendable {
        public let hiddenTitle: String
        public let hiddenBody: String
        public let quit: String
        public let showAgain: String
        public let openSystemSettings: String
    }

    public struct CLIText: Sendable {
        public let usage: String
        public let renderFailed: String
        public let sampleRefusal: String
        public let noInstaller: String
        public let needsServer: String
        public let dryRun: String
    }
}

extension VPSError {
    /// What the user reads.
    public func message(_ s: Strings) -> String {
        let e = s.errors
        switch self {
        case .invalidServer(.host(let host)): return host.isEmpty ? e.emptyHost : e.badHost(host)
        case .invalidServer(.user(let user)): return e.badUser(user)
        case .invalidServer(.port(let port)): return e.badPort(port)
        case .invalidServer(.identityFile(let key)): return e.badKey(key)
        case .invalidActionID(let id): return e.badActionID(id)
        case .timedOut(let seconds): return e.timedOut(s.format.duration(Double(seconds)))
        case .ssh(.unresolved): return e.sshUnresolved
        case .ssh(.timedOut): return e.sshTimedOut
        case .ssh(.noRoute): return e.sshNoRoute
        case .ssh(.refused): return e.sshRefused
        case .ssh(.keyRefused): return e.sshKeyRefused
        case .ssh(.hostKeyChanged): return e.sshHostKey
        case .ssh(.silent): return e.sshSilent
        case .ssh(.other(let text)): return e.ssh(text)
        case .server(let text), .other(let text): return text
        case .serverSilent: return e.serverSilent
        case .notInstalled: return e.notInstalled
        case .sudoPassword: return e.sudoPassword
        case .schema(let schema): return e.schema(schema, SnapshotDecoding.schema)
        case .notJSON: return e.notJSON
        case .contract(.missing(let path)): return e.missing(path)
        case .contract(.type(let path)): return e.wrongType(path)
        case .contract(.corrupt(let path)): return e.corrupt(path)
        case .failed(let status, let detail): return detail.isEmpty ? e.failed(status) : e.failedWith(status, detail)
        case .noInstaller: return e.noInstaller
        case .installer(.sudoMissing): return e.sudoMissing
        case .installer(.python3): return e.python3
        case .installer(.badUser): return e.installerBadUser
        case .installer(.badUnit): return e.badUnit
        case .installer(.usage): return e.installerUsage
        case .installer(.noSuchUser): return e.noSuchUser
        case .installer(.visudoMissing): return e.visudoMissing
        case .installer(.sudoersInvalid): return e.sudoersInvalid
        case .installer(.other(let code)): return e.installerOther(code)
        }
    }
}

// MARK: - English

extension Strings {
    public static let en = Strings(
        language: .en,
        format: Format(decimalMark: ".", justNow: "now", ago: Phrase { "\($0) ago" }),
        common: Common(cancel: "Cancel", ok: "OK", copy: "Copy", more: Phrase { "and \($0) more" }),
        errors: Errors(
            emptyHost: "Type the server's host name.",
            badHost: Phrase { "“\($0)” isn't a host name ssh can use." },
            badUser: Phrase { "“\($0)” isn't a valid user name." },
            badPort: Phrase { "Port \($0) is out of range (1–65535)." },
            badKey: Phrase { "There is no SSH key at \($0)." },
            badActionID: Phrase { "“\($0)” isn't an action the server published." },
            timedOut: Phrase { "The server didn't answer within \($0)." },
            sshUnresolved: "Can't find that server: check the host name, your network or your VPN.",
            sshTimedOut: "The server doesn't answer: check your network or your VPN.",
            sshNoRoute: "No route to the server: check your network or your VPN.",
            sshRefused: "The server refuses SSH connections on that port.",
            sshKeyRefused: "The server doesn't accept your SSH key: check the user and the key.",
            sshHostKey: "The server's host key doesn't match the one in known_hosts.",
            sshSilent: "SSH failed without saying why.",
            ssh: Phrase { "SSH: \($0)" },
            serverSilent: "vpsmon failed without saying why.",
            notInstalled: "vpsmon isn't installed on the server.",
            sudoPassword: "vpsmon can't become root without a password: install it again to add its sudo rule.",
            schema: Phrase { "The server's vpsmon speaks schema \($0) and this app schema \($1): update the server." },
            notJSON: "vpsmon didn't answer with JSON.",
            missing: Phrase { "vpsmon's answer doesn't match the contract: \($0) is missing." },
            wrongType: Phrase { "vpsmon's answer doesn't match the contract: \($0) has an unexpected type." },
            corrupt: Phrase { "vpsmon's answer doesn't match the contract: \($0) is corrupt." },
            failed: Phrase { "vpsmon failed (exit \($0))." },
            failedWith: Phrase { "vpsmon failed (exit \($0)): \($1)" },
            noInstaller: "This build of the app carries no installer.",
            sudoMissing: "The server has no sudo, and the SSH user isn't root: install sudo there, or connect as root.",
            python3: "vpsmon needs Python 3.10 or newer on the server.",
            installerBadUser: "The installer can't write a sudo rule for this user name.",
            badUnit: "The installer was given a service name it can't watch.",
            installerUsage: "The installer didn't understand how it was called.",
            noSuchUser: "The user for the sudo rule doesn't exist on the server.",
            visudoMissing: "The server has no visudo, so the installer can't check its sudo rule. Nothing changed.",
            sudoersInvalid: "visudo rejected the sudo rule, so the installer changed nothing.",
            installerOther: Phrase { "The installer stopped: \($0)." }),
        health: HealthText(
            serviceShort: Phrase { "\($0) down" },
            serviceSentence: Phrase { "The \($0) service isn't running." },
            diskShort: Phrase { "Disk \($0)" },
            diskSentence: Phrase { "Disk \($0) full: \($1) free of \($2)." },
            fillShort: Phrase { "Full in \($0)" },
            fillSentence: Phrase { growth, forecast in
                "At the last 24 h's rate\(growth.map { " (+\($0)/h)" } ?? ""), the disk fills up in \(forecast)."
            },
            ramShort: Phrase { "RAM \($0)" },
            ramSentence: Phrase { "Only \($0) of RAM available out of \($1)." },
            swapShort: Phrase { "Swap \($0)" },
            swapSentence: Phrase { "Swap \($0) full (\($1) of \($2)): RAM is short and everything slows down." },
            oomShort: Phrase { "OOM: \($0)" },
            oomSentence: Phrase { "The out-of-memory killer ended \($0) (pid \($1)) \($2)." }),
        notifications: Notifications(
            alertTitle: Phrase { "\($0): \($1)" },
            unreachableTitle: Phrase { "Can't reach \($0)" }),
        menuBar: MenuBarText(
            noServer: "VPS Monitor: no server connected yet",
            connecting: Phrase { "Connecting to \($0)…" },
            unreachable: Phrase { "Can't reach \($0): \($1)" },
            stale: Phrase { "No connection to \($0) (\($1)). Last data from \($2):" },
            summary: Phrase { "\($0) · disk \($1) full (\($2) free)" },
            sessions: Phrase { "\($0) of \($1) Claude Code sessions working" }),
        metrics: Metrics(
            disk: "disk", memory: "memory", cpu: "cpu",
            noTrend: "no trend yet",
            fullIn: Phrase { "full in \($0)" },
            freeOf: Phrase { "\($0) free of \($1)" },
            availableOf: Phrase { "\($0) available of \($1)" },
            swap: Phrase { "swap \($0) of \($1) (\($2))" },
            load: Phrase { "load \($0) on \($1) cores" },
            loadDetail: Phrase { "5 min \($0) · 15 min \($1)" },
            uptime: Phrase { "up \($0)" },
            showRAM: "Where the RAM goes"),
        ram: RAM(
            title: Phrase { "where the \($0) of RAM go" },
            inProcesses: Phrase { "\($0) in processes" },
            other: "Other: smaller programs, the kernel and its caches",
            available: "Available",
            barLabel: "RAM by program",
            end: "End",
            endQuestion: Phrase { name, pid, children, frees in
                let others = switch children {
                case 0: ""
                case 1: " It also ends 1 child process."
                default: " It also ends \(children) child processes."
                }
                return "End \(name) (pid \(pid))?\(others) Frees \(frees)."
            },
            endConfirm: Phrase { "End · frees \($0)" },
            endFrees: Phrase { "end frees \($0)" },
            sessionsClose: "Claude Code sessions close from their own list, which keeps their resume command."),
        sessions: Sessions(
            title: "claude code sessions",
            working: Phrase { "\($0) working" },
            idle: Phrase { "\($0) idle" },
            unknown: Phrase { "\($0) unknown" },
            stateWorking: "working",
            stateIdle: Phrase { "idle \($0)" },
            stateUnknown: "unknown",
            closable: "closable",
            bulkLabel: Phrase { "Close idle over 24 h (\($0)) · frees \($1)" },
            bulkQuestion: Phrase { "Close \($0) sessions idle for more than 24 h?" },
            bulkNote: "I'll copy the commands to resume them.",
            bulkConfirm: Phrase { "Close \($0) · frees \($1)" },
            bulkRunning: Phrase { "Closing \($0) of \($1)…" },
            close: "Close",
            closeQuestion: Phrase { "Close \($0)? It has been \($1) and frees \($2)." },
            closeNote: "I'll copy the command to resume it.",
            closeConfirm: "Close session",
            copyResume: "Copy resume command"),
        disk: DiskText(
            freeSection: "free up space",
            recoverable: Phrase { "\($0) recoverable" },
            scanning: "Scanning…",
            neverScanned: "Not scanned yet",
            scanned: Phrase { "Scanned \($0)" },
            scanningLong: "Scanning the disk: it takes a few minutes.",
            noScanYet: "No disk scan yet.",
            nothingToFree: "Nothing to free right now.",
            startingScan: "Starting the scan…",
            scanAgain: "Scan again",
            review: "review",
            freeButton: "Free",
            sure: "Sure? This can't be undone.",
            sureReview: "Sure? Check the list: this can't be undone.",
            freeConfirm: Phrase { "Free \($0)" },
            freed: Phrase { "Freed \($0) · \($1)" },
            mapTitle: Phrase { "where the \($0) go" },
            used: Phrase { "\($0) used" },
            freeable: Phrase { "\($0) can be freed" },
            barLabel: "Disk by group",
            freeSpace: "Free"),
        toasts: Toasts(
            closed: Phrase { "Closed \($0) · \($1) · resume command copied" },
            ended: Phrase { "Ended \($0) (pid \($1)) · freed \($2)" },
            freed: Phrase { "Freed \($0) · \($1)" },
            bulkPartly: Phrase { "Closed \($0) of \($1). \($2): \($3)" },
            bulkClosed: Phrase { "Closed \($0)" },
            bulkCopied: Phrase { "Closed \($0) of \($1) · \($2) · resume commands copied" },
            scanFailed: Phrase { "Couldn't start the scan: \($0)" },
            resumeCopied: Phrase { "Resume command for \($0) copied" },
            copied: "Copied"),
        popover: PopoverText(
            noServerSubline: "no server yet",
            connectingSubline: "connecting…",
            offlineSubline: "offline",
            updated: Phrase { "updated \($0)" },
            staleSubline: Phrase { "offline · data from \($0)" },
            refresh: "Refresh now",
            settings: "Settings",
            quit: "Quit",
            connecting: Phrase { "Connecting to \($0)…" },
            cantReach: Phrase { "Can't reach \($0)" },
            retry: "Retry",
            offline: "Offline",
            every: Phrase { "every \($0)" }),
        welcome: Welcome(
            title: "Watch a Linux server from the menu bar",
            body: "Disk, RAM, CPU and Claude Code sessions at a glance, with a confirmed click to free space and "
                + "memory.",
            needsTitle: "It needs",
            needs: ["A Linux server with systemd", "SSH access with your key", "root, or a user with sudo"],
            connect: "Connect a server…",
            note: "The app installs one script on the server, vpsmon, and talks to it over SSH."),
        setup: SetupText(
            testing: Phrase { "Connecting to \($0)…" },
            connected: Phrase { host, version, disk, sessions in
                "Connected to \(host) · vpsmon \(version) · disk \(disk) full"
                    + (sessions > 0 ? " · \(sessions) Claude Code session\(sessions == 1 ? "" : "s")" : "")
            },
            missing: Phrase { "vpsmon isn't installed on \($0)." },
            outdated: Phrase { "\($0) runs vpsmon \($1); this app brings \($2)." },
            schema: Phrase { "\($0) runs a vpsmon that speaks schema \($1); this app needs schema \($2)." },
            noSudoRule: Phrase { "vpsmon on \($0) can't become root without a password." },
            install: "Install on server",
            update: "Update server",
            installing: Phrase { "Installing vpsmon on \($0)…" },
            needsPassword: Phrase { "sudo on \($0) asks for a password, so the app can't install by itself. Run this in "
                + "Terminal, then check again:" },
            checkAgain: "Check again",
            tryAgain: "Try again",
            noTimer: "This server has no systemd, so vpsmon records no history: the 24 h charts stay empty."),
        settings: SettingsText(
            windowTitle: "VPS Monitor Settings",
            server: "server",
            host: "Host",
            hostPlaceholder: "web-1.example.com",
            user: "User",
            userPlaceholder: "from ssh",
            port: "Port",
            portPlaceholder: "22",
            key: "SSH key",
            keyPlaceholder: "ssh's default keys",
            choose: "Choose…",
            chooseKeyTitle: "Choose your SSH private key",
            fromConfig: "From ~/.ssh/config",
            noConfigHosts: "No hosts in ~/.ssh/config",
            connect: "Connect",
            requirements: "Needs a Linux server with systemd, SSH access with a key, and root or sudo. Connecting "
                + "saves the server.",
            general: "general",
            language: "Language",
            languageSystem: "System",
            interval: "Refresh every",
            notifications: "Notify critical alerts",
            launchAtLogin: "Open at login",
            iconOnly: "Icon only in the menu bar",
            version: Phrase { "VPS Monitor \($0)" },
            loginApprove: "Allow it in System Settings › General › Login Items.",
            loginNeedsApplications: "To open at login the app has to be in /Applications.",
            loginRemoveFailed: Phrase { "Couldn't remove it from login items: \($0)" }),
        app: AppText(
            hiddenTitle: "VPS Monitor isn't showing in the menu bar",
            hiddenBody: "macOS isn't showing the VPS Monitor icon. Usually the menu bar is full: on a Mac with a "
                + "notch, what doesn't fit beside the open app's menus is hidden. Remove an icon or ⌘-drag VPS "
                + "Monitor next to the clock. Otherwise it's turned off in System Settings › Menu Bar. Then click "
                + "Show again.",
            quit: "Quit",
            showAgain: "Show again",
            openSystemSettings: "Open Settings"),
        cli: CLIText(
            usage: """
            usage: vpsmon-mac <command> [server] [--lang en|es]
              server: --host <host> [--user <user>] [--port <port>] [--identity <key>]
              status [--fixture <status.json>]
                  what the popover shows, as text, from the server or a saved status
              install [--installer <vpsmon-install.sh>]
                  connects as Settings does, installs or updates vpsmon when needed, and prints each step
              act <id> [--dry-run]
                  applies one action the server published (frees disk, closes a session, ends a process)
              render <out.png> [--fixture <status.json>] [--dark] [--open <map group>]... [--open-ram <program>]
                     [--confirm <id>|bulk-close] [--fail <id>] [--stale | --unreachable] [--welcome]
                     [--outdated] [--settings idle|testing|connected|missing|outdated|schema|installing|password|failed]
                  the popover, or the Settings window, drawn into a PNG. --open shows a disk-map group with its
                  folders and Free buttons; --open-ram opens the RAM breakdown and one program's processes;
                  --confirm opens a row's inline confirmation (in the map when its group is open)
            render reads the server once unless given --fixture; it never acts on it.
            """,
            renderFailed: "Couldn't draw the PNG.",
            sampleRefusal: "Another action is still running on the server.",
            noInstaller: "No installer: pass --installer <vpsmon-install.sh>.",
            needsServer: "Pass --host, or --fixture to read a saved status.",
            dryRun: "dry run, nothing changed"))
}

// MARK: - Spanish

extension Strings {
    public static let es = Strings(
        language: .es,
        format: Format(decimalMark: ",", justNow: "ahora", ago: Phrase { "hace \($0)" }),
        common: Common(cancel: "Cancelar", ok: "OK", copy: "Copiar", more: Phrase { "y \($0) más" }),
        errors: Errors(
            emptyHost: "Escribe el nombre del servidor.",
            badHost: Phrase { "«\($0)» no es un nombre de servidor que ssh pueda usar." },
            badUser: Phrase { "«\($0)» no es un nombre de usuario válido." },
            badPort: Phrase { "El puerto \($0) está fuera de rango (1–65535)." },
            badKey: Phrase { "No hay ninguna clave SSH en \($0)." },
            badActionID: Phrase { "«\($0)» no es una acción que haya publicado el servidor." },
            timedOut: Phrase { "El servidor no contestó en \($0)." },
            sshUnresolved: "No encuentro el servidor: revisa el nombre, tu red o tu VPN.",
            sshTimedOut: "El servidor no contesta: revisa tu red o tu VPN.",
            sshNoRoute: "No hay ruta al servidor: revisa tu red o tu VPN.",
            sshRefused: "El servidor rechaza las conexiones SSH en ese puerto.",
            sshKeyRefused: "El servidor no acepta tu clave SSH: revisa el usuario y la clave.",
            sshHostKey: "La clave del servidor no coincide con la de known_hosts.",
            sshSilent: "SSH falló sin decir por qué.",
            ssh: Phrase { "SSH: \($0)" },
            serverSilent: "vpsmon falló sin decir por qué.",
            notInstalled: "vpsmon no está instalado en el servidor.",
            sudoPassword: "vpsmon no puede hacerse root sin contraseña: vuelve a instalarlo para añadir su regla de "
                + "sudo.",
            schema: Phrase { "El vpsmon del servidor habla el esquema \($0) y la app el \($1): actualiza el servidor." },
            notJSON: "vpsmon no devolvió JSON.",
            missing: Phrase { "La respuesta de vpsmon no encaja con el contrato: falta \($0)." },
            wrongType: Phrase { "La respuesta de vpsmon no encaja con el contrato: tipo inesperado en \($0)." },
            corrupt: Phrase { "La respuesta de vpsmon no encaja con el contrato: dato corrupto en \($0)." },
            failed: Phrase { "vpsmon falló (código \($0))." },
            failedWith: Phrase { "vpsmon falló (código \($0)): \($1)" },
            noInstaller: "Esta compilación de la app no trae instalador.",
            sudoMissing: "El servidor no tiene sudo y el usuario SSH no es root: instala sudo allí o conecta como root.",
            python3: "vpsmon necesita Python 3.10 o posterior en el servidor.",
            installerBadUser: "El instalador no puede escribir una regla de sudo para este nombre de usuario.",
            badUnit: "El instalador recibió un nombre de servicio que no puede vigilar.",
            installerUsage: "El instalador no entendió cómo se le llamó.",
            noSuchUser: "El usuario de la regla de sudo no existe en el servidor.",
            visudoMissing: "El servidor no tiene visudo, así que el instalador no puede comprobar su regla de sudo. No "
                + "cambió nada.",
            sudoersInvalid: "visudo rechazó la regla de sudo, así que el instalador no cambió nada.",
            installerOther: Phrase { "El instalador se detuvo: \($0)." }),
        health: HealthText(
            serviceShort: Phrase { "\($0) caído" },
            serviceSentence: Phrase { "El servicio \($0) no está activo." },
            diskShort: Phrase { "Disco \($0)" },
            diskSentence: Phrase { "Disco al \($0): quedan \($1) libres de \($2)." },
            fillShort: Phrase { "Se llena en \($0)" },
            fillSentence: Phrase { growth, forecast in
                "Al ritmo de las últimas 24 h\(growth.map { " (+\($0)/h)" } ?? ""), el disco se llena en \(forecast)."
            },
            ramShort: Phrase { "RAM \($0)" },
            ramSentence: Phrase { "Solo quedan \($0) de RAM disponibles de \($1)." },
            swapShort: Phrase { "Swap \($0)" },
            swapSentence: Phrase { "Swap al \($0) (\($1) de \($2)): la RAM no da abasto y todo va más lento." },
            oomShort: Phrase { "OOM: \($0)" },
            oomSentence: Phrase { "El killer de memoria cerró \($0) (pid \($1)) \($2) por falta de memoria." }),
        notifications: Notifications(
            alertTitle: Phrase { "\($0): \($1)" },
            unreachableTitle: Phrase { "No llego a \($0)" }),
        menuBar: MenuBarText(
            noServer: "VPS Monitor: aún no hay servidor conectado",
            connecting: Phrase { "Conectando con \($0)…" },
            unreachable: Phrase { "No llego a \($0): \($1)" },
            stale: Phrase { "Sin conexión con \($0) (\($1)). Último dato \($2):" },
            summary: Phrase { "\($0) · disco al \($1) (\($2) libres)" },
            sessions: Phrase { "\($0) de \($1) sesiones de Claude Code trabajando" }),
        metrics: Metrics(
            disk: "disco", memory: "memoria", cpu: "cpu",
            noTrend: "sin tendencia aún",
            fullIn: Phrase { "se llena en \($0)" },
            freeOf: Phrase { "\($0) libres de \($1)" },
            availableOf: Phrase { "\($0) libres de \($1)" },
            swap: Phrase { "swap \($0) de \($1) (\($2))" },
            load: Phrase { "carga \($0) de \($1) núcleos" },
            loadDetail: Phrase { "5 min \($0) · 15 min \($1)" },
            uptime: Phrase { "encendido \($0)" },
            showRAM: "En qué se va la RAM"),
        ram: RAM(
            title: Phrase { "en qué se van los \($0) de RAM" },
            inProcesses: Phrase { "\($0) en procesos" },
            other: "Otros: programas pequeños, el kernel y sus cachés",
            available: "Disponible",
            barLabel: "RAM por programa",
            end: "Terminar",
            endQuestion: Phrase { name, pid, children, frees in
                let others = switch children {
                case 0: ""
                case 1: " También termina 1 proceso hijo."
                default: " También termina \(children) procesos hijos."
                }
                return "¿Terminar \(name) (pid \(pid))?\(others) Libera \(frees)."
            },
            endConfirm: Phrase { "Terminar · libera \($0)" },
            endFrees: Phrase { "terminar libera \($0)" },
            sessionsClose: "Las sesiones de Claude Code se cierran desde su lista, que guarda su comando para retomarlas."),
        sessions: Sessions(
            title: "sesiones de claude code",
            working: Phrase { "\($0) trabajando" },
            idle: Phrase { "\($0) \($0 == 1 ? "parada" : "paradas")" },
            unknown: Phrase { "\($0) sin estado" },
            stateWorking: "trabajando",
            stateIdle: Phrase { "parada \($0)" },
            stateUnknown: "sin estado",
            closable: "cerrable",
            bulkLabel: Phrase { "Cerrar paradas de más de 24 h (\($0)) · libera \($1)" },
            bulkQuestion: Phrase { "¿Cerrar \($0) sesiones paradas desde hace más de 24 h?" },
            bulkNote: "Copio sus comandos para retomarlas.",
            bulkConfirm: Phrase { "Cerrar \($0) · libera \($1)" },
            bulkRunning: Phrase { "Cerrando \($0) de \($1)…" },
            close: "Cerrar",
            closeQuestion: Phrase { "¿Cerrar \($0)? Lleva \($1) y libera \($2)." },
            closeNote: "Copio el comando para retomarla.",
            closeConfirm: "Cerrar sesión",
            copyResume: "Copiar comando para retomar"),
        disk: DiskText(
            freeSection: "liberar espacio",
            recoverable: Phrase { "\($0) recuperables" },
            scanning: "Escaneando…",
            neverScanned: "Sin escanear todavía",
            scanned: Phrase { "Escaneado \($0)" },
            scanningLong: "Escaneando el disco: tarda unos minutos.",
            noScanYet: "Aún no hay escaneo del disco.",
            nothingToFree: "Nada que liberar ahora.",
            startingScan: "Empezando el escaneo…",
            scanAgain: "Volver a escanear",
            review: "revisar",
            freeButton: "Liberar",
            sure: "¿Seguro? No se puede deshacer.",
            sureReview: "¿Seguro? Revisa la lista: no se puede deshacer.",
            freeConfirm: Phrase { "Liberar \($0)" },
            freed: Phrase { "Liberados \($0) · \($1)" },
            mapTitle: Phrase { "en qué se van los \($0)" },
            used: Phrase { "\($0) usados" },
            freeable: Phrase { "\($0) liberables" },
            barLabel: "Reparto del disco",
            freeSpace: "Libre"),
        toasts: Toasts(
            closed: Phrase { "Cerrada \($0) · \($1) · comando para retomarla copiado" },
            ended: Phrase { "Terminado \($0) (pid \($1)) · liberados \($2)" },
            freed: Phrase { "Liberados \($0) · \($1)" },
            bulkPartly: Phrase { "Cerradas \($0) de \($1). \($2): \($3)" },
            bulkClosed: Phrase { "Cerradas \($0)" },
            bulkCopied: Phrase { "Cerradas \($0) de \($1) · \($2) · comandos para retomarlas copiados" },
            scanFailed: Phrase { "No pude empezar el escaneo: \($0)" },
            resumeCopied: Phrase { "Comando para retomar \($0) copiado" },
            copied: "Copiado"),
        popover: PopoverText(
            noServerSubline: "sin servidor todavía",
            connectingSubline: "conectando…",
            offlineSubline: "sin conexión",
            updated: Phrase { "actualizado \($0)" },
            staleSubline: Phrase { "sin conexión · dato de \($0)" },
            refresh: "Actualizar ahora",
            settings: "Ajustes",
            quit: "Salir",
            connecting: Phrase { "Conectando con \($0)…" },
            cantReach: Phrase { "No llego a \($0)" },
            retry: "Reintentar",
            offline: "Sin conexión",
            every: Phrase { "cada \($0)" }),
        welcome: Welcome(
            title: "Vigila un servidor Linux desde la barra de menús",
            body: "Disco, RAM, CPU y sesiones de Claude Code de un vistazo, y un clic confirmado para liberar espacio "
                + "y memoria.",
            needsTitle: "Necesita",
            needs: ["Un servidor Linux con systemd", "Acceso SSH con tu clave", "root, o un usuario con sudo"],
            connect: "Conectar un servidor…",
            note: "La app instala un único script en el servidor, vpsmon, y habla con él por SSH."),
        setup: SetupText(
            testing: Phrase { "Conectando con \($0)…" },
            connected: Phrase { host, version, disk, sessions in
                "Conectado a \(host) · vpsmon \(version) · disco al \(disk)"
                    + (sessions > 0 ? " · \(sessions) \(sessions == 1 ? "sesión" : "sesiones") de Claude Code" : "")
            },
            missing: Phrase { "vpsmon no está instalado en \($0)." },
            outdated: Phrase { "\($0) tiene vpsmon \($1); esta app trae la \($2)." },
            schema: Phrase { "\($0) tiene un vpsmon que habla el esquema \($1); esta app necesita el \($2)." },
            noSudoRule: Phrase { "vpsmon no puede hacerse root en \($0) sin contraseña." },
            install: "Instalar en el servidor",
            update: "Actualizar servidor",
            installing: Phrase { "Instalando vpsmon en \($0)…" },
            needsPassword: Phrase { "sudo pide contraseña en \($0), así que la app no puede instalarlo sola. Ejecuta esto en "
                + "Terminal y vuelve a comprobar:" },
            checkAgain: "Comprobar otra vez",
            tryAgain: "Reintentar",
            noTimer: "Este servidor no tiene systemd, así que vpsmon no guarda historial: las gráficas de 24 h se "
                + "quedan vacías."),
        settings: SettingsText(
            windowTitle: "Ajustes de VPS Monitor",
            server: "servidor",
            host: "Host",
            hostPlaceholder: "web-1.ejemplo.com",
            user: "Usuario",
            userPlaceholder: "el de ssh",
            port: "Puerto",
            portPlaceholder: "22",
            key: "Clave SSH",
            keyPlaceholder: "las claves por defecto de ssh",
            choose: "Elegir…",
            chooseKeyTitle: "Elige tu clave privada SSH",
            fromConfig: "Desde ~/.ssh/config",
            noConfigHosts: "No hay servidores en ~/.ssh/config",
            connect: "Conectar",
            requirements: "Necesita un servidor Linux con systemd, acceso SSH con clave, y root o sudo. Al conectar "
                + "se guarda el servidor.",
            general: "general",
            language: "Idioma",
            languageSystem: "Sistema",
            interval: "Actualizar cada",
            notifications: "Avisos de alertas críticas",
            launchAtLogin: "Abrir al iniciar sesión",
            iconOnly: "Solo el icono en la barra",
            version: Phrase { "VPS Monitor \($0)" },
            loginApprove: "Permítelo en Ajustes del Sistema › General › Ítems de inicio.",
            loginNeedsApplications: "Para abrirse al iniciar sesión la app tiene que estar en /Applications.",
            loginRemoveFailed: Phrase { "No pude quitarla del inicio: \($0)" }),
        app: AppText(
            hiddenTitle: "VPS Monitor no aparece en la barra de menús",
            hiddenBody: "macOS no muestra el icono de VPS Monitor. Casi siempre la barra está llena: en un Mac con "
                + "notch, lo que no cabe junto a los menús de la app abierta se oculta. Quita algún icono o arrastra "
                + "VPS Monitor con ⌘ junto al reloj. Si no, está desactivado en Ajustes del Sistema › Barra de "
                + "menús. Luego pulsa Mostrar otra vez.",
            quit: "Salir",
            showAgain: "Mostrar otra vez",
            openSystemSettings: "Abrir Ajustes"),
        cli: CLIText(
            usage: """
            uso: vpsmon-mac <orden> [servidor] [--lang en|es]
              servidor: --host <host> [--user <usuario>] [--port <puerto>] [--identity <clave>]
              status [--fixture <status.json>]
                  lo que muestra el popover, en texto, del servidor o de un status guardado
              install [--installer <vpsmon-install.sh>]
                  conecta como Ajustes, instala o actualiza vpsmon si hace falta, y escribe cada paso
              act <id> [--dry-run]
                  aplica una acción que publicó el servidor (libera disco, cierra una sesión, termina un proceso)
              render <salida.png> [--fixture <status.json>] [--dark] [--open <grupo del mapa>]...
                     [--open-ram <programa>] [--confirm <id>|bulk-close] [--fail <id>] [--stale | --unreachable]
                     [--welcome] [--outdated]
                     [--settings idle|testing|connected|missing|outdated|schema|installing|password|failed]
                  el popover, o la ventana de Ajustes, dibujado en un PNG. --open muestra un grupo del mapa del
                  disco con sus carpetas y sus botones Liberar; --open-ram abre el reparto de la RAM y los procesos
                  de un programa; --confirm abre la confirmación de una fila (en el mapa si su grupo está abierto)
            render lee el servidor una vez salvo con --fixture; nunca actúa sobre él.
            """,
            renderFailed: "No pude dibujar el PNG.",
            sampleRefusal: "Otra acción sigue en marcha en el servidor.",
            noInstaller: "Sin instalador: pasa --installer <vpsmon-install.sh>.",
            needsServer: "Pasa --host, o --fixture para leer un status guardado.",
            dryRun: "simulación, nada cambió"))
}
