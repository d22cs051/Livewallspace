import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    private static var didApplyInitialWindowSize = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window: window)
            }
        }
    }

    private func configure(window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 980, height: 700)

        if !Self.didApplyInitialWindowSize {
            window.setContentSize(NSSize(width: 1320, height: 860))
            window.center()
            Self.didApplyInitialWindowSize = true
        }
    }
}
