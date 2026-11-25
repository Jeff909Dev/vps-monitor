import Foundation

/// This build's version, which is also the version of the vpsmon it installs, and the installer it carries.
public enum AppInfo {
    /// The bundle's CFBundleShortVersionString (bundle.sh writes VERSION there). Outside a bundle (the CLI,
    /// `swift run`), the repo's VERSION file in a folder above the executable.
    public static func version(bundle: Bundle = .main) -> String {
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        var folder = bundle.executableURL?.deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            let file = current.appendingPathComponent("VERSION")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            folder = current.deletingLastPathComponent()
        }
        return "0.0.0"
    }

    /// `vpsmon-install.sh` from the app's Resources; nil in a build without it.
    public static func bundledInstaller(bundle: Bundle = .main) -> Data? {
        bundle.url(forResource: "vpsmon-install", withExtension: "sh").flatMap { try? Data(contentsOf: $0) }
    }
}
