import Foundation

public enum PollInterval: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var seconds: TimeInterval { TimeInterval(rawValue) }
    /// "1 min"
    public var label: String { "\(rawValue / 60) min" }
}

public struct Settings: Equatable, Sendable {
    /// nil until a server is connected from Settings.
    public var server: ServerAddress?
    public var language = AppLanguage.system
    public var interval = PollInterval.oneMinute
    public var notifications = true
    /// The menu bar shows the icon without a label.
    public var iconOnly = false

    public init() {}

    /// One key per setting, so `defaults read com.jeff909dev.VPSMonitor` is legible and a launch argument such as
    /// `-notifications NO` overrides one for a single run. A missing or unreadable key keeps its default.
    public static func load(from defaults: UserDefaults) -> Settings {
        var settings = Settings()
        if let host = defaults.string(forKey: Key.serverHost), !host.isEmpty {
            settings.server = ServerAddress(
                host: host,
                user: defaults.string(forKey: Key.serverUser).flatMap { $0.isEmpty ? nil : $0 },
                port: defaults.object(forKey: Key.serverPort) == nil ? nil : defaults.integer(forKey: Key.serverPort),
                identityFile: defaults.string(forKey: Key.serverIdentityFile).flatMap { $0.isEmpty ? nil : $0 })
        } else if let legacy = defaults.string(forKey: Key.legacyHost) {
            // Before 0.2 the server was one `user@host` string.
            settings.server = ServerAddress(legacy: legacy)
        }
        if let language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) {
            settings.language = language
        }
        if let interval = PollInterval(rawValue: defaults.integer(forKey: Key.interval)) { settings.interval = interval }
        if defaults.object(forKey: Key.notifications) != nil {
            settings.notifications = defaults.bool(forKey: Key.notifications)
        }
        if defaults.object(forKey: Key.iconOnly) != nil { settings.iconOnly = defaults.bool(forKey: Key.iconOnly) }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        defaults.removeObject(forKey: Key.legacyHost)
        for (key, value) in [(Key.serverHost, server?.host), (Key.serverUser, server?.user),
                             (Key.serverIdentityFile, server?.identityFile)] as [(String, String?)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let port = server?.port { defaults.set(port, forKey: Key.serverPort) } else {
            defaults.removeObject(forKey: Key.serverPort)
        }
        defaults.set(language.rawValue, forKey: Key.language)
        defaults.set(interval.rawValue, forKey: Key.interval)
        defaults.set(notifications, forKey: Key.notifications)
        defaults.set(iconOnly, forKey: Key.iconOnly)
    }

    enum Key {
        static let legacyHost = "host"
        static let serverHost = "serverHost"
        static let serverUser = "serverUser"
        static let serverPort = "serverPort"
        static let serverIdentityFile = "serverIdentityFile"
        static let language = "language"
        static let interval = "intervalSeconds"
        static let notifications = "notifications"
        static let iconOnly = "iconOnly"
    }
}
