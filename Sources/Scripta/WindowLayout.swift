import AppKit
import Foundation

enum WindowLayout {
    static let permissionsContentSize = NSSize(width: 900, height: 540)
    static let permissionsMinSize = NSSize(width: 860, height: 520)

    static let setupContentSize = NSSize(width: 560, height: 520)
    static let setupMinSize = NSSize(width: 540, height: 400)

    static let fullBaseWidth: CGFloat = 760
    static let fullChatWidth: CGFloat = 980
    static let fullBaseHeight: CGFloat = 680
    static let fullMinWidth: CGFloat = 640
    static let fullMinHeight: CGFloat = 520
    static let minimalBaseWidth: CGFloat = 560
    static let minimalMinWidth: CGFloat = 500

    static func fullContentSize(showChatPanel: Bool, fontScale: Double) -> NSSize {
        let scale = normalizedFontScale(fontScale)
        let width = (showChatPanel ? fullChatWidth : fullBaseWidth) * scale
        let height = fullBaseHeight * scale
        return NSSize(width: width, height: height)
    }

    static func fullMinSize(showChatPanel: Bool, fontScale: Double) -> NSSize {
        let scale = normalizedFontScale(fontScale)
        let width = (showChatPanel ? fullChatWidth : fullMinWidth) * scale
        let height = fullMinHeight * scale
        return NSSize(width: width, height: height)
    }

    static func clampedFullContentSize(
        _ size: NSSize,
        showChatPanel: Bool,
        fontScale: Double,
        screenVisible: NSRect
    ) -> NSSize {
        let minSize = fullMinSize(showChatPanel: showChatPanel, fontScale: fontScale)
        let defaultSize = fullContentSize(showChatPanel: showChatPanel, fontScale: fontScale)
        let maxWidth = max(minSize.width, screenVisible.width - 32)
        let maxHeight = max(minSize.height, min(defaultSize.height, screenVisible.height - 32))
        return NSSize(
            width: min(max(size.width, minSize.width), maxWidth),
            height: min(max(size.height, minSize.height), maxHeight)
        )
    }

    static func isReasonableFullContentSize(_ size: NSSize) -> Bool {
        size.width >= fullMinWidth * 0.9
            && size.width <= fullChatWidth * 1.8
            && size.height >= fullMinHeight * 0.9
            && size.height <= fullBaseHeight * 1.15
    }

    static func minimalContentWidth(fontScale: Double) -> CGFloat {
        max(minimalBaseWidth, minimalMinWidth) * normalizedFontScale(fontScale)
    }

    /// Minimum content height so minimal mode always fits drag strip + control bar.
    static func minimalMinContentHeight(fontScale: Double) -> CGFloat {
        118 * normalizedFontScale(fontScale)
    }

    static func minimalMinSize(fontScale: Double) -> NSSize {
        let scale = normalizedFontScale(fontScale)
        let height = minimalMinContentHeight(fontScale: fontScale)
        return NSSize(width: minimalMinWidth * scale, height: height)
    }

    static func minimalMaxSize(fontScale: Double) -> NSSize {
        let scale = normalizedFontScale(fontScale)
        return NSSize(width: 900 * scale, height: 320)
    }

    static func normalizedFontScale(_ fontScale: Double) -> CGFloat {
        let value = fontScale > 0 ? fontScale : 1.0
        return CGFloat(min(1.8, max(0.7, value)))
    }
}

extension Notification.Name {
    static let fullWindowLayoutNeeded = Notification.Name("Scripta.fullWindowLayoutNeeded")
}

enum WindowLayoutUserInfoKey {
    static let showChatPanel = "showChatPanel"
    static let fontScale = "fontScale"
    static let animated = "animated"
    /// When true, only adjust window width (e.g. AI chat panel toggle); preserve height.
    static let widthOnly = "widthOnly"
}
