import Cocoa
import Combine

// MARK: - Helpers

/// A view that automatically updates its layer colors when the system appearance changes.
class ThemedContainerView: NSView {
    var isFocused: Bool = false {
        didSet { 
            DispatchQueue.main.async { [weak self] in
                self?.updateLayer()
            }
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
    }
    
    override var wantsUpdateLayer: Bool {
        return true
    }
    
    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            
            if isFocused {
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.borderWidth = 2
            } else {
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.borderWidth = 1
            }
        }
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }
}

protocol FocusDelegate: AnyObject {
    func focusDidUpdate(isFocused: Bool)
}

class FocusTrackingTextField: NSTextField {
    weak var focusDelegate: FocusDelegate?
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDelegate?.focusDidUpdate(isFocused: true)
        }
        return result
    }
    
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusDelegate?.focusDidUpdate(isFocused: false)
    }
}

class FocusTrackingSecureTextField: NSSecureTextField {
    weak var focusDelegate: FocusDelegate?
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDelegate?.focusDidUpdate(isFocused: true)
        }
        return result
    }
    
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusDelegate?.focusDidUpdate(isFocused: false)
    }
}

class SelectionCardView: NSView {
    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }
    var onSelect: (() -> Void)?
    
    private let radioIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    
    init(title: String, description: String) {
        super.init(frame: .zero)
        
        titleLabel.stringValue = title
        descLabel.stringValue = description
        
        setupUI()
        updateAppearance()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        
        // Radio Icon
        radioIcon.translatesAutoresizingMaskIntoConstraints = false
        radioIcon.contentTintColor = .labelColor
        addSubview(radioIcon)
        
        // Text Stack
        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        
        // Styling
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 2
        descLabel.cell?.wraps = true
        
        NSLayoutConstraint.activate([
            radioIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            radioIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            radioIcon.widthAnchor.constraint(equalToConstant: 16),
            radioIcon.heightAnchor.constraint(equalToConstant: 16),
            
            textStack.leadingAnchor.constraint(equalTo: radioIcon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            
            heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
        
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }
    
    @objc private func clicked() {
        onSelect?()
    }
    
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.borderWidth = 1.5
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
                
                radioIcon.image = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "Selected")
                radioIcon.contentTintColor = .controlAccentColor
            } else {
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.borderWidth = 1
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                
                radioIcon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Unselected")
                radioIcon.contentTintColor = .tertiaryLabelColor
            }
        }
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool {
        return true
    }
}

class StandardInputView: NSView, FocusDelegate {
    private let containerView = ThemedContainerView()
    private let textField = FocusTrackingTextField()
    
    var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }
    
    var placeholderString: String? {
        didSet {
            textField.placeholderString = placeholderString
        }
    }
    
    var isEditable: Bool {
        get { textField.isEditable }
        set { textField.isEditable = newValue }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 36)
        ])
        
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.textColor = .labelColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.focusDelegate = self
        
        containerView.addSubview(textField)
        
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
    }
    
    func focusDidUpdate(isFocused: Bool) {
        containerView.isFocused = isFocused
    }
}

class SecureInputView: NSView, NSTextFieldDelegate, FocusDelegate {
    private let containerView = ThemedContainerView()
    private let secureField = FocusTrackingSecureTextField()
    private let plainField = FocusTrackingTextField()
    private let toggleButton = NSButton()
    
    var stringValue: String {
        get { secureField.stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }
    
    var placeholderString: String? {
        didSet {
            secureField.placeholderString = placeholderString
            plainField.placeholderString = placeholderString
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 36)
        ])
        
        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
        toggleButton.target = self
        toggleButton.action = #selector(toggleVisibility)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        
        containerView.addSubview(toggleButton)
        
        NSLayoutConstraint.activate([
            toggleButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            toggleButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 24),
            toggleButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        
        setupField(secureField)
        setupField(plainField)
        
        plainField.isHidden = true
        
        secureField.delegate = self
        plainField.delegate = self
        secureField.focusDelegate = self
        plainField.focusDelegate = self
    }
    
