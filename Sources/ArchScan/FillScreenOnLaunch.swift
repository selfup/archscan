import AppKit
import SwiftUI

/// Sizes the hosting window to fill the screen the first time it appears: a
/// regular window covering everything outside the menu bar and Dock, not
/// native full screen. It reaches the NSWindow through an invisible AppKit
/// view so the size is applied on every launch, whatever frame was saved.
struct FillScreenOnLaunch: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbe: NSView {
        private var didResize = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didResize else { return }
            didResize = true

            // Keep macOS from reopening the window in a saved state (such as
            // native full screen) that would override the frame set below.
            window.isRestorable = false

            // SwiftUI places the window after this callback, so wait a turn of
            // the run loop to have the last word on its frame.
            Task { @MainActor in
                guard let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.visibleFrame, display: true)
            }
        }
    }
}
