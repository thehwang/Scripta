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
    static let minimalBaseWidth: CGFloat = 560

    static func fullContentSize(showChatPanel: Bool, fontScale: Double) -> NSSize {
        let scale = normalizedFontScale(fontScale)
        let width = (showChatPanel ? fullChatWidth : fullBaseWidth) * scale
        let height = fullBaseHeight * scale
        return NSSize(width: width, height: height)
    }

    static func fullMinSize(showChatPanel: Bool, fontScale: Double) -> NSSize {
        fullContentSize(showChatPanel: showChatPanel, fontScale: fontScale)
    }

    static func minimalContentWidth(fontScale: Double) -> CGFloat {
        minimalBaseWidth * normalizedFontScale(fontScale)
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
}
