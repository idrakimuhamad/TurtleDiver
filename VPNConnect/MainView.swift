import SwiftUI

struct MainView: View {
    @ObservedObject private var vpnManager = VPNManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    
    @State private var showDebugPanel = false
    @State private var debugWidth: CGFloat = 360
    @State private var isConnecting = false
    @State private var isAtBottom = true
    
    private let statusAnimation = Animation.spring(response: 0.38, dampingFraction: 0.75)
    
    var body: some View {
        HStack(spacing: 0) {
            // Main content
            VStack(spacing: 24) {
                // Status Icon with scale bounce
                statusIconView
                    .padding(.top, 40)
                    .scaleEffect(vpnManager.status.statusIconScale)
                    .animation(statusAnimation, value: vpnManager.status)
                
                // Status Label
                Text(statusText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(statusColor)
                    .contentTransition(.interpolate)
                    .animation(statusAnimation, value: vpnManager.status)
                
                // Host Info
                VStack(spacing: 8) {
                    Text("ORGANIZATION DOMAIN")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    Text(settings.vpnHost.isEmpty ? "No VPN Host Set Yet" : settings.vpnHost)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(settings.vpnHost.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                
                // Tunneling Badge
                if settings.useTunneling {
                    Text("SPLIT TUNNELING ACTIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Proxy Badge
                if case .connected = vpnManager.status,
                   settings.useProxy,
                   let proxyName = settings.selectedProxy?.name {
                    Text("PROXY: \(proxyName.uppercased())")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.purple)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // Stats (Duration) with slide/fade
                if case .connected = vpnManager.status {
                    VStack(spacing: 2) {
                        Text("DURATION")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        Text(vpnManager.durationString)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .contentTransition(.numericText())
                            .animation(.linear, value: vpnManager.durationString)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Action Button with scale feedback
                Button(action: actionButtonTapped) {
                    Text(actionButtonText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 240, height: 44)
                        .background(actionButtonBackground)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(actionButtonDisabled)
                .scaleEffect(actionButtonDisabled ? 0.97 : 1.0)
                .animation(statusAnimation, value: actionButtonDisabled)
                
                // Proxy Section
                VStack(spacing: 8) {
                    Toggle("Use Proxy", isOn: $settings.useProxy)
                        .font(.system(size: 12))
                        .toggleStyle(.checkbox)
                    
                    if settings.useProxy {
                        Picker("Proxy Configuration", selection: $settings.selectedProxyID) {
                            Text("(None)").tag(nil as UUID?)
                            ForEach(settings.proxyConfigurations) { config in
                                Text(config.name).tag(config.id as UUID?)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .padding(.vertical, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                
                // Debug Toggle
                Toggle("Enable Debug Mode", isOn: $settings.debugMode)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
            }
            .frame(width: 360)
            .padding(.bottom, 40)
            .animation(statusAnimation, value: vpnManager.status)
            
            // Separator
            if showDebugPanel {
                Divider()
                    .transition(.opacity)
            }
            
            // Debug Panel
            if showDebugPanel {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(vpnManager.debugOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(8)
                            .contentTransition(.opacity)
                        
                        // Invisible anchor at the bottom — auto-scroll targets this
                        Color.clear
                            .frame(height: 1)
                            .id("debugBottom")
                    }
                    .frame(minWidth: 300, idealWidth: 440, maxHeight: .infinity)
                    .background(Color(white: 0.1))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .overlay(alignment: .bottomTrailing) {
                        // "Scroll to Bottom" button — appears when user scrolls up
                        if !isAtBottom {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("debugBottom", anchor: .bottom)
                                }
                                isAtBottom = true
                            } label: {
                                Label("Scroll to Bottom", systemImage: "arrow.down")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(white: 0.2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color(white: 0.35), lineWidth: 1)
                                    )
                            )
                            .foregroundColor(.white)
                            .padding(.trailing, 12)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .onChange(of: vpnManager.debugOutput) { _ in
                        if isAtBottom {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("debugBottom", anchor: .bottom)
                            }
                        }
                    }
                    .background(
                        ScrollPositionObserver(isAtBottom: $isAtBottom)
                    )
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 360, maxWidth: 860, minHeight: 480, idealHeight: 550, maxHeight: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            showDebugPanel = settings.debugMode
            updatePulseState(for: vpnManager.status)
        }
        .onChange(of: settings.debugMode) { newValue in
            withAnimation(.easeInOut(duration: 0.25)) {
                showDebugPanel = newValue
            }
        }
        .onChange(of: vpnManager.status) { newStatus in
            updatePulseState(for: newStatus)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            (NSApp.delegate as? AppDelegate)?.showSettings()
        }
    }
    
    // MARK: - Spinner Management
    
    private func updatePulseState(for status: VPNStatus) {
        switch status {
        case .connecting, .disconnecting:
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                isConnecting = true
            }
        default:
            withAnimation(.easeOut(duration: 0.3)) {
                isConnecting = false
            }
        }
    }
    
    // MARK: - Status Views
    
    private var statusIconView: some View {
        ZStack {
            Circle()
                .fill(statusBackgroundColor)
                .frame(width: 100, height: 100)
            
            // Spinning progress ring during connecting/disconnecting
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(statusIconColor, lineWidth: 3)
                .rotationEffect(.degrees(isConnecting ? 360 : 0))
                .frame(width: 100, height: 100)
                .opacity(isConnecting ? 1.0 : 0.0)
            
            Image(systemName: statusIconName)
                .font(.system(size: 48))
                .foregroundColor(statusIconColor)
        }
        .animation(statusAnimation, value: vpnManager.status)
    }
    
    // MARK: - Computed Properties
    
    private var statusText: String {
        switch vpnManager.status {
        case .disconnected:
            return "Ready to connect"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting..."
        case .error:
            return "Error"
        }
    }
    
    private var statusColor: Color {
        switch vpnManager.status {
        case .disconnected:
            return .primary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .disconnecting:
            return .secondary
        case .error:
            return .red
        }
    }
    
    private var statusIconName: String {
        switch vpnManager.status {
        case .disconnected:
            return "lock.open.fill"
        case .connecting, .connected:
            return "lock.fill"
        case .disconnecting:
            return "lock.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusIconColor: Color {
        switch vpnManager.status {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .disconnecting:
            return .secondary
        case .error:
            return .red
        }
    }
    
    private var statusBackgroundColor: Color {
        switch vpnManager.status {
        case .disconnected:
            return Color.secondary.opacity(0.05)
        case .connecting:
            return Color.orange.opacity(0.05)
        case .connected:
            return Color.green.opacity(0.05)
        case .disconnecting:
            return Color.secondary.opacity(0.05)
        case .error:
            return Color.red.opacity(0.05)
        }
    }
    
    private var actionButtonText: String {
        switch vpnManager.status {
        case .disconnected, .error:
            return "Connect"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Disconnect"
        case .disconnecting:
            return "Disconnecting..."
        }
    }
    
    private var actionButtonDisabled: Bool {
        switch vpnManager.status {
        case .connecting, .disconnecting:
            return true
        default:
            return false
        }
    }
    
    private var actionButtonBackground: Color {
        switch vpnManager.status {
        case .error:
            return .red
        default:
            return .accentColor
        }
    }
    
    // MARK: - Actions
    
    private func actionButtonTapped() {
        if case .connected = vpnManager.status {
            vpnManager.disconnect()
        } else {
            // Validate settings
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
            
            vpnManager.connect()
        }
    }
}

// MARK: - Status Icon Scale

extension VPNStatus {
    var statusIconScale: CGFloat {
        switch self {
        case .disconnected:
            return 1.0
        case .connecting:
            return 1.08
        case .connected:
            return 1.0
        case .disconnecting:
            return 0.95
        case .error:
            return 1.0
        }
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let showSettings = Notification.Name("showSettings")
}

// MARK: - Scroll Position Observer

/// Bridges into the underlying NSScrollView to detect whether the user
/// has scrolled away from the bottom. Updates `isAtBottom` accordingly.
struct ScrollPositionObserver: NSViewRepresentable {
    @Binding var isAtBottom: Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Try to find the enclosing NSScrollView — retries every update
        // since the view may not yet be in the window hierarchy on first call.
        // setup(with:) guards against double-registration internally.
        context.coordinator.findScrollView(from: nsView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }
    
    class Coordinator: NSObject {
        @Binding var isAtBottom: Bool
        weak var scrollView: NSScrollView?
        private var isObserving = false
        
        init(isAtBottom: Binding<Bool>) {
            self._isAtBottom = isAtBottom
        }
        
        func findScrollView(from view: NSView) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var current = view.superview
                while current != nil {
                    if let sv = current as? NSScrollView {
                        self.setup(with: sv)
                        return
                    }
                    current = current?.superview
                }
            }
        }
        
        func setup(with sv: NSScrollView) {
            scrollView = sv
            guard !isObserving else { return }
            isObserving = true
            
            // Observe live scroll (user dragging/trackpad scrolling)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollDidChange),
                name: NSScrollView.didLiveScrollNotification,
                object: sv
            )
            
            // Observe all bounds changes (including programmatic scrolls)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollDidChange),
                name: NSView.boundsDidChangeNotification,
                object: sv.contentView
            )
        }
        
        @objc private func scrollDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            let visibleRect = sv.documentVisibleRect
            let documentHeight = sv.documentView?.frame.height ?? 0
            let threshold: CGFloat = 20.0
            let atBottom = visibleRect.maxY >= documentHeight - threshold
            
            if atBottom != isAtBottom {
                isAtBottom = atBottom
            }
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
            .frame(width: 800, height: 450)
    }
}
#endif
