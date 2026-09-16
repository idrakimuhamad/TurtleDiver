import AppKit
import SwiftUI

/// Main window — one window, two states.
///
/// **Compact** (the default): header, status hero, connect button, the four
/// switches and a "Show Dashboard" link, so the everyday actions are always at
/// hand. **Expanded** (on demand): the same controls plus the engine, policy
/// and traffic cards, the live request table and the connection log.
///
/// The window frame is animated from `MainWindowLayout` in `AppDelegate`, which
/// observes `SettingsManager.dashboardExpanded` — this view only decides what
/// is on screen.
struct MainView: View {
    @ObservedObject private var vpn = VPNManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var engine = EngineController.shared
    /// Profile switches must re-render the header pill.
    @ObservedObject private var profiles = ProfileModelBridge.shared

    /// Set when the window expanded itself (the tunnel came up). A manual
    /// choice always wins and clears the flag, so we never auto-collapse a
    /// dashboard the user opened on purpose.
    @State private var autoExpanded = false
    @State private var copiedLog = false
    /// The docked log starts open — it is only on screen when it has something
    /// to say (`showsLog`) — and collapses out of the way on request.
    @State private var logExpanded = true
    @State private var spinning = false
    @State private var footerHovered = false

    private var expanded: Bool { settings.dashboardExpanded }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            statusHero
                .padding(.horizontal, 14)

            toggles
                .padding(.horizontal, 14)
                .padding(.top, 12)
                // Room under the pinned switches for the dashboard to scroll
                // into: without it the first row of cards was clipped flush
                // against the switch tiles, with nothing to say more was below.
                .padding(.bottom, 12)

            if expanded {
                dashboard
                // Docked, not appended to the dashboard: the log is what you
                // watch *while* something goes wrong, so it must not sit below
                // the request table, where reaching it meant scrolling first.
                if showsLog {
                    logCard
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncSpinner() }
        .onChange(of: vpn.status) { _, newStatus in handleStatusChange(newStatus) }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            (NSApp.delegate as? AppDelegate)?.showSettings()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text("TurtleDiver")
                    .font(.system(size: 14, weight: .semibold))
                Text("VPN + proxy routing, made simple.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            profilePill
        }
    }

