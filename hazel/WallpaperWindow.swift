import AppKit

class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.setFrame(screen.frame, display: true)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        // Start invisible: windows sit transparent (alpha 0) until the first
        // video frame composites, then reveal(). An opaque black window
        // ordered front before the async decode finishes is the startup
        // blackout — the desktop stays visible underneath until reveal.
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = .clear
        self.isReleasedWhenClosed = false
        self.alphaValue = 0.0
    }

    /// Shows the window once the first video frame is composited. Idempotent.
    func reveal(animated: Bool = true) {
        guard alphaValue < 1.0 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
        }
    }

    /// Hides without closing (used when validation fails before teardown).
    func conceal() {
        alphaValue = 0.0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
