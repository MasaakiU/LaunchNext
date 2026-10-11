import AppKit
import CoreGraphics

/// Talks to the Dock's "Show Desktop".
///
/// Toggling goes through the Dock's own notification, so the effect is exactly the system's Show Desktop.
/// Reading the state uses two facts that are visible in the window list while the desktop is shown:
/// the Dock keeps a full-screen window at level 18, and every normal window is pushed almost entirely
/// off screen. Because the Dock itself produces both, the state reads correctly no matter how the
/// desktop was revealed (gesture, hot corner, keyboard shortcut).
enum ShowDesktopBridge {
    private typealias SendNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let sendNotification: SendNotification? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: SendNotification.self)
    }()

    static var isAvailable: Bool { sendNotification != nil }

    static func toggleShowDesktop() {
        sendNotification?("com.apple.showdesktop.awake" as CFString, nil)
    }

    static func isDesktopShown() -> Bool {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let displays = displayBounds()
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var dockOverlayPresent = false
        var normalWindows = 0
        var maxVisibleFraction = 0.0
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            if layer == 18, pid == dockPID, displays.contains(where: { coveredFraction(of: $0, by: bounds) >= 0.9 }) {
                dockOverlayPresent = true
                continue
            }
            guard layer == 0, pid != ownPID, bounds.width >= 100, bounds.height >= 100,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01 else { continue }
            normalWindows += 1
            let visible = displays.reduce(0.0) { $0 + intersectionArea(bounds, $1) }
            maxVisibleFraction = max(maxVisibleFraction, visible / Double(bounds.width * bounds.height))
        }
        return dockOverlayPresent && (normalWindows == 0 || maxVisibleFraction < 0.2)
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let r = a.intersection(b)
        return r.isNull ? 0 : Double(r.width * r.height)
    }

    private static func coveredFraction(of display: CGRect, by window: CGRect) -> Double {
        let area = Double(display.width * display.height)
        return area > 0 ? intersectionArea(window, display) / area : 0
    }
}
