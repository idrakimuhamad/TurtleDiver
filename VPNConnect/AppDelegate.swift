import Cocoa
import Combine
import SwiftUI

// MARK: - Startup Logger

enum StartupLog {
    private static let logPath = "/tmp/TurtleDiver-launch.log"
    private static let queue = DispatchQueue(label: "com.turtlediver.startup-log")
    
    static func write(_ message: String) {
        print("[TurtleDiver] \(message)")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                // First write — create the file
                try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
        }
    }
    
    static func reset() {
        try? FileManager.default.removeItem(atPath: logPath)
        write("=== Launch Log ===")
        write("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        write("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
        write("LSUIElement: \(Bundle.main.infoDictionary?["LSUIElement"] ?? "not set")")
        write("NSPrincipalClass: \(Bundle.main.infoDictionary?["NSPrincipalClass"] ?? "not set")")
        write("NSMainStoryboardFile: \(Bundle.main.infoDictionary?["NSMainStoryboardFile"] ?? "not set")")
        write("ActivationPolicy: \(NSApp.activationPolicy().rawValue) (0=NSApplicationActivationPolicyRegular, 1=Accessory, 2=Prohibited)")
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var window: NSWindow!
    var settingsWindowController: SettingsWindowController?
    var menuBarManager: MenuBarManager!
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        StartupLog.reset()
        StartupLog.write("applicationDidFinishLaunching started")
        
        // 1. Set up the menu FIRST — before anything else
        StartupLog.write("Step 1: Setting up menu bar...")
        setupMenuBar()
        StartupLog.write("Step 1 done. mainMenu set: \(NSApp.mainMenu != nil)")
        
        // 2. Initialize menu bar (status item) manager
        StartupLog.write("Step 2: Initializing MenuBarManager...")
        menuBarManager = MenuBarManager()
        StartupLog.write("Step 2 done.")
        
        // 3. Create and show the main window
        StartupLog.write("Step 3: Setting up main window...")
        setupMainWindow()
        StartupLog.write("Step 3 done. window: \(window != nil), visible: \(window?.isVisible ?? false)")
        
        // 4. Observe theme changes
        StartupLog.write("Step 4: Setting up theme observation...")
        SettingsManager.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
            .store(in: &cancellables)
        
        // 5. Observe debug mode for window resize
        SettingsManager.shared.$debugMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] debugMode in
                self?.resizeWindowForDebugMode(debugMode)
            }
            .store(in: &cancellables)
        
        // 6. Observe content-affecting settings for dynamic window height
        // Note: VPN status changes do NOT trigger a resize — the main content
        // reserves space for conditional elements and fades them with opacity
        // so the window stays a fixed height during connection transitions.
        Publishers.Merge(
            SettingsManager.shared.$useTunneling.map { _ in },
            SettingsManager.shared.$useProxy.map { _ in }
        )
        .debounce(for: 0.1, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.resizeWindowForContent()
        }
        .store(in: &cancellables)
            
        // 7. Apply initial theme
        applyTheme(SettingsManager.shared.theme)
        StartupLog.write("Step 7: Theme applied")
        
        // 6. Activate last, after everything is set up
        StartupLog.write("Step 6: Activating...")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        StartupLog.write("Step 6 done. isVisible: \(window.isVisible), isKeyWindow: \(window.isKeyWindow)")
        
        // 8. Immediately set the correct window height (before the debounced observation fires)
        resizeWindowForContent()
        StartupLog.write("Step 8: Initial window height set")
        
        StartupLog.write("applicationDidFinishLaunching complete")
    }
    
    private func setupMainWindow() {
        StartupLog.write("  setupMainWindow: creating MainView...")
        let mainView = MainView()
        let hostingView = NSHostingView(rootView: mainView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        StartupLog.write("  setupMainWindow: hostingView created")
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "VPN Connect"
        window.minSize = NSSize(width: 360, height: 480)
        window.maxSize = NSSize(width: 860, height: 680)
        window.isReleasedWhenClosed = false
        window.center()
        StartupLog.write("  setupMainWindow: window created, frame: \(NSStringFromRect(window.frame))")
        
        // Pin the hosting view to all edges — same approach as old AppKit code
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: hostingView.superview!.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: hostingView.superview!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: hostingView.superview!.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: hostingView.superview!.bottomAnchor)
        ])
        
        addSettingsTitlebarAccessory(to: window)
        StartupLog.write("  setupMainWindow: accessory added")
    }
    
    private func addSettingsTitlebarAccessory(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(scale: .medium)
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?.withSymbolConfiguration(config)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.target = self
        button.action = #selector(showSettings)
        
        view.addSubview(button)
        accessory.view = view
        accessory.layoutAttribute = .right
        
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        
        window.addTitlebarAccessoryViewController(accessory)
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
        window.orderFrontRegardless()
    }
    
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        VPNManager.shared.cleanupOnTermination()
    }
    
    /// Calculates the ideal content height based on which UI elements are visible,
    /// then resizes the window accordingly with animation.
    func resizeWindowForContent() {
        guard let window = window else { return }
        
        // Base height for always-visible items (top badge, icon, status, host,
        // spacer, button, proxy section, debug toggle, paddings/spacings).
        let baseHeight: CGFloat = 550
        
        // Extra height for each conditional element
        let sm = SettingsManager.shared
        let tunnelingExtra: CGFloat = sm.useTunneling ? 40 : 0
        let isConnected: Bool
        switch VPNManager.shared.status {
        case .connected: isConnected = true
        default: isConnected = false
        }
        let proxyBadgeExtra: CGFloat = (isConnected && sm.useProxy && sm.selectedProxy != nil) ? 40 : 0
        let durationExtra: CGFloat = isConnected ? 64 : 0
        
        let targetHeight = baseHeight + tunnelingExtra + proxyBadgeExtra + durationExtra
        let clampedHeight = min(max(targetHeight, window.minSize.height), 680)
        
        let currentFrame = window.frame
        let currentContentHeight = window.contentRect(forFrameRect: currentFrame).size.height
        guard abs(currentContentHeight - clampedHeight) > 10 else { return } // skip small changes
        
        let newContentSize = NSSize(width: window.contentRect(forFrameRect: currentFrame).size.width, height: clampedHeight)
        let newFrameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContentSize))
        
        var newFrame = currentFrame
        newFrame.size = newFrameRect.size
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.size.height - newFrame.size.height)
        // Keep centered horizontally
        newFrame.origin.x = currentFrame.origin.x - (newFrame.size.width - currentFrame.size.width) / 2
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }
    
    func resizeWindowForDebugMode(_ enabled: Bool) {
        guard let window = window else { return }
        let targetWidth: CGFloat = enabled ? 800 : 360
        
        // Calculate new frame — keep the window anchored at top-left
        let currentFrame = window.frame
        let newContentSize = NSSize(width: targetWidth, height: window.contentRect(forFrameRect: currentFrame).size.height)
        let newFrameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContentSize))
        
        var newFrame = currentFrame
        newFrame.size = newFrameRect.size
        newFrame.origin.x = currentFrame.origin.x - (newFrame.size.width - currentFrame.size.width) / 2
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.size.height - newFrame.size.height)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }
    
    private func setupMenuBar() {
        StartupLog.write("  setupMenuBar: creating main menu...")
        let mainMenu = NSMenu()
        mainMenu.autoenablesItems = false
        
        // --- App Menu ---
        let appMenuItem = NSMenuItem(title: "TurtleDiver", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "TurtleDiver")
        appMenu.autoenablesItems = false
        appMenuItem.submenu = appMenu
        
        let aboutItem = NSMenuItem(title: "About TurtleDiver",
                                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                    keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        StartupLog.write("  setupMenuBar: added About item")
        
        appMenu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...",
                                       action: #selector(showSettings),
                                       keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        StartupLog.write("  setupMenuBar: added Settings item")
        
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        StartupLog.write("  setupMenuBar: added Quit item")
        
        // --- Edit Menu ---
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = true
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        StartupLog.write("  setupMenuBar: assigning mainMenu...")
        NSApp.mainMenu = mainMenu
        let menuDump = mainMenu.items.map { item in
            let subItems = (item.submenu?.items ?? []).map { "\($0.title)(enabled=\($0.isEnabled),target=\($0.target != nil))" }
            return "\(item.title): [\(subItems.joined(separator: ", "))]"
        }.joined(separator: "; ")
        StartupLog.write("  setupMenuBar: done. menu=\(menuDump)")
    }
}

class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        StartupLog.write("MenuBarManager.init: creating status item...")
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        StartupLog.write("MenuBarManager.init: statusItem created: \(statusItem != nil)")
        
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.imagePosition = .imageLeft
            StartupLog.write("MenuBarManager.init: button image set: \(button.image != nil)")
        } else {
            StartupLog.write("MenuBarManager.init: WARNING - no statusItem.button!")
        }
        
        updateMenu(status: .disconnected)
        setupBindings()
        StartupLog.write("MenuBarManager.init: done")
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
