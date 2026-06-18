import Cocoa
import SwiftUI

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    
    convenience init() {
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.setContentSize(NSSize(width: 600, height: 600))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 600, height: 600)
        window.center()
        
        self.init(window: window)
        window.delegate = self
    }
    
    override func showWindow(_ sender: Any?) {
        // Recreate the hosting controller with a fresh SettingsView
        // to reset the NavigationStack to the root menu — otherwise
        // it remembers the last navigated screen across open/close.
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        window?.contentViewController = hostingController
        window?.title = "Settings"
        
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        // Reset window size and center for next open
        window?.setContentSize(NSSize(width: 600, height: 600))
        window?.center()
    }
}
