import Foundation

/// Installs the bundled Hazel.saver into ~/Library/Screen Savers.
/// No UI code here; callers present errors themselves.
///
/// All mutations serialize on `workQueue`: concurrent callers (launch Task +
/// follow-up switch Task) coalesce onto one install instead of racing
/// remove/copy against each other.
final class SaverInstallService {
    static let shared = SaverInstallService()

    private init() {}

    private static let saverBundleID = "com.live.hazel.saver"
    private static let saverName = "Hazel.saver"

    private let workQueue = DispatchQueue(label: "com.live.hazel.saver-install")

    /// .saver bundled inside hazel.app/Contents/Resources (embedded by build phase).
    var bundledSaverURL: URL? {
        Bundle.main.url(forResource: "Hazel", withExtension: "saver")
    }

    /// The real user home (POSIX, sandbox-proof): FileManager's home resolves
    /// into the host container when sandboxed, and Hazel must stay working if
    /// sandboxing is ever re-enabled.
    static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Destination: ~/Library/Screen Savers/Hazel.saver
    var installURL: URL {
        Self.realHomeDirectory()
            .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent(Self.saverName, isDirectory: true)
    }

    private func infoDictionary(at saverURL: URL) -> [String: Any]? {
        let plistURL = saverURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// True when an installed saver exists and its CFBundleIdentifier matches.
    var isInstalled: Bool {
        infoDictionary(at: installURL)?["CFBundleIdentifier"] as? String == Self.saverBundleID
    }

    /// Installed saver's CFBundleShortVersionString, if present.
    var version: String? {
        infoDictionary(at: installURL)?["CFBundleShortVersionString"] as? String
    }

    enum InstallError: LocalizedError {
        case bundledSaverMissing
        case createDirectoryFailed(String)
        case removeOldFailed(String)
        case copyFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledSaverMissing:
                return "Bundled Hazel.saver not found in the app bundle. Rebuild the app to embed it."
            case .createDirectoryFailed(let detail):
                return "Could not create Screen Savers folder: \(detail)"
            case .removeOldFailed(let detail):
                return "Could not remove old Hazel.saver: \(detail)"
            case .copyFailed(let detail):
                return "Could not install Hazel.saver: \(detail)"
            case .verificationFailed(let detail):
                return "Installed Hazel.saver failed verification: \(detail)"
            }
        }
    }

    /// Copies the bundled .saver over ~/Library/Screen Savers/Hazel.saver.
    /// Atomic: stages to a temp sibling and renames, so a crash never leaves
    /// no saver at all. Serialized against concurrent installs.
    func install() throws {
        try workQueue.sync {
            guard let source = bundledSaverURL,
                  FileManager.default.fileExists(atPath: source.path) else {
                throw InstallError.bundledSaverMissing
            }
            let dest = installURL
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw InstallError.createDirectoryFailed(error.localizedDescription)
            }
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent("\(Self.saverName).installing")
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: staging, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw InstallError.copyFailed(error.localizedDescription)
            }
            guard infoDictionary(at: dest)?["CFBundleIdentifier"] as? String == Self.saverBundleID,
                  FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/MacOS").path) else {
                throw InstallError.verificationFailed("bundle identifier or executable missing after copy")
            }
        }
    }
}
