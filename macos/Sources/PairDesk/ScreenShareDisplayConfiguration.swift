import AppKit
import CoreGraphics

/// Only changes that invalidate capture geometry should end a share. App and
/// full-screen Space switches can post screen-parameter notifications as well.
struct ScreenShareDisplayConfiguration: Equatable {
    struct Display: Equatable {
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let rotation: Double
    }

    let mainDisplayID: CGDirectDisplayID
    let displays: [CGDirectDisplayID: Display]

    @MainActor
    static var current: Self {
        var displays: [CGDirectDisplayID: Display] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let mode = CGDisplayCopyDisplayMode(id)
            displays[id] = Display(bounds: CGDisplayBounds(id),
                                   pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                                   pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                                   rotation: CGDisplayRotation(id))
        }
        return Self(mainDisplayID: CGMainDisplayID(), displays: displays)
    }
}
