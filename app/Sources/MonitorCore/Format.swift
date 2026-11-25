import Foundation

/// Numbers in one language: its decimal mark and its words for time, with the units `df -h` and `free -h` print on
/// the server (powers of 1024, written GB and MB). Each `Strings` carries one.
public struct Format: Sendable {
    public static let kib: Int64 = 1024
    public static let mib: Int64 = 1024 * 1024
    public static let gib: Int64 = 1024 * 1024 * 1024
    public static let tib: Int64 = 1024 * 1024 * 1024 * 1024

    /// "." or ",".
    public let decimalMark: String
    /// Under five seconds: "now".
    public let justNow: String
    /// "40 s ago" from "40 s".
    public let ago: Phrase<String>

    /// "3.7 GB", "14.2 GB", "300 GB", "812 MB". One decimal below 100, none above; megabytes and smaller whole.
    public func bytes(_ value: Int64) -> String {
        let magnitude = abs(Double(value))
        let sign = value < 0 ? "-" : ""
        let units: [(Int64, String)] = [(Self.tib, "TB"), (Self.gib, "GB"), (Self.mib, "MB"), (Self.kib, "KB")]
        for (size, unit) in units where magnitude >= Double(size) {
            let scaled = magnitude / Double(size)
            let decimals = size >= Self.gib && scaled < 99.95 ? 1 : 0
            return sign + number(scaled, decimals: decimals) + " " + unit
        }
        return sign + "\(Int(magnitude)) B"
    }

    /// "1.5", "16", "5.41": fixed decimals with this language's decimal mark.
    public func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: decimalMark)
    }

    /// "99%" from 0.987.
    public func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "40 s", "12 min", "7 h", "2 d". Hours up to two days, so "30 h" stays more precise than "1 d".
    public func duration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s)) s" }
        if s < 3_600 { return "\(Int(s / 60)) min" }
        if s < 48 * 3_600 { return "\(Int(s / 3_600)) h" }
        return "\(Int(s / 86_400)) d"
    }

    /// "40 s ago"; "now" under five seconds.
    public func ago(seconds: Double) -> String {
        seconds < 5 ? justNow : ago(duration(seconds))
    }

    /// "~7 h" for a forecast: rounded to the nearest unit rather than down.
    public func forecast(hours: Double) -> String {
        if hours < 1 { return "~\(max(1, Int((hours * 60).rounded()))) min" }
        if hours < 48 { return "~\(Int(hours.rounded())) h" }
        return "~\(Int((hours / 24).rounded())) d"
    }

    /// The last two components of a path: "/home/deploy/code/api" → "code/api".
    public static func shortPath(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}