    /// Active-profile picker. Switching profiles reloads the engine through
    /// `EngineController`'s profile observation.
    private var profilePill: some View {
        let manager = ProfileManager.shared
        let active = manager.activeProfile.name
        return Menu {
            ForEach(manager.listProfileNames(), id: \.self) { name in
                Button {
                    _ = manager.activateProfile(named: name)
                } label: {
                    if name == active {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(active)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Active profile")
    }

    // MARK: - Status

    private var statusHero: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(badgeFill)
                    .frame(width: 44, height: 44)
                if isBusy {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(statusTint, lineWidth: 2.5)
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                }
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(badgeForeground)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusTitleColor)
                    .lineLimit(1)
                if let detail = statusDetail {
                    statusDetailLine(detail)
                }
            }

            Spacer(minLength: 8)

            // Status and action in one card: the button no longer owns a row of
            // its own, so the everyday controls sit together instead of in two
            // stacked bands.
            actionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(statusTint.opacity(isDimState ? 0.07 : 0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusTint.opacity(isDimState ? 0.18 : 0.30))
        )
        .animation(.easeInOut(duration: 0.2), value: vpn.status)
    }

    /// Host on the left, duration on the right, both on the detail line — which
    /// left the card's trailing edge to the one thing that acts: the button.
    /// The duration is `.fixedSize()` so a long host truncates first (the
    /// other way round hid the number that changes).
    @ViewBuilder
    private func statusDetailLine(_ detail: String) -> some View {
        HStack(spacing: 6) {
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if vpn.status == .connected {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(vpn.durationString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
    }

    /// Idle is not a problem state, so it is not coloured like one: the badge
    /// stays neutral while the title keeps full contrast (it used to be drawn in
    /// the state tint, which made the headline read as disabled).
    private var isDimState: Bool {
        switch vpn.status {
        case .disconnected, .disconnecting: return true
        case .connecting, .connected, .error: return false
        }
    }

    private var badgeFill: Color {
        switch vpn.status {
        case .connected, .error, .connecting: return statusTint
        case .disconnected, .disconnecting: return Color.secondary.opacity(0.20)
        }
    }

    private var badgeForeground: Color {
        switch vpn.status {
        case .connected, .error, .connecting: return .white
        case .disconnected, .disconnecting: return Color.primary.opacity(0.75)
        }
    }

    private var statusTitleColor: Color {
        isDimState ? .primary : statusTint
    }

    private var actionButton: some View {
        Button(action: actionButtonTapped) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(actionButtonText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            // A fixed box, not the whole row: a fixed width keeps the button
            // from resizing itself between "Connect" and "Disconnect", which
            // would shove the status text sideways on every state change.
            .frame(width: 106, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(actionButtonBackground))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(vpn.status == .disconnecting)
        .opacity(vpn.status == .disconnecting ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.2), value: vpn.status)
    }

    // MARK: - Switches

    private var toggles: some View {
        Group {
            if expanded {
                // A grid needs an explicit leading alignment: its default is to
                // centre each cell, and a `.switch` Toggle is content-sized, so
                // the rows floated mid-cell with ragged left edges.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(switchSpecs) { spec in
                        SwitchTile(spec: spec, expanded: true)
                    }
                }
            } else {
                // Compact: the rows share the leftover height so the window is
                // filled evenly instead of ending in dead space, with hairlines
                // between them so the spread reads as a settings list.
                VStack(spacing: 0) {
                    ForEach(Array(switchSpecs.enumerated()), id: \.element.id) { index, spec in
                        SwitchTile(spec: spec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        if index < switchSpecs.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var switchSpecs: [SwitchSpec] {
        [
            SwitchSpec(
                id: "tunneling",
                title: "Tunneling (vpn-slice)",
                caption: tunnelingCaption,
                isOn: $settings.useTunneling
            ),
            SwitchSpec(
                id: "engine",
                title: "Proxy Engine",
                caption: engineCaption,
                isOn: Binding(
                    get: { engine.engineRunning },
                    set: { on in
                        engine.setEngineEnabled(on)
                        // Turning the engine on is "something to watch" — show the
                        // dashboard without making the user go look for it. Only
                        // the user's switch does this: the engine also auto-starts
                        // at launch from the saved preference, and that must not
                        // override the window state the user left behind.
                        if on { expandIfNeeded() }
                    }
                )
            ),
            SwitchSpec(
                id: "system-proxy",
                title: "Use as System Proxy",
                caption: systemProxyCaption,
                isOn: Binding(
                    get: { engine.systemProxyOn },
                    set: { on in Task { await engine.setSystemProxyEnabled(on) } }
                ),
                enabled: engine.engineRunning && !engine.systemProxyBusy,
                busy: engine.systemProxyBusy
            ),
            SwitchSpec(
                id: "debug",
                title: "Debug Output",
                caption: settings.debugMode ? "Live log shown below" : "Show live logs",
                isOn: $settings.debugMode
            )
        ]
    }

    private var tunnelingCaption: String {
        let count = settings.vpnSliceURLs.count
        guard settings.useTunneling, count > 0 else { return "Only selected hosts go through VPN" }
        return "\(count) target\(count == 1 ? "" : "s") routed through the tunnel"
    }

    private var engineCaption: String {
        guard engine.engineRunning else { return "Local routing is off" }
        let ports = [engine.httpPort.map { "HTTP \($0)" }, engine.socks5Port.map { "SOCKS5 \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return ports.isEmpty ? "Listening" : ports
    }

    private var systemProxyCaption: String {
        if engine.systemProxyBusy { return "Applying proxy settings…" }
        guard engine.engineRunning else { return "Needs the proxy engine" }
        return engine.systemProxyOn ? "All apps use TurtleDiver" : "Send all apps through the engine"
    }

    // MARK: - Dashboard (expanded state)

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Equal-height row: `minHeight` is applied inside each card, so
                // every card is exactly as tall as the tallest content and the
                // three tops and bottoms line up.
                HStack(alignment: .top, spacing: 10) {
                    engineCard
                    policyCard
                    trafficCard
                }
                RequestsCard()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        // A row is sliced mid-height at both scroll boundaries. Without the
        // fades that hard cut reads as a rendering glitch rather than "there is
        // more this way".
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
            .allowsHitTesting(false)
        }
        .transition(.opacity)
    }

    private var engineCard: some View {
        StatCard(title: "Proxy Engine", minHeight: 116) {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.engineRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(engine.engineRunning ? "Running" : "Off")
                    .font(.system(size: 12, weight: .medium))
            }
            if engine.engineRunning {
                addressRow("HTTP", "127.0.0.1:\(engine.httpPort.map(String.init) ?? "—")")
                addressRow("SOCKS5", "127.0.0.1:\(engine.socks5Port.map(String.init) ?? "—")")
            } else {
                Text("Rules and policies apply while the engine is running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let error = engine.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    /// Label in the UI font, address in monospace — monospacing the label too
    /// made "HTTP" look letter-spaced.
    private func addressRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var policyCard: some View {
        StatCard(
            title: "Policy Health",
            minHeight: 116,
            actionLabel: "Test All",
            action: { engine.engine.policyStore.testAllPolicies() },
            actionEnabled: engine.engineRunning
        ) {
            if engine.policySummaries.isEmpty {
                Text("No policies in the active profile.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.policySummaries.prefix(5), id: \.name) { summary in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(RequestFormat.policyColor(summary.name))
                            .frame(width: 6, height: 6)
                        Text(summary.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        healthBadge(summary)
                    }
                }
            }
        }
    }

    /// Latency as a small pill, so a row's health reads at a glance instead of
    /// relying on the colour of a bare number.
    @ViewBuilder
    private func healthBadge(_ summary: PolicySummary) -> some View {
        switch summary.health.lastResult {
        case .notProbed:
            Text("—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        case .success(let ms):
            pill(String(format: "%.0f ms", ms), color: .green)
        case .failure:
            pill("failed", color: .red)
        case .timeout:
            pill("timeout", color: .orange)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 54)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var trafficCard: some View {
        let up = engine.requests.reduce(0) { $0 + $1.bytesToDestination }
        let down = engine.requests.reduce(0) { $0 + $1.bytesToClient }
        return StatCard(title: "Traffic (This Session)", minHeight: 116) {
            HStack(spacing: 12) {
                trafficMetric(RequestFormat.totalBytes(up), arrow: "arrow.up", tint: .blue)
                trafficMetric(RequestFormat.totalBytes(down), arrow: "arrow.down", tint: .green)
            }
            Text("\(engine.requests.count) request\(engine.requests.count == 1 ? "" : "s") through the engine")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if up + down > 0 {
                TrafficBar(up: up, down: down)
            } else {
                // Two full-width tracks with nothing in them read as two full
                // bars; say there is nothing to show instead.
                Text(engine.requests.isEmpty ? "Waiting for traffic." : "No bytes transferred yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The arrow carries the same colour as its bar below, which is what labels
    /// the two bars.
    private func trafficMetric(_ value: String, arrow: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    /// The log is docked below the dashboard (not part of its scroll view) and
    /// turns itself on when it is actually useful: while a connection is coming
    /// up or running, or when the Debug Output switch asks for it.
    private var showsLog: Bool {
        if settings.debugMode { return true }
        switch vpn.status {
        case .connecting, .connected, .disconnecting: return true
        case .disconnected, .error: return false
        }
    }

    /// The docked console: header (collapse, VERBOSE, Copy) plus the log body.
    /// It sits between the dashboard and the footer, at a fixed height, so the
    /// request table scrolls inside its own card instead of being the thing you
    /// have to scroll past to reach the log.
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { logExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: logExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("Live Log")
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(logExpanded ? "Hide the log" : "Show the log")

                if settings.debugMode {
                    Text("VERBOSE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 8)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(vpn.debugOutput, forType: .string)
                    copiedLog = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLog = false }
                } label: {
                    Label(copiedLog ? "Copied" : "Copy", systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copiedLog ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(vpn.debugOutput.isEmpty)
            }

            if logExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if logLines.isEmpty {
                                Text("No log output yet.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.62))
                            } else {
                                ForEach(logLines) { line in
                                    logLineText(line)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(logBottomAnchor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    }
                    // A dark, *opaque* console. The old fill was
                    // `black.opacity(0.32)` over a light window, which turned
                    // the light log text into pale ink on mid grey; the colours
                    // below are the ones tuned for a dark background, so the
                    // background has to actually be dark.
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
                    .onAppear { proxy.scrollTo(logBottomAnchor, anchor: .bottom) }
                    .onChange(of: vpn.debugOutput) { _, _ in
                        proxy.scrollTo(logBottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
        // Card chrome, so the log reads as one block instead of text floating on
        // the window background (the old fill was nearly the same colour).
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private let logBottomAnchor = "logBottom"

    /// The tail of the log, split for colouring. Lines are cheap value types and
    /// only the last few hundred are parsed — the raw buffer covers a session.
    private var logLines: [DebugLogLine] {
        DebugLogParser.lines(from: vpn.debugOutput)
    }

    private func logLineText(_ line: DebugLogLine) -> some View {
        var text = Text(line.time + (line.time.isEmpty ? "" : " "))
            .foregroundColor(Color(white: 0.58))
        if !line.tag.isEmpty {
            text = text + Text("[\(line.tag)] ").foregroundColor(logTagColor(line.tag))
        }
        return text + Text(line.body).foregroundColor(logBodyColor(line.severity))
    }

    private func logTagColor(_ tag: String) -> Color {
        switch tag {
        case "SEND": return .purple
        case "HANDLER": return .blue
        case "stderr": return Color(white: 0.68)
        default: return Color(white: 0.55)
        }
    }

    private func logBodyColor(_ severity: DebugLogLine.Severity) -> Color {
        switch severity {
        case .normal: return Color(white: 0.93)
        case .highlight: return Color(red: 0.42, green: 0.85, blue: 0.5)
        case .warning: return Color(red: 1.0, green: 0.78, blue: 0.35)
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button {
                setExpanded(!expanded, manual: true)
            } label: {
                Label(
                    expanded ? "Hide Dashboard" : "Show Dashboard",
                    systemImage: expanded ? "chevron.up" : "chevron.down"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(footerHovered ? Color.primary : Color.primary.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { footerHovered = $0 }
            .help(expanded ? "Collapse to the essentials" : "Show traffic, policies and logs")
        }
    }

    // MARK: - Presentation state

    private func setExpanded(_ value: Bool, manual: Bool) {
        if manual { autoExpanded = false }
        guard settings.dashboardExpanded != value else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            settings.dashboardExpanded = value
        }
    }

    private func expandIfNeeded() {
        guard !settings.dashboardExpanded else { return }
        autoExpanded = true
        setExpanded(true, manual: false)
    }

    private func handleStatusChange(_ status: VPNStatus) {
        syncSpinner()
        switch status {
        case .connected:
            expandIfNeeded()
        case .disconnected:
            // Only undo our own expansion — the user's choice is sticky.
            if autoExpanded { setExpanded(false, manual: false) }
        default:
            break
        }
    }

    private func syncSpinner() {
        switch vpn.status {
        case .connecting, .disconnecting:
            spinning = true
        default:
            spinning = false
        }
    }

    // MARK: - Status presentation

    private var isBusy: Bool {
        switch vpn.status {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    private var statusTitle: String {
        switch vpn.status {
        case .disconnected: return "Ready to connect"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .error: return "Connection error"
        }
    }

    private var statusDetail: String? {
        switch vpn.status {
        case .error(let message):
            return message
        case .connected:
            return settings.vpnHost.isEmpty ? nil : settings.vpnHost
        case .disconnected:
            return settings.vpnHost.isEmpty ? "No VPN host set — open Settings" : settings.vpnHost
        default:
            return nil
        }
    }

    private var statusTint: Color {
        switch vpn.status {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected, .disconnecting: return .secondary
        }
    }

    /// A padlock reads as "locked away"; when the tunnel is actually up the
    /// badge should say so at a glance.
    private var statusIcon: String {
        switch vpn.status {
        case .disconnected: return "lock.open.fill"
        case .connecting, .disconnecting: return "lock.fill"
        case .connected: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var actionButtonText: String {
        switch vpn.status {
        case .disconnected: return "Connect"
        case .connecting: return "Cancel"
        case .connected: return "Disconnect"
        case .disconnecting: return "Disconnecting…"
        case .error: return "Reconnect"
        }
    }

    private var actionButtonBackground: Color {
        switch vpn.status {
        case .error, .connected: return .red
        case .connecting: return .orange
        case .disconnected, .disconnecting: return .accentColor
        }
    }

    // MARK: - Actions

    private func actionButtonTapped() {
        switch vpn.status {
        case .connected, .connecting:
            vpn.disconnect()
        case .disconnected, .error:
            var missingFields: [String] = []
            if settings.vpnHost.isEmpty { missingFields.append("Organization Domain") }
            if settings.vpnID.isEmpty { missingFields.append("Username") }
            if settings.vpnPassword.isEmpty { missingFields.append("Password") }
            if settings.vpnPasscode.isEmpty { missingFields.append("Passcode (2FA)") }

            if !missingFields.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Missing Configuration"
                alert.informativeText = "Please set the following required information in Settings:\n\n"
                    + missingFields.map { "• \($0)" }.joined(separator: "\n")
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                }
                return
            }

            vpn.connect()
        case .disconnecting:
            break // Button is disabled, ignore
        }
    }
}

// MARK: - Switch tile

/// One of the four switches. Compact = label + caption + switch in a row;
/// expanded = the same thing as a card, matching the dashboard's grid.
/// One switch, described as data so the compact list and the expanded grid can
/// share the same definitions (and so the compact list can put hairlines between
/// rows).
private struct SwitchSpec: Identifiable {
    let id: String
    let title: String
    let caption: String
    let isOn: Binding<Bool>
    var enabled = true
    var busy = false
}

private struct SwitchTile: View {
    let spec: SwitchSpec
    var expanded = false

    var body: some View {
        if expanded {
            // Matches the compact list: label left, switch right, caption under
            // the label (the switch used to sit above the title).
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(spec.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Toggle("", isOn: spec.isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                captionView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
            .disabled(!spec.enabled)
            .opacity(spec.enabled ? 1 : 0.55)
        } else {
            // Fills its share of the window so the rows are spread evenly, and
            // pads the label so the switch lands on a shared right edge instead
            // of wherever the label happens to end.
            Toggle(isOn: spec.isOn) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spec.title)
                            .font(.system(size: 12, weight: .medium))
                        captionView
                    }
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!spec.enabled)
            .opacity(spec.enabled ? 1 : 0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var captionView: some View {
        HStack(spacing: 4) {
            if spec.busy {
                ProgressView().controlSize(.mini)
            }
            Text(spec.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? 2 : 1)
        }
    }
}

// MARK: - Stat card

/// A dashboard card. `actionLabel` puts a small bordered button in the header
/// (the "Test All" affordance) so the card's content stays purely informational.
private struct StatCard<Content: View>: View {
    let title: String
    /// Cards in a row share a floor height so their edges line up even when
    /// their content differs in length.
    var minHeight: CGFloat = 0
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var actionEnabled = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let actionLabel, let action {
                    Button(action: action) {
                        Text(actionLabel)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!actionEnabled)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
    }
}

/// Two-bar up/down meter for the traffic card (upload above download, scaled to
/// the larger of the two so a single request still shows shape). The colours
/// match the ↑/↓ arrows in the card, which is what labels the bars.
private struct TrafficBar: View {
    let up: Int
    let down: Int

    var body: some View {
        let scale = max(up, down, 1)
        VStack(alignment: .leading, spacing: 3) {
            bar(value: up, scale: scale, color: .blue)
            bar(value: down, scale: scale, color: .green)
        }
        .padding(.top, 2)
    }

    private func bar(value: Int, scale: Int, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Tinted per direction, so two empty tracks still say "up" and
                // "down" instead of reading as two grey placeholders.
                Capsule().fill(color.opacity(0.16))
                Capsule()
                    .fill(color.opacity(0.75))
                    .frame(
                        width: value <= 0
                            ? 0
                            : max(3, geometry.size.width * CGFloat(value) / CGFloat(scale))
                    )
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let showSettings = Notification.Name("showSettings")
}

// MARK: - Preview

#if DEBUG
struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
            .frame(width: 380, height: 520)
    }
}
#endif
