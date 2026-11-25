import Foundation
import Testing
@testable import MonitorCore

/// Walks every field of a `Strings` with Mirror: plain text as is, and each phrase called with marked arguments, so
/// the tests see what a user would read.
enum StringsWalk {
    static let a = "«A»", b = "«B»", c = "«C»", d = "«D»"
    static let x = 7, y = 11

    /// path → (text, the arguments it was given)
    static func texts(_ strings: Strings) -> [String: (text: String, arguments: [String])] {
        var out: [String: (String, [String])] = [:]
        walk(strings, path: "", into: &out)
        return out
    }

    private static func walk(_ value: Any, path: String, into out: inout [String: (String, [String])]) {
        if let text = value as? String {
            out[path] = (text, [])
            return
        }
        if let list = value as? [String] {
            for (i, text) in list.enumerated() { out["\(path)[\(i)]"] = (text, []) }
            return
        }
        if let (text, arguments) = call(value) {
            out[path] = (text, arguments)
            return
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .struct else {
            if !(value is Language) { out[path] = ("<unknown \(type(of: value))>", []) }
            return
        }
        for child in mirror.children {
            walk(child.value, path: path.isEmpty ? child.label ?? "?" : "\(path).\(child.label ?? "?")", into: &out)
        }
    }

    /// Every `Phrase` shape `Strings` uses. A new shape lands in "<unknown …>" and fails the tests until it is added.
    private static func call(_ value: Any) -> (String, [String])? {
        let (a, b, c, d, x, y) = (a, b, c, d, x, y)
        let (sx, sy) = (String(x), String(y))
        switch value {
        case let f as Phrase<String>: return (f(a), [a])
        case let f as Phrase<Int>: return (f(x), [sx])
        case let f as Phrase<Int32>: return (f(Int32(x)), [sx])
        case let f as Phrase<String, String>: return (f(a, b), [a, b])
        case let f as Phrase<String?, String>: return (f(a, b), [a, b])
        case let f as Phrase<String?, String?, String>: return (f(a, b, c), [a, b, c])
        case let f as Phrase<String?, String, String, String>: return (f(a, b, c, d), [a, b, c, d])
        case let f as Phrase<String, Int>: return (f(a, x), [a, sx])
        case let f as Phrase<Int, Int>: return (f(x, y), [sx, sy])
        case let f as Phrase<Int, String>: return (f(x, a), [sx, a])
        case let f as Phrase<Int32, String>: return (f(Int32(x), a), [sx, a])
        case let f as Phrase<String, String, String>: return (f(a, b, c), [a, b, c])
        case let f as Phrase<String, Int, String>: return (f(a, x, b), [a, sx, b])
        case let f as Phrase<String, Int, Int>: return (f(a, x, y), [a, sx, sy])
        case let f as Phrase<Int, Int, String>: return (f(x, y, a), [sx, sy, a])
        case let f as Phrase<String, Int, Int, String>: return (f(a, x, y, b), [a, sx, sy, b])
        case let f as Phrase<String, String, String, Int>: return (f(a, b, c, x), [a, b, c, sx])
        case let f as Phrase<Int, Int, String, String>: return (f(x, y, a, b), [sx, sy, a, b])
        default: return nil
        }
    }
}

struct StringsTests {
    @Test(arguments: [Language.en, .es])
    func nothingIsEmptyAndEveryValueShows(_ language: Language) {
        let texts = StringsWalk.texts(Strings.for(language))
        #expect(texts.count > 150)
        for (path, entry) in texts.sorted(by: { $0.key < $1.key }) {
            #expect(!entry.text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(path) is empty")
            #expect(!entry.text.hasPrefix("<unknown"), "\(language) \(path): \(entry.text)")
            for argument in entry.arguments {
                #expect(entry.text.contains(argument), "\(language) \(path) drops \(argument): \(entry.text)")
            }
        }
    }

    /// Both tables have the same fields, by construction; this catches a field copied without translating it.
    @Test func spanishIsTranslated() {
        let english = StringsWalk.texts(.en), spanish = StringsWalk.texts(.es)
        #expect(Set(english.keys) == Set(spanish.keys))
        // The same in both languages, on purpose: units, names, symbols.
        let alike: Set<String> = [
            "common.ok", "metrics.cpu", "metrics.loadDetail", "settings.portPlaceholder", "settings.general",
            "notifications.alertTitle", "errors.ssh", "health.ramShort", "health.swapShort", "health.oomShort",
            "settings.version", "settings.host",
        ]
        let same = english.keys.filter { english[$0]?.text == spanish[$0]?.text }
        #expect(Set(same).subtracting(alike).sorted() == [])
    }

    @Test func theLanguageGetsItsOwnTable() {
        #expect(Strings.for(.en).language == .en)
        #expect(Strings.for(.es).language == .es)
        #expect(Strings.for(.es).popover.quit == "Salir")
    }

    @Test func pluralsAndOptionalParts() {
        #expect(en.ram.endQuestion("node", 1, 1, "1 GB") == "End node (pid 1)? It also ends 1 child process. Frees 1 GB.")
        #expect(en.ram.endQuestion("node", 1, 0, "1 GB") == "End node (pid 1)? Frees 1 GB.")
        #expect(es.sessions.idle(1) == "1 parada")
        #expect(es.sessions.idle(3) == "3 paradas")
        #expect(en.setup.connected("web-1", "0.2.0", "85%", 0) == "Connected to web-1 · vpsmon 0.2.0 · disk 85% full")
        #expect(en.setup.connected("web-1", "0.2.0", "85%", 1).hasSuffix("· 1 Claude Code session"))
        #expect(en.health.fillSentence(nil, nil, "~7 h") == "At the last 24 h's rate, the disk fills up in ~7 h.")
        #expect(es.health.fillSentence("/srv", nil, "~7 h") == "Al ritmo de las últimas 24 h, /srv se llena en ~7 h.")
    }

    /// Every error reads as words, in both languages.
    @Test(arguments: [Language.en, .es])
    func everyErrorHasAMessage(_ language: Language) {
        let s = Strings.for(language)
        let errors: [VPSError] = [
            .invalidServer(.host("x y")), .invalidServer(.host("")), .invalidServer(.user("X")),
            .invalidServer(.port(0)), .invalidServer(.identityFile("/k")), .invalidActionID("x;y"),
            .timedOut(seconds: 30), .ssh(.unresolved), .ssh(.timedOut), .ssh(.noRoute), .ssh(.refused),
            .ssh(.keyRefused), .ssh(.hostKeyChanged), .ssh(.silent), .ssh(.other("boom")), .server("boom"),
            .serverSilent, .notInstalled, .sudoPassword, .schema(1), .notJSON, .contract(.missing("a.b")),
            .contract(.type("a.b")), .contract(.corrupt("a.b")), .failed(status: 3, detail: ""),
            .failed(status: 3, detail: "boom"), .noInstaller, .other("boom"), .installer(.sudoMissing),
            .installer(.python3), .installer(.badUser), .installer(.badUnit), .installer(.usage),
            .installer(.noSuchUser), .installer(.visudoMissing), .installer(.sudoersInvalid),
            .installer(.other("disk-full")),
        ]
        for error in errors {
            #expect(!error.message(s).isEmpty)
        }
    }
}
