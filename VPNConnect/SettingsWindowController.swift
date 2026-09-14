import Cocoa
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Route to select on the next `showWindow` (menu bar deep links).
    var pendingRoute: SettingsRoute?

    /// Wide enough for the sidebar plus a comfortable form column; the Rules
    /// and Policies tables want the room.
    private static let defaultSize = NSSize(width: 860, height: 620)

    convenience init() {
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.setContentSize(Self.defaultSize)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 800, height: 560)
        window.toolbarStyle = .unifiedCompact
        window.center()
        
        self.init(window: window)
        window.delegate = self
    }
    
    override func showWindow(_ sender: Any?) {
        // The hosting controller is only rebuilt for a deep link. A deep link
        // needs a freshly built view — @State survives a `rootView` swap, so
        // swapping the view value alone would keep the old selection — while an
        // ordinary reopen should keep the pane (and its scroll position) as the
        // user left it. Rebuilding also re-applies the view's fitting size, so
        // the current size is carried over.
        if let route = pendingRoute {
            let contentSize = window?.contentView?.frame.size ?? Self.defaultSize
            window?.contentViewController = NSHostingController(rootView: SettingsView(initialRoute: route))
            window?.setContentSize(contentSize)
        }
        pendingRoute = nil
        window?.title = "Settings"
        
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        // Reset window size and center for next open
        window?.setContentSize(Self.defaultSize)
        window?.center()
    }
}
