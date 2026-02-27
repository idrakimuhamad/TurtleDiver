import Cocoa
import Combine

class SettingsAccessoryViewController: NSTitlebarAccessoryViewController {
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(scale: .medium)
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?.withSymbolConfiguration(config)
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = NSApp.delegate
        button.action = Selector(("showSettings"))
        
        view.addSubview(button)
        self.view = view
        
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
    }
}

class MainViewController: NSViewController {
    
    // UI Elements
    private var rootStackView: NSStackView!
    private var mainContentStackView: NSStackView!
    private var debugStackView: NSStackView!
    
    private var statusIconContainer: NSView!
    private var statusIconView: NSImageView!
    private var statusLabel: NSTextField!
    
    private var hostLabel: NSTextField!
    private var tunnelingBadge: NSTextField!
    
    private var statsStackView: NSStackView!
    private var durationLabel: NSTextField!
    private var durationValueLabel: NSTextField!
    
    private var actionButton: NSButton!
    private var debugCheckbox: NSButton!
    
    private var debugScrollView: NSScrollView!
    private var debugTextView: NSTextView!
    
    private var cancellables = Set<AnyCancellable>()
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
        
        setupUI()
        
        // Listen for appearance changes
        view.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
    }
    
    deinit {
        view.removeObserver(self, forKeyPath: "effectiveAppearance")
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            // Need to update UI on main thread
            DispatchQueue.main.async {
                self.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    self.updateUI(for: VPNManager.shared.status)
                    self.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    self.actionButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func updateColorsForAppearance() {
         // Replaced by direct call in observeValue
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupBindings()
        
        if let window = self.view.window {
            setupTitleBarAccessory(window: window)
        }
        
        // Setup challenge handler
        VPNManager.shared.onChallenge = { [weak self] prompt, completion in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Authentication Challenge"
                alert.informativeText = "The server requested a new passcode. Please enter the next token."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                alert.accessoryView = input
                
                NSApp.activate(ignoringOtherApps: true)
                self?.view.window?.makeKeyAndOrderFront(nil)
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    completion(input.stringValue)
                } else {
                    completion("")
                }
            }
        }
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        if let window = self.view.window {
            setupTitleBarAccessory(window: window)
        }
        updateHostLabel()
        updateTunnelingBadge()
        debugCheckbox.state = SettingsManager.shared.debugMode ? .on : .off
        updateDebugViewVisibility(animated: false)
        
        // Add observer for window focus/activation to refresh settings
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: self.view.window)
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self.view.window)
    }
    
    @objc private func windowDidBecomeKey() {
        updateHostLabel()
        updateTunnelingBadge()
    }
    
    private func setupTitleBarAccessory(window: NSWindow) {
        if window.titlebarAccessoryViewControllers.first(where: { $0 is SettingsAccessoryViewController }) == nil {
            let accessory = SettingsAccessoryViewController()
            accessory.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
    
    private func setupUI() {
        // Root Horizontal Stack (Main | Separator | Debug)
        rootStackView = NSStackView()
        rootStackView.orientation = .horizontal
        rootStackView.spacing = 0
        rootStackView.alignment = .top
        rootStackView.distribution = .fill
        rootStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStackView)
        
        NSLayoutConstraint.activate([
            rootStackView.topAnchor.constraint(equalTo: view.topAnchor),
            rootStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStackView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // --- Left Column: Main Content ---
        mainContentStackView = NSStackView()
        mainContentStackView.orientation = .vertical
        mainContentStackView.alignment = .centerX
        mainContentStackView.spacing = 24 // Increased spacing for breathability
        mainContentStackView.edgeInsets = NSEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)
        
        // Add Main Content to Root
        rootStackView.addArrangedSubview(mainContentStackView)
        
        // Width constraint for main content (fixed 360)
        mainContentStackView.widthAnchor.constraint(equalToConstant: 360).isActive = true
        
        // 1. Status Icon with Circle Background
        statusIconContainer = NSView()
        statusIconContainer.wantsLayer = true
        statusIconContainer.layer?.cornerRadius = 50 // Circle
        // Initial color will be set by updateUI
        statusIconContainer.translatesAutoresizingMaskIntoConstraints = false
        statusIconContainer.widthAnchor.constraint(equalToConstant: 100).isActive = true
        statusIconContainer.heightAnchor.constraint(equalToConstant: 100).isActive = true
        
        statusIconView = NSImageView()
        statusIconView.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        statusIconView.contentTintColor = .secondaryLabelColor
        statusIconView.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Status")
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        
        statusIconContainer.addSubview(statusIconView)
        NSLayoutConstraint.activate([
            statusIconView.centerXAnchor.constraint(equalTo: statusIconContainer.centerXAnchor),
            statusIconView.centerYAnchor.constraint(equalTo: statusIconContainer.centerYAnchor)
        ])
        
        mainContentStackView.addArrangedSubview(statusIconContainer)
        
        // 2. Status Label
        statusLabel = NSTextField(labelWithString: "Ready to connect")
        statusLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        statusLabel.textColor = .labelColor
        mainContentStackView.addArrangedSubview(statusLabel)
        
        // 3. Host Info
        let hostStack = NSStackView()
        hostStack.orientation = .vertical
        hostStack.spacing = 8
        hostStack.alignment = .centerX
        
        let hostTitle = NSTextField(labelWithString: "ORGANIZATION DOMAIN")
        hostTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        hostTitle.textColor = .tertiaryLabelColor
        hostStack.addArrangedSubview(hostTitle)
        
        hostLabel = NSTextField(labelWithString: "")
        hostLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        hostLabel.textColor = .labelColor
        hostLabel.isBezeled = false
        hostLabel.drawsBackground = false
        hostLabel.isEditable = false
        hostLabel.isSelectable = true
        hostLabel.alignment = .center
        hostStack.addArrangedSubview(hostLabel)
        
        mainContentStackView.addArrangedSubview(hostStack)
        
        // 4. Tunneling Badge
        tunnelingBadge = NSTextField(labelWithString: "SPLIT TUNNELING ACTIVE")
        tunnelingBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        tunnelingBadge.textColor = .systemBlue
        tunnelingBadge.isHidden = true
        mainContentStackView.addArrangedSubview(tunnelingBadge)
        
        // Spacer (flexible)
        mainContentStackView.addArrangedSubview(NSView())
        
        // 5. Stats (Duration)
        statsStackView = NSStackView()
        statsStackView.orientation = .horizontal
        statsStackView.distribution = .fillEqually
        statsStackView.spacing = 20
        statsStackView.isHidden = true
        
        let durationStack = NSStackView()
        durationStack.orientation = .vertical
        durationStack.spacing = 2
        let dLabel = NSTextField(labelWithString: "DURATION")
        dLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        dLabel.textColor = .tertiaryLabelColor
        durationValueLabel = NSTextField(labelWithString: "00:00:00")
        durationValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        durationStack.addArrangedSubview(dLabel)
        durationStack.addArrangedSubview(durationValueLabel)
        statsStackView.addArrangedSubview(durationStack)
        
        mainContentStackView.addArrangedSubview(statsStackView)
        
        // 6. Action Button
        actionButton = NSButton(title: "Connect", target: self, action: #selector(actionButtonClicked))
        actionButton.bezelStyle = .regularSquare
        actionButton.isBordered = false
        actionButton.wantsLayer = true
        actionButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        actionButton.layer?.cornerRadius = 10
        // Set text color/font via attributed string to ensure visibility on accent color
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrTitle = NSAttributedString(string: "Connect", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        actionButton.attributedTitle = attrTitle
        
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.widthAnchor.constraint(equalToConstant: 240).isActive = true
        actionButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        
        mainContentStackView.addArrangedSubview(actionButton)
        
        // 7. Debug Toggle
        debugCheckbox = NSButton(checkboxWithTitle: "Enable Debug Mode", target: self, action: #selector(debugToggled))
        debugCheckbox.font = NSFont.systemFont(ofSize: 12)
        debugCheckbox.translatesAutoresizingMaskIntoConstraints = false
        mainContentStackView.addArrangedSubview(debugCheckbox)
        
        // --- Separator ---
        // We'll add a visual separator line or background distinction in the debug view itself
        
        // --- Right Column: Debug View ---
        debugStackView = NSStackView()
        debugStackView.orientation = .vertical
        debugStackView.spacing = 0
        debugStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        
        // Separator line
        let separator = NSBox()
        separator.boxType = .separator
        // For a vertical stack, a horizontal separator is default, but we want a vertical line between panes.
        // Since rootStackView is horizontal, we can insert a vertical box there or style the debug view.
        // Let's style the debug view background instead for the "terminal" look.
        
        debugTextView = NSTextView()
        debugTextView.isEditable = false
        debugTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        debugTextView.textColor = NSColor.white // Terminal text
        debugTextView.backgroundColor = NSColor(white: 0.1, alpha: 1.0) // Dark terminal background
        debugTextView.string = "Debug output..."
        
        debugScrollView = NSScrollView()
        debugScrollView.documentView = debugTextView
        debugScrollView.hasVerticalScroller = true
        debugScrollView.borderType = .noBorder
        debugScrollView.translatesAutoresizingMaskIntoConstraints = false
        debugScrollView.wantsLayer = true
        // Set scroll view background to match
        debugScrollView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        
        // Vertical Separator Line
        let verticalLine = NSBox()
        verticalLine.boxType = .custom
        verticalLine.borderType = .noBorder
        verticalLine.fillColor = NSColor.separatorColor
        verticalLine.translatesAutoresizingMaskIntoConstraints = false
        verticalLine.widthAnchor.constraint(equalToConstant: 1).isActive = true
        
        // Add line and scrollview to root (or intermediate container)
        // Since we want the separator to show only when debug is visible, we'll wrap debug content
        
        debugStackView.addArrangedSubview(debugScrollView)
        
        // Add to Root: Separator then Debug
        rootStackView.addArrangedSubview(verticalLine)
        rootStackView.addArrangedSubview(debugStackView)
        
        // Store references to hide/show
        // The vertical line should be part of the debug visibility group
        verticalLine.isHidden = true // Default hidden
        debugStackView.isHidden = true // Default hidden
    }
    
    private func setupBindings() {
        VPNManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateUI(for: status)
            }
            .store(in: &cancellables)
        
        VPNManager.shared.$debugOutput
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.debugTextView.string = output
                self?.scrollToBottom()
            }
            .store(in: &cancellables)
            
        VPNManager.shared.$durationString
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.durationValueLabel.stringValue = duration
            }
            .store(in: &cancellables)
        
        // Listen for debug mode toggle from SettingsManager if possible, 
        // but since we don't have a publisher there, we rely on viewWillAppear 
        // or check periodically. For immediate update, we can use NotificationCenter or KVO.
        // For simplicity, we'll use a Timer or assume Settings window update triggers something.
        // Actually, let's observe UserDefaults.
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @objc private func userDefaultsChanged() {
        debugCheckbox.state = SettingsManager.shared.debugMode ? .on : .off
        updateDebugViewVisibility(animated: true)
        updateTunnelingBadge()
    }
    
    private func updateHostLabel() {
        let host = SettingsManager.shared.vpnHost
        if host.isEmpty {
            hostLabel.stringValue = "No VPN Host Set Yet"
            hostLabel.textColor = .tertiaryLabelColor
        } else {
            hostLabel.stringValue = host
            hostLabel.textColor = .labelColor
        }
    }
    
    private func updateTunnelingBadge() {
        tunnelingBadge.isHidden = !SettingsManager.shared.useTunneling
    }
    
    private func updateUI(for status: VPNStatus) {
        updateTunnelingBadge()
        
        switch status {
        case .disconnected:
            statusLabel.stringValue = "Ready to connect"
            statusLabel.textColor = .labelColor
            
            statusIconView.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Disconnected")
            statusIconView.contentTintColor = .secondaryLabelColor
            // Lighter shade: 0.05 alpha instead of 0.1 or 0.2
            statusIconContainer.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.05).cgColor
            
            setActionButtonTitle("Connect")
            actionButton.isEnabled = true
            
            statsStackView.isHidden = true
            
        case .connecting:
            statusLabel.stringValue = "Connecting..."
            statusLabel.textColor = .systemOrange
            
            statusIconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Connecting")
            statusIconView.contentTintColor = .systemOrange
            statusIconContainer.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.05).cgColor
            
            setActionButtonTitle("Connecting...")
            actionButton.isEnabled = false
            
            statsStackView.isHidden = true
            
        case .connected:
            statusLabel.stringValue = "Connected"
            statusLabel.textColor = .systemGreen
            
            statusIconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Connected")
            statusIconView.contentTintColor = .systemGreen
            statusIconContainer.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.05).cgColor
            
            setActionButtonTitle("Disconnect")
            actionButton.isEnabled = true
            
            statsStackView.isHidden = false
            
        case .disconnecting:
            statusLabel.stringValue = "Disconnecting..."
            actionButton.isEnabled = false
            
        case .error(let message):
            statusLabel.stringValue = "Error"
            statusLabel.textColor = .systemRed
            
            statusIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            statusIconView.contentTintColor = .systemRed
            statusIconContainer.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.05).cgColor
            
            setActionButtonTitle("Retry")
            actionButton.isEnabled = true
        }
    }
    
    private func setActionButtonTitle(_ title: String) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        actionButton.attributedTitle = attrTitle
    }
    
    private func updateDebugViewVisibility(animated: Bool) {
        guard let window = self.view.window else { return }
        
        let debugMode = SettingsManager.shared.debugMode
        let isCurrentlyHidden = debugStackView.isHidden
        
        // Only update if state changed
        if isCurrentlyHidden == !debugMode { return }
        
        // Calculate new content size
        let targetWidth: CGFloat = debugMode ? 800 : 360
        // Preserve current height, but ensure minimum
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let targetHeight: CGFloat = max(400, currentContentSize.height)
        
        // Calculate new frame preserving top-left corner
        let currentFrame = window.frame
        let newFrameRect = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        var newFrame = currentFrame
        newFrame.size = newFrameRect.size
        newFrame.origin.y = currentFrame.origin.y + (currentFrame.height - newFrame.size.height)
        
        if debugMode {
            // OPENING: Show content first, then animate window expansion
            // This ensures content is there when window grows
            self.debugStackView.isHidden = false
            self.setSeparatorHidden(false)
            
            DispatchQueue.main.async {
                if animated {
                    window.setFrame(newFrame, display: true, animate: true)
                } else {
                    window.setFrame(newFrame, display: true)
                }
            }
        } else {
            // CLOSING: Animate window contraction first, then hide content
            // This prevents content from disappearing instantly before shrink
            DispatchQueue.main.async {
                if animated {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.25 // Standard macOS window resize duration
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().setFrame(newFrame, display: true)
                    }, completionHandler: {
                        self.debugStackView.isHidden = true
                        self.setSeparatorHidden(true)
                    })
                } else {
                    window.setFrame(newFrame, display: true)
                    self.debugStackView.isHidden = true
                    self.setSeparatorHidden(true)
                }
            }
        }
    }
    
    private func setSeparatorHidden(_ hidden: Bool) {
        if let separatorIndex = rootStackView.arrangedSubviews.firstIndex(of: debugStackView), separatorIndex > 0 {
            rootStackView.arrangedSubviews[separatorIndex - 1].isHidden = hidden
        }
    }
    
    private func scrollToBottom() {
        if let textView = debugScrollView.documentView as? NSTextView {
            let range = NSRange(location: textView.string.count, length: 0)
            textView.scrollRangeToVisible(range)
        }
    }
    
    @objc private func actionButtonClicked() {
        if case .connected = VPNManager.shared.status {
            VPNManager.shared.disconnect()
        } else {
            // Validate settings
            let settings = SettingsManager.shared
            var missingFields: [String] = []
            
            if settings.vpnHost.isEmpty { missingFields.append("Organization Domain") }
            if settings.vpnID.isEmpty { missingFields.append("Username") }
            if settings.vpnPassword.isEmpty { missingFields.append("Password") }
            if settings.vpnPasscode.isEmpty { missingFields.append("Passcode (2FA)") }
            
            if !missingFields.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Missing Configuration"
                alert.informativeText = "Please set the following required information in Settings:\n\n" + missingFields.map { "• \($0)" }.joined(separator: "\n")
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                
                if alert.runModal() == .alertFirstButtonReturn {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                }
                return
            }
            
            updateHostLabel()
            VPNManager.shared.connect()
        }
    }
    
    @objc private func debugToggled() {
        SettingsManager.shared.debugMode = (debugCheckbox.state == .on)
    }
}
