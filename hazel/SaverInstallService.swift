import Foundation

/// Installs the bundled Hazel.saver into ~/Library/Screen Savers.
/// No UI code here; callers present errors themselves.
///
/// All mutations serialize on `workQueue`: concurrent callers (launch Task +
/// follow-up switch Task) coalesce onto one install instead of racing
/// remove/copy against each other.
final class SaverInstallService {
    static let shared = SaverInstallService()

    private init() {
        workQueue.setSpecific(key: queueKey, value: ())
    }

    private static let saverBundleID = "com.live.hazel.saver"
    private static let saverName = "Hazel.saver"

    /// Utility QoS: the .saver copy + verify must never contend a foreground
    /// decode. Concurrent callers coalesce onto one install (see above).
    /// Background: installs are rare; live display always wins CPU.
    private let workQueue = DispatchQueue(label: "com.live.hazel.saver-install", qos: .background)
    private let queueKey = DispatchSpecificKey<Void>()
    /// TTL cache for install state: followSwitch/ensureAutomatic run per
    /// switch, but the .saver bundle only changes on install. Without this,
    /// every switch paid 1-2 Info.plist decodes (isInstalled + version).
    /// 5 minutes matches the reselect cooldown; install() invalidates.
    private let cacheLock = NSLock()
    private var cachedInstalled: Bool?
    private var cachedVersion: String??
    private var cachedAt: Date?

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
    /// TTL-cached (5 min): per-switch callers must not pay a plist decode.
    /// Use `refreshInstallCache()` on explicit UI opens when freshness matters.
    var isInstalled: Bool {
        cacheLock.lock()
        if let cached = cachedInstalled, let at = cachedAt,
           Date().timeIntervalSince(at) < 300 {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let (installed, version) = readInstallState()
        cacheLock.lock()
        cachedInstalled = installed
        cachedVersion = version
        cachedAt = Date()
        cacheLock.unlock()
        return installed
    }

    /// Installed saver's CFBundleShortVersionString, if present.
    /// Same TTL cache as isInstalled (single shared plist read).
    var version: String? {
        cacheLock.lock()
        if let cached = cachedVersion, let at = cachedAt,
           Date().timeIntervalSince(at) < 300 {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let (installed, version) = readInstallState()
        cacheLock.lock()
        cachedInstalled = installed
        cachedVersion = version
        cachedAt = Date()
        cacheLock.unlock()
        return version
    }

    /// Single plist read serving both isInstalled + version (was two decodes
    /// per switch: isInstalled checked Info.plist, then version read it again).
    private func readInstallState() -> (installed: Bool, version: String?) {
        guard let dict = infoDictionary(at: installURL) else { return (false, nil) }
        let installed = dict["CFBundleIdentifier"] as? String == Self.saverBundleID
        return (installed, dict["CFBundleShortVersionString"] as? String)
    }

    /// Explicit refresh for menu/Settings opens (user-visible freshness).
    /// Per-switch paths stay on the TTL cache above.
    func refreshInstallCache() {
        let (installed, version) = readInstallState()
        cacheLock.lock()
        cachedInstalled = installed
        cachedVersion = version
        cachedAt = Date()
        cacheLock.unlock()
    }

    enum InstallError: LocalizedError {
        case bundledSaverMissing
        case createDirectoryFailed(String)
        case copyFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledSaverMissing:
                return "Bundled Hazel.saver not found in the app bundle. Rebuild the app to embed it."
            case .createDirectoryFailed(let detail):
                return "Could not create Screen Savers folder: \(detail)"
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
    /// Reentrancy-safe: a nested call from the same queue runs inline instead
    /// of deadlocking on workQueue.sync.
    func install() throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try performInstall()
        } else {
            try workQueue.sync {
                try performInstall()
            }
        }
        // Install changed the bundle: drop the TTL cache so the next
        // per-switch read sees the new version, not the pre-install one.
        cacheLock.lock()
        cachedInstalled = nil
        cachedVersion = nil
        cachedAt = nil
        cacheLock.unlock()
    }

    private func performInstall() throws {
            guard let source = bundledSaverURL,
                  FileManager.default.fileExists(atPath: source.path) else {
                throw InstallError.bundledSaverMissing
            }
            // Double-checked: per-switch callers race on stale TTL reads, so
            // two concurrent installs can both pass the pre-check. The loser
            // skips its copy here, inside the serialized queue, when the
            // winner already made the destination current — no redundant
            // copy + verify while the saver may be loading the bundle.
            if isAlreadyCurrent(source: source) {
                return
            }
            let dest = installURL
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw InstallError.createDirectoryFailed("\(dest.deletingLastPathComponent().path): \(error.localizedDescription)")
            }
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent("\(Self.saverName).installing")
            if FileManager.default.fileExists(atPath: staging.path) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch {
                    NSLog("[Hazel] SaverInstallService: staging cleanup failed %@ : %@", staging.path, error.localizedDescription)
                }
            }
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Atomic replace: remove-then-move leaves a window with no
                    // saver at all if the process crashes in between.
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: dest)
                }
            } catch {
                if FileManager.default.fileExists(atPath: staging.path) {
                    do {
                        try FileManager.default.removeItem(at: staging)
                    } catch {
                        NSLog("[Hazel] SaverInstallService: staging cleanup failed %@ : %@", staging.path, error.localizedDescription)
                    }
                }
                throw InstallError.copyFailed("\(source.path) -> \(dest.path): \(error.localizedDescription)")
            }
            guard infoDictionary(at: dest)?["CFBundleIdentifier"] as? String == Self.saverBundleID else {
                throw InstallError.verificationFailed("\(dest.path): bundle identifier missing or mismatched after copy")
            }
            // Version must be present and match the bundled saver; a version
            // skew means the copy is stale/partial.
            let installedVersion = infoDictionary(at: dest)?["CFBundleShortVersionString"] as? String
            let bundledVersion = infoDictionary(at: source)?["CFBundleShortVersionString"] as? String
            guard let installedVersion, !installedVersion.isEmpty else {
                throw InstallError.verificationFailed("\(dest.path): version missing after copy")
            }
            if let bundledVersion, installedVersion != bundledVersion {
                throw InstallError.verificationFailed("\(dest.path): version mismatch installed=\(installedVersion) bundled=\(bundledVersion)")
            }
            let macOSDir = dest.appendingPathComponent("Contents/MacOS")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: macOSDir.path, isDirectory: &isDir), isDir.boolValue,
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: macOSDir.path),
                  !contents.isEmpty,
                  contents.contains(where: { FileManager.default.isExecutableFile(atPath: macOSDir.appendingPathComponent($0).path) }) else {
                throw InstallError.verificationFailed("\(dest.path): executable missing or not executable in Contents/MacOS")
            }
    }

    /// True when the destination already matches the bundled saver (same
    /// bundle id + same version). Must run inside workQueue (serialized):
    /// callers use it as the losing side of a pre-check race.
    private func isAlreadyCurrent(source: URL) -> Bool {
        guard let bundledVersion = infoDictionary(at: source)?["CFBundleShortVersionString"] as? String,
              !bundledVersion.isEmpty,
              let destDict = infoDictionary(at: installURL),
              destDict["CFBundleIdentifier"] as? String == Self.saverBundleID,
              destDict["CFBundleShortVersionString"] as? String == bundledVersion else {
            return false
        }
        return true
    }
}