    private func setupField(_ field: NSTextField) {
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.textColor = .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(field)
        
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
    }
    
    @objc private func toggleVisibility() {
        let isSecured = !plainField.isHidden
        if isSecured {
            secureField.stringValue = plainField.stringValue
            plainField.isHidden = true
            secureField.isHidden = false
            toggleButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
            if window?.firstResponder == plainField { window?.makeFirstResponder(secureField) }
        } else {
            plainField.stringValue = secureField.stringValue
            secureField.isHidden = true
            plainField.isHidden = false
            toggleButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide password")
            if window?.firstResponder == secureField { window?.makeFirstResponder(plainField) }
        }
    }
    
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            if field == secureField {
                plainField.stringValue = secureField.stringValue
            } else {
                secureField.stringValue = plainField.stringValue
            }
        }
    }
    
    func focusDidUpdate(isFocused: Bool) {
        containerView.isFocused = isFocused
    }
}

// MARK: - Settings Row View

class SettingsRowView: NSView {
    
    var onClick: (() -> Void)?
    
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    
    init(icon: String, title: String, description: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.onClick = action
        setupUI(icon: icon, title: title, description: description)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(icon: String, title: String, description: String?) {
        wantsLayer = true
        layer?.cornerRadius = 8
        
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = image
        }
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        
        chevronView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Details")
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)
        
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
        ])
        
        if let desc = description {
            descriptionLabel.stringValue = desc
            descriptionLabel.font = NSFont.systemFont(ofSize: 12)
            descriptionLabel.textColor = .secondaryLabelColor
            descriptionLabel.maximumNumberOfLines = 2
            descriptionLabel.cell?.wraps = true
            descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(descriptionLabel)
            
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                
                descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                descriptionLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),
                descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                descriptionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
                titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
            ])
        }
        
        heightAnchor.constraint(greaterThanOrEqualToConstant: description != nil ? 64 : 48).isActive = true
        
        let trackingArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }
    
    @objc private func clicked() { onClick?() }
    
    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }
    
    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func updateLayer() {}
}

// MARK: - Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    
    private var settingsViewController: SettingsNavigationController?
    
    convenience init() {
        let window = NSWindow(contentRect: NSMakeRect(0, 0, 600, 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered,
                             defer: false)
        window.title = "Settings"
        window.center()
        
        window.contentMinSize = NSSize(width: 600, height: 600)
        
        self.init(window: window)
        window.delegate = self
        
        let vc = SettingsNavigationController()
        self.settingsViewController = vc
        window.contentViewController = vc
    }
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        // Reset to root view controller and initial size when window closes
        settingsViewController?.popToRoot(animated: false)
        // Reset window size to standard and center
        window?.setFrame(NSRect(x: 0, y: 0, width: 600, height: 600), display: true)
        window?.center()
    }
}

// MARK: - Navigation Controller

class SettingsNavigationController: NSViewController, SettingsMenuDelegate {
    
    private let headerView = NSView()
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    
    private var currentViewController: NSViewController?
    private var stack: [NSViewController] = []
    
    override func loadView() {
        // Create the view without a frame or with a flexible one
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        self.view = view
        
        view.wantsLayer = true
        view.autoresizingMask = [] // Disable autoresizing mask so view doesn't snap to window's initial size if different
        
        setupUI()
        
        // let menuVC = SettingsMenuViewController()
        // menuVC.delegate = self
        // push(menuVC, animated: false)
        
        view.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
    }
    
    deinit {
        if isViewLoaded {
            view.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            DispatchQueue.main.async {
                self.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    self.headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Removed preferredContentSize as we manage window size explicitly
        
        let menuVC = SettingsMenuViewController()
        menuVC.delegate = self
        push(menuVC, animated: false)
    }
    
    private func setupUI() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(headerView)
        
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.bezelStyle = .regularSquare
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isHidden = true
        headerView.addSubview(backButton)
        
        titleLabel.stringValue = "Settings"
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)
        
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(separator)
        
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),
            
            backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),
            
            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            
            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    func push(_ viewController: NSViewController, animated: Bool = true) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(viewController.view)
        
        // Remove width constraints to allow window to resize freely
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        
        if let current = currentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        
        stack.append(viewController)
        currentViewController = viewController
        
        updateHeader()
    }
    
    func pop(animated: Bool = true) {
        guard stack.count > 1 else { return }
        let _ = stack.popLast()
        let previous = stack.last!
        
        if let current = currentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        
        addChild(previous)
        previous.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(previous.view)
        
        NSLayoutConstraint.activate([
            previous.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            previous.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            previous.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            previous.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        
        currentViewController = previous
        updateHeader()
    }
    
    func popToRoot(animated: Bool = true) {
        guard stack.count > 1 else { return }
        
        // Remove all but first
        while stack.count > 1 {
            stack.removeLast()
        }
        
        let root = stack.first!
        
        if let current = currentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        
        addChild(root)
        root.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(root.view)
        
        // Remove width constraints to allow window to resize freely
        NSLayoutConstraint.activate([
            root.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            root.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            root.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            root.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        
        currentViewController = root
        updateHeader()
    }
    
    private func resizeWindow(to size: NSSize, animated: Bool) {
        // No-op
    }
    
    private func updateHeader() {
        let isRoot = stack.count <= 1
        backButton.isHidden = isRoot
        
        if isRoot {
            titleLabel.stringValue = "Settings"
            titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        } else {
            titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
            if let _ = currentViewController as? ConfigurationViewController {
                titleLabel.stringValue = "Configuration"
            } else if let _ = currentViewController as? AppearanceViewController {
                titleLabel.stringValue = "Appearance"
            } else if let _ = currentViewController as? HistoryViewController {
                titleLabel.stringValue = "History"
            }
        }
    }
    
    @objc private func goBack() {
        pop(animated: true)
    }
    
    func didSelectConfiguration() {
        let configVC = ConfigurationViewController()
        push(configVC)
    }
    
    func didSelectAppearance() {
        let appearanceVC = AppearanceViewController()
        push(appearanceVC)
    }
    
    func didSelectHistory() {
        let historyVC = HistoryViewController()
        push(historyVC)
    }
    

}

// MARK: - Menu View Controller

protocol SettingsMenuDelegate: AnyObject {
    func didSelectConfiguration()
    func didSelectAppearance()
    func didSelectHistory()
}

class SettingsMenuViewController: NSViewController {
    
    weak var delegate: SettingsMenuDelegate?
    
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        self.view = view
        
        // Add explicit width/height constraints to force size
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        
        setupUI()
    }
    
    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)
        
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        
        addSectionHeader("General")
        
        let configRow = SettingsRowView(
            icon: "network",
            title: "VPN Configuration",
            description: "Manage connection details, authentication, and routing"
        ) { [weak self] in
            self?.delegate?.didSelectConfiguration()
        }
        addRow(configRow)
        
        let appearanceRow = SettingsRowView(
            icon: "paintbrush",
            title: "Appearance",
            description: "Choose app theme (Light, Dark, System)"
        ) { [weak self] in
            self?.delegate?.didSelectAppearance()
        }
        addRow(appearanceRow)
        
        addSectionHeader("Advanced")
        
        let historyRow = SettingsRowView(
            icon: "clock",
            title: "Connection History",
            description: "View past connection attempts and logs"
        ) { [weak self] in
            self?.delegate?.didSelectHistory()
        }
        addRow(historyRow)
        
        contentStack.addArrangedSubview(NSView())
    }
    
    private func addSectionHeader(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        contentStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
    }
    
    private func addRow(_ row: SettingsRowView) {
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -40).isActive = true
    }
}

// MARK: - Configuration View Controller

class ConfigurationViewController: NSViewController {
    
