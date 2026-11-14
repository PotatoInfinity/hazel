import AppKit
import CoreImage

/// User-chosen menu bar icon. First two are the Hazel pixel logo
/// (light = current white art, dark = inverted black art); the rest are
/// minimal SF Symbols rendered as templates so they follow light/dark.
enum MenuBarIcon: String, CaseIterable, Codable {
    case hazelLight
    case hazelDark
    case box
    case boxFilled
    case circle
    case dot
    case diamond
    case diamondFilled

    var title: String {
        switch self {
        case .hazelLight: return "Hazel Light"
        case .hazelDark: return "Hazel Dark"
        case .box: return "Box"
        case .boxFilled: return "Box Filled"
        case .circle: return "Circle"
        case .dot: return "Dot"
        case .diamond: return "Diamond"
        case .diamondFilled: return "Diamond Filled"
        }
    }

    /// SF Symbol name for the minimal options; nil for the Hazel bitmaps.
    var systemSymbolName: String? {
        switch self {
        case .hazelLight, .hazelDark: return nil
        case .box: return "square"
        case .boxFilled: return "square.fill"
        case .circle: return "circle"
        case .dot: return "circle.fill"
        case .diamond: return "diamond"
        case .diamondFilled: return "diamond.fill"
        }
    }

    /// Status-item image. Hazel bitmaps render opaque at 24pt (current
    /// look); SF Symbols render as templates so the system tints them.
    func makeStatusImage() -> NSImage? {
        if let name = systemSymbolName {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hazel")
            image?.isTemplate = true
            return image
        }
        guard let base = NSImage(named: "Logo") else {
            return NSImage(systemSymbolName: "square", accessibilityDescription: "Hazel")
        }
        switch self {
        case .hazelDark: return Self.darkened(base)
        default:
            let copy = base.copy() as? NSImage ?? base
            copy.size = NSSize(width: 24, height: 24)
            copy.isTemplate = false
            return copy
        }
    }

    /// True color invert of the logo: white becomes black, black details
    /// become white, alpha untouched so transparency stays transparent.
    private static func darkened(_ base: NSImage) -> NSImage {
        let size = NSSize(width: 24, height: 24)
        if let tiff = base.tiffRepresentation,
           let input = CIImage(data: tiff),
           let filter = CIFilter(name: "CIColorInvert") {
            filter.setValue(input, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                let context = CIContext(options: nil)
                if let cg = context.createCGImage(output, from: input.extent) {
                    let dark = NSImage(cgImage: cg, size: size)
                    dark.isTemplate = false
                    return dark
                }
            }
        }
        // Fallback: black silhouette through alpha.
        let dark = NSImage(size: size)
        dark.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: base.size),
            operation: .copy,
            fraction: 1.0
        )
        NSColor.black.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        dark.unlockFocus()
        dark.isTemplate = false
        return dark
    }
}
