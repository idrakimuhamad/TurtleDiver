import Cocoa
import Combine
import SwiftUI

// MARK: - Startup Logger

enum StartupLog {
    /// Next to the VPN connection log, for the same two reasons: `/tmp` names
    /// are predictable (another user can pre-create the file), and
    /// `~/Library/Logs` is where Console.app looks.
    static let logPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TurtleDiver", isDirectory: true)
        .appendingPathComponent("launch.log")
        .path
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
                // First write — create the file, owner-only.
                try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: logPath)
            }
        }
    }
    
    static func reset() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

        // 0. Bring anything stored under an older bundle identifier forward.
        // Settings first, and synchronously: the domain is keyed by the bundle
        // id, so after a rename the app would otherwise start with no
        // preferences at all, and this half cannot block on anything.
        StartupLog.write("Step 0: Migrating settings from older bundle ids...")
        let copiedKeys = SettingsDomainMigration.copyLegacyDomains()
        StartupLog.write("Step 0 done. settings keys: \(copiedKeys.count)")

        // 0b. Credentials, off the main thread. Reading an item that belongs to
        // the app's *previous* identity raises the system's "wants to access"
        // dialog, and the read blocks until it is answered. Done inline here it
        // once held a launch for nearly eleven hours — before the window, menu
        // bar or status item existed. In the background the app is usable, the
        // prompt just sits on top, and every credential read until then reports
        // what is true: not set yet.
        StartupLog.write("Step 0b: Migrating credentials from older bundle ids (background)...")
        KeychainHelper.migrateLegacyServicesInBackground { copied in
            StartupLog.write("Step 0b done. credentials: \(copied)")
        }

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
        StartupLog.write("Step 5: Initializing proxy engine controller...")
        _ = EngineController.shared // auto-starts the engine when enabled
        StartupLog.write("Step 5 done.")
        
        // 5b. Keep the main window sized to its presentation state: compact
        // controls by default, the full dashboard when expanded. The view
        // switches instantly, the frame animates here.
        SettingsManager.shared.$dashboardExpanded
            .receive(on: DispatchQueue.main)
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

        let initialSize = MainWindowLayout.targetSize(
            expanded: SettingsManager.shared.dashboardExpanded,
            screen: NSScreen.main?.frame.size
        )

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "TurtleDiver"
        // The window's own header carries the app name, exactly like the
        // compact/expanded designs; the title stays for the Window menu.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: MainWindowLayout.compactWidth, height: 480)
        window.maxSize = NSSize(width: 1400, height: 1100)
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
        openSettingsRoute(nil)
    }

    /// Menu bar: jump straight to the tools pane — the one place that answers
    /// "why won't it connect" when a command-line tool is missing.
    @objc func showToolSetup() {
        openSettingsRoute(.setup)
    }

    /// Opens Settings, optionally deep-linking to a route (menu bar actions;
    /// nil = root menu).
    func openSettingsRoute(_ route: SettingsRoute?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.pendingRoute = route
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        EngineController.shared.shutdown()
        VPNManager.shared.cleanupOnTermination()
    }
    
    /// Sizes the window to the current presentation state (compact controls or
    /// expanded dashboard), keeping the top edge and the horizontal centre
    /// anchored and animating the change.
    ///
    /// Deliberately *not* driven by VPN status or by other content changes: the
    /// window is resizable, and snapping it back on every state change would
    /// fight a user who just dragged its corner. Only the compact ↔ expanded
    /// decision (and launch) resizes.
    func resizeWindowForContent() {
        guard let window = window else { return }

        let screen = window.screen ?? NSScreen.main
        let target = MainWindowLayout.targetSize(
            expanded: SettingsManager.shared.dashboardExpanded,
            screen: screen?.frame.size
        )
        let currentFrame = window.frame
        let currentContent = window.contentRect(forFrameRect: currentFrame).size
        guard abs(currentContent.width - target.width) > 8 || abs(currentContent.height - target.height) > 8 else {
            return // already the right size (or close enough)
        }

        let newFrameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        var newFrame = currentFrame
        newFrame.size = newFrameRect.size
        // Keep the top edge and the horizontal centre where they were.
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.size.height - newFrame.size.height)
        newFrame.origin.x = currentFrame.origin.x - (newFrame.size.width - currentFrame.size.width) / 2

        // Never park the window off-screen when growing near a display edge.
        if let visible = screen?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.origin.x, visible.minX), max(visible.maxX - newFrame.width, visible.minX))
            newFrame.origin.y = min(max(newFrame.origin.y, visible.minY), max(visible.maxY - newFrame.height, visible.minY))
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.2, 0.64, 1.0)
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