    private var hostField: StandardInputView!
    private var idField: StandardInputView!
    private var passwordInput: SecureInputView!
    private var passcodeInput: SecureInputView!
    private var sliceURLsTextView: NSTextView!
    private var stokenFileField: StandardInputView!
    private var fullTunnelCard: SelectionCardView!
    private var splitTunnelCard: SelectionCardView!
    private var useTunneling: Bool = false
    private var resetButton: NSButton!
    private var saveButton: NSButton!
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        self.view = view
        
        // Add explicit width/height constraints to force size
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        
        setupUI()
        loadSettings()
        
        view.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
    }
    
    deinit {
        if isViewLoaded {
            view.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            DispatchQueue.main.async {
                self.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let destructiveColor = NSColor(srgbRed: 0.92, green: 0.0, blue: 0.02, alpha: 1.0)
                    self.resetButton.layer?.backgroundColor = destructiveColor.withAlphaComponent(0.1).cgColor
                    self.saveButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func setupUI() {
        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.distribution = .fillEqually
        footerStack.spacing = 16
        footerStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerStack)
        
        resetButton = NSButton(title: "Reset", target: self, action: #selector(resetSettings))
        resetButton.bezelStyle = .regularSquare
        resetButton.isBordered = false
        resetButton.wantsLayer = true
        let destructiveColor = NSColor(srgbRed: 0.92, green: 0.0, blue: 0.02, alpha: 1.0)
        resetButton.layer?.backgroundColor = destructiveColor.withAlphaComponent(0.1).cgColor
        resetButton.layer?.cornerRadius = 10
        let resetStyle = NSMutableParagraphStyle()
        resetStyle.alignment = .center
        let resetAttrTitle = NSAttributedString(string: "Reset", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: destructiveColor,
            .paragraphStyle: resetStyle
        ])
        resetButton.attributedTitle = resetAttrTitle
        
        saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .regularSquare
        saveButton.isBordered = false
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        saveButton.layer?.cornerRadius = 10
        saveButton.keyEquivalent = "\r"
        let saveStyle = NSMutableParagraphStyle()
        saveStyle.alignment = .center
        let saveAttrTitle = NSAttributedString(string: "Save", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: saveStyle
        ])
        saveButton.attributedTitle = saveAttrTitle
        
        footerStack.addArrangedSubview(resetButton)
        footerStack.addArrangedSubview(saveButton)
        
        NSLayoutConstraint.activate([
            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerStack.heightAnchor.constraint(equalToConstant: 84),
            resetButton.heightAnchor.constraint(equalToConstant: 44),
            saveButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor)
        ])
        
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        
        let authHeader = NSTextField(labelWithString: "Authentication Details")
        authHeader.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        contentStack.addArrangedSubview(authHeader)
        
        addSectionHeader("Organization Domain (Required)", to: contentStack)
        hostField = StandardInputView()
        hostField.placeholderString = "vpn.company.com"
        addFormField(hostField, to: contentStack)
        
        addSectionHeader("Username (Required)", to: contentStack)
        idField = StandardInputView()
        idField.placeholderString = "Enter username"
        addFormField(idField, to: contentStack)
        
        addSectionHeader("Password (Required)", to: contentStack)
        passwordInput = SecureInputView()
        passwordInput.placeholderString = "Enter password"
        addFormField(passwordInput, to: contentStack)
        
        addSectionHeader("Passcode (2FA) (Required)", to: contentStack)
        passcodeInput = SecureInputView()
        passcodeInput.placeholderString = "Enter passcode or token"
        addFormField(passcodeInput, to: contentStack)
        
        addSeparator(to: contentStack)
        
        let configHeader = NSTextField(labelWithString: "Configuration")
        configHeader.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        contentStack.addArrangedSubview(configHeader)
        
        addSectionHeader("Stoken File (.stid)", to: contentStack)
        let stokenStack = NSStackView()
        stokenStack.orientation = .horizontal
        stokenStack.spacing = 8
        stokenStack.distribution = .fill
        stokenFileField = StandardInputView()
        stokenFileField.placeholderString = "~/token.stid"
        stokenStack.addArrangedSubview(stokenFileField)
        let browseButton = NSButton(title: "Browse", target: self, action: #selector(browseStokenFile))
        browseButton.bezelStyle = .rounded
        stokenStack.addArrangedSubview(browseButton)
        contentStack.addArrangedSubview(stokenStack)
        stokenStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -60).isActive = true
        
        addSectionHeader("Traffic Routing", to: contentStack)
        fullTunnelCard = SelectionCardView(title: "Standard VPN", description: "Route all traffic through the VPN connection")
        fullTunnelCard.onSelect = { [weak self] in self?.setTunnelingMode(useTunneling: false) }
        addFormField(fullTunnelCard, to: contentStack)
        splitTunnelCard = SelectionCardView(title: "Split Tunneling (vpn-slice)", description: "Only route specific traffic through VPN based on slice URLs")
        splitTunnelCard.onSelect = { [weak self] in self?.setTunnelingMode(useTunneling: true) }
        addFormField(splitTunnelCard, to: contentStack)
        
        addSectionHeader("Slice URLs (One per line)", to: contentStack)
        let sliceScrollView = NSScrollView()
        sliceScrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        sliceScrollView.hasVerticalScroller = true
        sliceScrollView.borderType = .noBorder
        sliceURLsTextView = NSTextView()
        sliceURLsTextView.font = NSFont.systemFont(ofSize: 12)
        sliceURLsTextView.isRichText = false
        sliceURLsTextView.textColor = .labelColor
        sliceURLsTextView.backgroundColor = .clear
        sliceScrollView.documentView = sliceURLsTextView
        let sliceTextContainer = ThemedContainerView()
        sliceTextContainer.addSubview(sliceScrollView)
        sliceScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sliceScrollView.topAnchor.constraint(equalTo: sliceTextContainer.topAnchor, constant: 4),
            sliceScrollView.leadingAnchor.constraint(equalTo: sliceTextContainer.leadingAnchor, constant: 4),
            sliceScrollView.trailingAnchor.constraint(equalTo: sliceTextContainer.trailingAnchor, constant: -4),
            sliceScrollView.bottomAnchor.constraint(equalTo: sliceTextContainer.bottomAnchor, constant: -4)
        ])
        contentStack.addArrangedSubview(sliceTextContainer)
        sliceTextContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -60).isActive = true
    }
    
    private func addSectionHeader(_ title: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
    }
    
    private func addSeparator(to stack: NSStackView) {
        let box = NSBox()
        box.boxType = .separator
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
    }
    
    private func addFormField(_ field: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
    }
    
    private func setTunnelingMode(useTunneling: Bool) {
        self.useTunneling = useTunneling
        fullTunnelCard.isSelected = !useTunneling
        splitTunnelCard.isSelected = useTunneling
    }
    

    
    private func loadSettings() {
        let settings = SettingsManager.shared
        hostField.stringValue = settings.vpnHost
        passwordInput.stringValue = settings.vpnPassword
        idField.stringValue = settings.vpnID
        passcodeInput.stringValue = settings.vpnPasscode
        setTunnelingMode(useTunneling: settings.useTunneling)
        stokenFileField.stringValue = settings.stokenTokenFilePath
        sliceURLsTextView.string = settings.vpnSliceURLs.joined(separator: "\n")
    }
    
    @objc private func saveSettings() {
        let settings = SettingsManager.shared
        settings.vpnHost = hostField.stringValue
        settings.vpnPassword = passwordInput.stringValue
        settings.vpnID = idField.stringValue
        settings.vpnPasscode = passcodeInput.stringValue
        settings.stokenTokenFilePath = stokenFileField.stringValue
        settings.useTunneling = self.useTunneling
        let urls = sliceURLsTextView.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        settings.vpnSliceURLs = urls
        view.window?.close()
    }
    
    @objc private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset All Settings?"
        alert.informativeText = "This will delete all saved configurations. This action cannot be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        alert.beginSheetModal(for: self.view.window!) { response in
            if response == .alertFirstButtonReturn {
                DispatchQueue.main.async {
                    SettingsManager.shared.resetAllSettings()
                    self.loadSettings()
                }
            }
        }
    }
    
    @objc private func browseStokenFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select stoken file"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.stokenFileField.stringValue = url.path
                SettingsManager.shared.updateStokenTokenURL(url)
            }
        }
    }
}

