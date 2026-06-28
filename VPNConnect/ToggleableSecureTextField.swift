import Cocoa

/// A text field with a toggle button to show/hide the password text.
/// Replaces a plain NSSecureTextField with an NSTextField/NSSecureTextField pair
/// and an inline eye icon button.
class ToggleableSecureTextField: NSView {
    private let secureField = NSSecureTextField(frame: .zero)
    private let plainField = NSTextField(frame: .zero)
    private let toggleButton = NSButton(frame: .zero)
    private var showingSecure = true

    var stringValue: String {
        get { showingSecure ? secureField.stringValue : plainField.stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(showingSecure ? secureField : plainField)
        return true
    }

    override init(frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 260, height: 24)) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let fieldWidth = bounds.width - 28

        // Secure text field
        secureField.frame = CGRect(x: 0, y: 0, width: fieldWidth, height: bounds.height)
        secureField.autoresizingMask = [.width, .maxYMargin]
        addSubview(secureField)

        // Plain text field (initially hidden)
        plainField.frame = CGRect(x: 0, y: 0, width: fieldWidth, height: bounds.height)
        plainField.autoresizingMask = [.width, .maxYMargin]
        plainField.isHidden = true
        addSubview(plainField)

        // Toggle button (eye icon)
        toggleButton.frame = CGRect(x: fieldWidth + 4, y: 1, width: 22, height: 22)
        toggleButton.autoresizingMask = [.minXMargin, .maxYMargin]
        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        toggleButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.target = self
        toggleButton.action = #selector(toggleVisibility)
        addSubview(toggleButton)
    }

    @objc private func toggleVisibility() {
        showingSecure.toggle()

        secureField.isHidden = !showingSecure
        plainField.isHidden = showingSecure

        // Copy text between fields
        if showingSecure {
            secureField.stringValue = plainField.stringValue
            window?.makeFirstResponder(secureField)
        } else {
            plainField.stringValue = secureField.stringValue
            window?.makeFirstResponder(plainField)
        }

        // Update icon
        toggleButton.image = NSImage(
            systemSymbolName: showingSecure ? "eye" : "eye.slash",
            accessibilityDescription: showingSecure ? "Show password" : "Hide password"
        )
    }
}