@MainActor
final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var lastKnownStatus: VPNStatus = .disconnected
    
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
                MainActor.assumeIsolated {
                    self?.lastKnownStatus = status
                    self?.updateStatusItem(for: status)
                    self?.updateMenu(status: status)
                }
            }
            .store(in: &cancellables)

        // Engine toggle changes the icon dot and menu items.
        EngineController.shared.$engineRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStatusItem(for: self.lastKnownStatus)
                    self.updateMenu(status: self.lastKnownStatus)
                }
            }
            .store(in: &cancellables)

        // Policy health/selection changes refresh the menu contents.
        EngineController.shared.$policySummaries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateMenu(status: self.lastKnownStatus)
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateStatusItem(for status: VPNStatus) {
        guard let button = statusItem.button else { return }
        
        // Use the custom menu bar icon
        // Since we configured it as a template image in Assets.xcassets, 
        // we can set contentTintColor to indicate status if desired.
        
        button.image = Self.currentIcon(engineOn: EngineController.shared.engineRunning)
        
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
            button.contentTintColor = EngineController.shared.engineRunning ? nil : NSColor.secondaryLabelColor
            
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
        case .error(let message): statusTitle = "Status: Error — \(message)"
        }

        let statusMenuItem = NSMenuItem(title: statusTitle, action: #selector(openMainWindow), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. VPN connect / disconnect
        switch status {
        case .connected:
            let item = NSMenuItem(title: "Disconnect VPN", action: #selector(toggleVPN), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        case .disconnected, .error:
            let item = NSMenuItem(title: "Connect VPN", action: #selector(toggleVPN), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        case .connecting, .disconnecting:
            let item = NSMenuItem(title: "VPN busy…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 3. Proxy engine section
        let engine = EngineController.shared
        let engineToggle = NSMenuItem(
            title: engine.engineRunning ? "Disable Proxy Engine" : "Enable Proxy Engine",
            action: #selector(toggleEngine), keyEquivalent: "")
        engineToggle.target = self
        menu.addItem(engineToggle)

        if engine.engineRunning {
            let ports = [engine.httpPort.map { "HTTP \($0)" }, engine.socks5Port.map { "SOCKS \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            let portsItem = NSMenuItem(title: ports.isEmpty ? "Listening" : "Listening — \(ports)", action: nil, keyEquivalent: "")
            portsItem.isEnabled = false
            menu.addItem(portsItem)
        }

        // The system proxy is the switch users reach for most often, and it is
        // invisible otherwise: surface it here so it can be checked/flipped
        // without opening the Dashboard.
        let systemProxyItem = NSMenuItem(
            title: engine.systemProxyBusy ? "Applying Proxy Settings…" : "Use as System Proxy",
            action: #selector(toggleSystemProxy), keyEquivalent: "")
        systemProxyItem.target = self
        systemProxyItem.state = engine.systemProxyOn ? .on : .off
        systemProxyItem.isEnabled = engine.engineRunning && !engine.systemProxyBusy
        menu.addItem(systemProxyItem)

        menu.addItem(profileSubmenu())
        if let groupItem = selectGroupSubmenu() {
            menu.addItem(groupItem)
        }

        let testItem = NSMenuItem(title: "Test Latency Now", action: #selector(testLatency), keyEquivalent: "")
        testItem.target = self
        testItem.isEnabled = engine.engineRunning
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Dashboard + Settings
        let dashboardItem = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let requirementsItem = NSMenuItem(title: "Check Requirements…",
                                          action: #selector(openToolSetup),
                                          keyEquivalent: "")
        requirementsItem.target = self
        menu.addItem(requirementsItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Status-bar icon: base asset with a distinct look while the engine is
    /// listening (asset catalog ships `MenuBarIcon` / `MenuBarIconEngine`;
    /// falls back to the base icon when the engine variant is missing).
    private static func currentIcon(engineOn: Bool) -> NSImage? {
        if engineOn, let engineIcon = NSImage(named: "MenuBarIconEngine") {
            return engineIcon
        }
        return NSImage(named: "MenuBarIcon")
    }

    /// Profile picker submenu; the checkmarked entry is active.
    private func profileSubmenu() -> NSMenuItem {
        let container = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Profile")
        let manager = ProfileManager.shared
        let active = manager.activeProfile.name
        for name in manager.listProfileNames() {
            let item = NSMenuItem(title: name, action: #selector(switchProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == active ? .on : .off
            submenu.addItem(item)
        }
        container.submenu = submenu
        return container
    }

    /// One submenu per `select` group with the persisted choice checkmarked.
    private func selectGroupSubmenu() -> NSMenuItem? {
        let engine = EngineController.shared
        let groups = ProfileManager.shared.activeProfile.groups.filter { $0.type == .select }
        guard !groups.isEmpty else { return nil }

        let container = NSMenuItem(title: "Policy Groups", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Policy Groups")
        for group in groups {
            let groupItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            let groupMenu = NSMenu(title: group.name)
            let current = engine.engine.policyStore.selection(forGroup: group.name) ?? group.policies.first
            for member in group.policies {
                let item = NSMenuItem(title: member, action: #selector(selectPolicyMember(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["group": group.name, "member": member]
                item.state = member == current ? .on : .off
                groupMenu.addItem(item)
            }
            groupItem.submenu = groupMenu
            submenu.addItem(groupItem)
        }
        container.submenu = submenu
        return container
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

    // MARK: Engine actions

    @objc private func toggleEngine() {
        let engine = EngineController.shared
        engine.setEngineEnabled(!engine.engineRunning)
    }

    @objc private func toggleSystemProxy() {
        let engine = EngineController.shared
        Task { await engine.setSystemProxyEnabled(!engine.systemProxyOn) }
    }

    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = ProfileManager.shared.activateProfile(named: name)
    }

    @objc private func selectPolicyMember(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let group = info["group"], let member = info["member"] else { return }
        EngineController.shared.engine.policyStore.setSelection(member, forGroup: group)
    }

    @objc private func testLatency() {
        EngineController.shared.engine.policyStore.testAllPolicies()
    }

    @objc private func openToolSetup() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showToolSetup()
        }
    }

    @objc private func openDashboard() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openSettingsRoute(.dashboard)
        }
    }

    @objc private func toggleVPN() {
        switch VPNManager.shared.status {
        case .connected:
            VPNManager.shared.disconnect()
        case .disconnected, .error:
            VPNManager.shared.connect()
        default:
            break
        }
    }
}
