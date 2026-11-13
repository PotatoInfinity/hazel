import Foundation

/// Shared handles to the library store and wallpaper controller, set once at
/// launch. The Settings scene and menu actions resolve through here so neither
/// needs init-time injection (the scene is built before the delegate runs).
final class AppContext {
    static let shared = AppContext()

    var store: WallpaperStore?
    var controller: WallpaperController?

    private init() {}
}
