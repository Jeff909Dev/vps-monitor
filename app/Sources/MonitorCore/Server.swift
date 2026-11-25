import Foundation

/// Where the server is and how to log in. Only `host` is required; ssh fills in the rest from `~/.ssh/config` and its
/// own defaults.
public struct ServerAddress: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var user: String?
    public var port: Int?
    /// An absolute path to a private key.
    public var identityFile: String?

    public init(host: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    public enum Problem: Equatable, Sendable {
        case host(String)
        case user(String)
        case port(Int)
        case identityFile(String)
    }

    /// `web-1`, `web-1.example.com`, `192.0.2.10`. Never starts with "-", so ssh can't read an option.
    static var hostPattern: Regex<Substring> { /^[A-Za-z0-9][A-Za-z0-9.-]*$/ }
    /// A Linux user name.
    static var userPattern: Regex<Substring> { /^[a-z_][a-z0-9_.-]*$/ }

    /// The address itself when every part is one ssh can take safely. Each part ends up in ssh's argument vector, so
    /// this runs before every command, not only when Settings saves.
    public func validated(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws(VPSError) -> ServerAddress {
        guard host.wholeMatch(of: Self.hostPattern) != nil else { throw .invalidServer(.host(host)) }
        if let user, user.wholeMatch(of: Self.userPattern) == nil { throw .invalidServer(.user(user)) }
        if let port, !(1...65_535).contains(port) { throw .invalidServer(.port(port)) }
        if let key = identityFile, !key.hasPrefix("/") || !fileExists(key) { throw .invalidServer(.identityFile(key)) }
        return self
    }

    /// What Settings used to store: `user@host` or `host`.
    public init?(legacy: String) {
        let parts = legacy.trimmingCharacters(in: .whitespaces)
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: self.init(host: parts[0])
        case 2: self.init(host: parts[1], user: parts[0])
        default: return nil
        }
        guard (try? validated(fileExists: { _ in true })) != nil else { return nil }
    }

    /// "~/.ssh/id_ed25519" → "/Users/<me>/.ssh/id_ed25519".
    static func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst() : path
    }
}

/// The `Host` entries of `~/.ssh/config` that name one machine (no wildcards), with what they set, to fill the
/// Settings form. ssh itself still reads the file; this only saves typing.
public struct SSHConfigHost: Equatable, Sendable, Identifiable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public var id: String { alias }

    /// The form's contents: the alias as the host, so ssh applies the rest of the entry too.
    public var address: ServerAddress {
        ServerAddress(host: alias, user: user, port: port, identityFile: identityFile)
    }

    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        /// The entries the current `Host` line opened; a `Match` block opens none.
        var open: [Int] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // `Keyword value`, `Keyword=value` or `Keyword = value`.
            let pieces = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard pieces.count == 2 else { continue }
            let keyword = pieces[0].lowercased()
            let value = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch keyword {
            case "host":
                open = []
                for alias in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                where !alias.contains(where: { "*?!".contains($0) }) && !hosts.contains(where: { $0.alias == alias }) {
                    open.append(hosts.count)
                    hosts.append(SSHConfigHost(alias: alias))
                }
            case "match":
                open = []
            default:
                // ssh keeps the first value it reads for each keyword; tokens like %h are left to ssh.
                for i in open where !value.contains("%") {
                    switch keyword {
                    case "hostname": hosts[i].hostName = hosts[i].hostName ?? value
                    case "user": hosts[i].user = hosts[i].user ?? value
                    case "port": hosts[i].port = hosts[i].port ?? Int(value)
                    case "identityfile":
                        hosts[i].identityFile = hosts[i].identityFile ?? ServerAddress.expandingTilde(value)
                    default: break
                    }
                }
            }
        }
        return hosts
    }

    /// `~/.ssh/config`, or nothing when it is missing or unreadable.
    public static func load(from url: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".ssh/config")) -> [SSHConfigHost] {
        (try? String(contentsOf: url, encoding: .utf8)).map(parse) ?? []
    }
}
