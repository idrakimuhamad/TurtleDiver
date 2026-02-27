import Cocoa
import Combine

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    var window: NSWindow!
    var settingsWindowController: SettingsWindowController?
    var menuBarManager: MenuBarManager!
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the main window
        let mainViewController = MainViewController()
        window = NSWindow(contentViewController: mainViewController)
        window.title = "VPN Connect"
        // Start with compact size matching MainViewController default state
        window.setContentSize(NSSize(width: 360, height: 450))
        window.styleMask.insert(.resizable)
        // Allow resizing down to compact width
        window.minSize = NSSize(width: 360, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager()
        
        // Set up the menu bar
        setupMenuBar()
        
        // Observe theme changes
        SettingsManager.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
            .store(in: &cancellables)
            
        // Apply initial theme
        applyTheme(SettingsManager.shared.theme)
    }
    
    private func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }
    
    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up VPN connection if active
        VPNManager.shared.cleanupOnTermination()
    }
    
    private func setupMenuBar() {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "VPN Connect")
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        // Create the status item in the system menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Initial setup
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.imagePosition = .imageLeft
        }
        
        // Setup the initial menu
        updateMenu(status: .disconnected)
        
        // Start observing VPN status changes
        setupBindings()
    }
    
    private func setupBindings() {
        VPNManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateStatusItem(for: status)
                self?.updateMenu(status: status)
            }
            .store(in: &cancellables)
    }
    
    private func updateStatusItem(for status: VPNStatus) {
        guard let button = statusItem.button else { return }
        
        // Use the custom menu bar icon
        // Since we configured it as a template image in Assets.xcassets, 
        // we can set contentTintColor to indicate status if desired.
        
        let icon = NSImage(named: "MenuBarIcon")
        button.image = icon
        
        switch status {
        case .connected:
            // For connected state, maybe we want it to be distinct?
            // Since it's a template image, it adopts the system text color (black/white).
            // We can try to tint it green, but macOS menu bar icons are usually monochrome.
            // Let's stick to the icon, but maybe we can change opacity or add an overlay if needed.
            // For now, the user requested "use icon-menu-bar.png for the menubar".
            // We'll keep the icon consistent.
            button.contentTintColor = nil // Default system behavior
            
        case .disconnected:
            // Ensure it looks "inactive" or just normal?
            // Usually inactive icons are just the icon.
            button.contentTintColor = NSColor.tertiaryLabelColor // Make it dimmer? Or just default.
            // Actually, for menu bar, default is best. 
            // Let's try to distinguish connected state by using default (high contrast)
            // and disconnected by using secondary label color?
            // Or maybe just keep it simple as requested.
            button.contentTintColor = NSColor.secondaryLabelColor
            
        case .connecting, .disconnecting:
            // Maybe orange?
            button.contentTintColor = NSColor.systemOrange
            
        case .error:
            button.contentTintColor = NSColor.systemRed
        }
        
        // If the user wants the icon to be exactly the image provided without tinting:
        // Then we should not set template mode in Assets.xcassets.
        // But standard macOS menu bar icons should be templates.
        // I will assume standard behavior (template) + status indication via tint.
    }
    
    private func updateMenu(status: VPNStatus) {
        let menu = NSMenu()
        
        // 1. Connection Status Item
        let statusTitle: String
        switch status {
        case .connected: statusTitle = "Status: Connected"
        case .disconnected: statusTitle = "Status: Disconnected"
        case .connecting: statusTitle = "Status: Connecting..."
        case .disconnecting: statusTitle = "Status: Disconnecting..."
        case .error: statusTitle = "Status: Error"
        }
        
        // The first item shows status and opens main window
        let statusMenuItem = NSMenuItem(title: statusTitle, action: #selector(openMainWindow), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func openMainWindow() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showMainWindow()
        }
    }
    
    @objc private func openSettings() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            // First ensure app is active and main window is available if needed, 
            // but requirements say "open the main app, and open settings focused"
            appDelegate.showMainWindow()
            appDelegate.showSettings()
        }
    }
    
    @objc private func quitApp() {
        // Disconnect if connected
        if case .connected = VPNManager.shared.status {
            VPNManager.shared.disconnect()
        }
        
        // Terminate the app. applicationWillTerminate in AppDelegate will handle cleanup.
        NSApp.terminate(nil)
    }
}