// MARK: - Appearance View Controller

class AppearanceViewController: NSViewController {
    
    private var systemCard: SelectionCardView!
    private var lightCard: SelectionCardView!
    private var darkCard: SelectionCardView!
    private var cancellables = Set<AnyCancellable>()
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        self.view = view
        
        // Add explicit width/height constraints to force size
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        
        setupUI()
        bindSettings()
    }
    
    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        
        let header = NSTextField(labelWithString: "Appearance")
        header.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        contentStack.addArrangedSubview(header)
        
        addSectionHeader("Theme", to: contentStack)
        
        systemCard = SelectionCardView(title: "System Default", description: "Use the system appearance settings")
        systemCard.onSelect = { SettingsManager.shared.theme = .system }
        addFormField(systemCard, to: contentStack)
        
        lightCard = SelectionCardView(title: "Light", description: "Always use light appearance")
        lightCard.onSelect = { SettingsManager.shared.theme = .light }
        addFormField(lightCard, to: contentStack)
        
        darkCard = SelectionCardView(title: "Dark", description: "Always use dark appearance")
        darkCard.onSelect = { SettingsManager.shared.theme = .dark }
        addFormField(darkCard, to: contentStack)
        
        contentStack.addArrangedSubview(NSView())
    }
    
    private func addSectionHeader(_ title: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
    }
    
    private func addFormField(_ field: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
    }
    
    private func bindSettings() {
        SettingsManager.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.updateSelection(theme)
            }
            .store(in: &cancellables)
    }
    
    private func updateSelection(_ theme: AppTheme) {
        systemCard.isSelected = theme == .system
        lightCard.isSelected = theme == .light
        darkCard.isSelected = theme == .dark
    }
}

// MARK: - History View Controller

class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    
    private var historyTableView: NSTableView!
    private var scrollView: NSScrollView!
    private var clearButton: NSButton!
    private var detailWindowController: NSWindowController?
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        self.view = view
        
        // Add explicit width/height constraints to force size
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        
        setupUI()
        loadHistory()
        
        view.addObserver(self, forKeyPath: "effectiveAppearance", options: [.new], context: nil)
    }
    
    deinit {
        if isViewLoaded {
            view.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            DispatchQueue.main.async {
                self.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    self.clearButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Connection History")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        clearButton = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .regularSquare
        clearButton.isBordered = false
        clearButton.wantsLayer = true
        clearButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        clearButton.layer?.cornerRadius = 8
        let buttonStyle = NSMutableParagraphStyle()
        buttonStyle.alignment = .center
        let buttonAttrTitle = NSAttributedString(string: "Clear History", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: buttonStyle
        ])
        clearButton.attributedTitle = buttonAttrTitle
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clearButton)
        
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view.addSubview(scrollView)
        
        historyTableView = NSTableView()
        historyTableView.headerView = nil
        historyTableView.allowsMultipleSelection = false
        historyTableView.allowsEmptySelection = true
        historyTableView.usesAlternatingRowBackgroundColors = true
        historyTableView.intercellSpacing = NSSize(width: 0, height: 1)
        historyTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        historyTableView.target = self
        historyTableView.doubleAction = #selector(showDetails)
        
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.width = 100
        historyTableView.addTableColumn(dateColumn)
        let hostColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hostColumn.width = 150
        historyTableView.addTableColumn(hostColumn)
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.width = 80
        historyTableView.addTableColumn(statusColumn)
        let durationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        durationColumn.width = 80
        historyTableView.addTableColumn(durationColumn)
        
        scrollView.documentView = historyTableView
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -20),
            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            clearButton.widthAnchor.constraint(equalToConstant: 120),
            clearButton.heightAnchor.constraint(equalToConstant: 30),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }
    

    
    private func loadHistory() {
        historyTableView.dataSource = self
        historyTableView.delegate = self
        historyTableView.reloadData()
    }
    
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Are you sure you want to clear all connection history?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            ConnectionHistoryManager.shared.clearHistory()
            loadHistory()
        }
    }
    
    @objc private func showDetails() {
        guard historyTableView.selectedRow >= 0 else { return }
        let history = ConnectionHistoryManager.shared.getHistory()
        guard historyTableView.selectedRow < history.count else { return }
        let attempt = history[historyTableView.selectedRow]
        
        if let existing = detailWindowController {
            existing.close()
        }
        
        let detailWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered,
                                   defer: false)
        detailWindow.title = "Connection Details - \(attempt.timestamp)"
        let detailVC = ConnectionDetailViewController(attempt: attempt)
        detailWindow.contentViewController = detailVC
        detailWindow.center()
        
        let wc = NSWindowController(window: detailWindow)
        wc.showWindow(nil)
        self.detailWindowController = wc
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return ConnectionHistoryManager.shared.getHistory().count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let history = ConnectionHistoryManager.shared.getHistory()
        guard row < history.count else { return nil }
        let attempt = history[row]
        let cellIdentifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView
        if cellView == nil {
            let cv = NSTableCellView()
            let textField = NSTextField(labelWithString: "")
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = .labelColor
            textField.drawsBackground = false
            textField.isBordered = false
            textField.isEditable = false
            textField.isSelectable = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            
            cv.textField = textField
            cv.addSubview(textField)
            cv.identifier = cellIdentifier
            
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cv.centerYAnchor)
            ])
            cellView = cv
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        
        switch cellIdentifier.rawValue {
        case "date": cellView?.textField?.stringValue = formatter.string(from: attempt.timestamp)
        case "host": cellView?.textField?.stringValue = attempt.host
        case "status":
            cellView?.textField?.stringValue = attempt.status
            if attempt.status.lowercased().contains("connected") { cellView?.textField?.textColor = .systemGreen }
            else if attempt.status.lowercased().contains("error") || attempt.status.lowercased().contains("failed") { cellView?.textField?.textColor = .systemRed }
            else { cellView?.textField?.textColor = .labelColor }
        case "duration":
            if let duration = attempt.duration {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute, .second]
                formatter.unitsStyle = .abbreviated
                cellView?.textField?.stringValue = formatter.string(from: duration) ?? "--"
            } else { cellView?.textField?.stringValue = "--" }
        default: cellView?.textField?.stringValue = ""
        }
        return cellView
    }
}

class ConnectionDetailViewController: NSViewController {
    let attempt: ConnectionAttempt
    init(attempt: ConnectionAttempt) {
        self.attempt = attempt
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view = view
        setupUI()
    }
    
    private func setupUI() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let infoLabel = NSTextField(labelWithString: """
        Host: \(attempt.host)
        Date: \(formatter.string(from: attempt.timestamp))
        Status: \(attempt.status)
        Duration: \(attempt.duration != nil ? DateComponentsFormatter().string(from: attempt.duration!) ?? "--" : "--")
        """)
        infoLabel.font = NSFont.systemFont(ofSize: 12)
        infoLabel.isEditable = false
        infoLabel.isSelectable = true
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)
        
        let logScrollView = NSScrollView()
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.drawsBackground = false
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        view.addSubview(logScrollView)
        
        let logTextView = NSTextView()
        logTextView.string = attempt.logOutput
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .textColor
        logTextView.backgroundColor = .textBackgroundColor
        logScrollView.documentView = logTextView
        
        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logScrollView.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 20),
            logScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }
}