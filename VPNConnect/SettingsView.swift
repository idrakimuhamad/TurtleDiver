import SwiftUI
import AppKit

// MARK: - Root Settings View

/// The Settings window: a sidebar in the order defined by `SettingsCatalog`,
/// and one pane at a time beside it.
///
/// It is a `NavigationSplitView` rather than the previous push-navigation
/// stack — settings are somewhere you jump between, not a hierarchy you descend
/// into, and the old stack forgot where you had been every time the window was
/// reopened. The selected pane is persisted instead (`settingsPane`).
struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var engine = EngineController.shared
    @ObservedObject private var bridge = ProfileModelBridge.shared

    @State private var selection: SettingsRoute
    @State private var query = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Deep links (the menu bar's Dashboard item) preselect a pane; otherwise
    /// the pane the user had open last time wins.
    init(initialRoute: SettingsRoute? = nil) {
        _selection = State(initialValue: initialRoute
            ?? SettingsCatalog.route(forStoredValue: SettingsManager.shared.settingsPane))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 560)
        .onChange(of: selection) { _, newValue in
            settings.settingsPane = newValue.rawValue
        }
        .onChange(of: columnVisibility) { _, newValue in
            // The sidebar *is* the navigation here, and dragging the divider
            // shut used to hide it with no obvious way back (System Settings
            // does not let you lose its sidebar either).
            if newValue != .all { columnVisibility = .all }
        }
    }

    // MARK: Sidebar

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SettingsItem] { SettingsCatalog.filter(query) }

    private var sidebar: some View {
        List(selection: $selection) {
            if isSearching {
                if searchResults.isEmpty {
                    Text("No settings match “\(query.trimmingCharacters(in: .whitespaces))”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(searchResults) { sidebarRow($0) }
                }
            } else {
                ForEach(SettingsCatalog.groups) { group in
                    Section {
                        ForEach(SettingsCatalog.items(in: group)) { sidebarRow($0) }
                    } header: {
                        // `listSectionSpacing` is iOS-only; padding the header
                        // is what gives the groups room to breathe on macOS.
                        Text(group.title)
                            .padding(.top, 10)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // Outermost: `.searchable(placement: .sidebar)` rebuilds the sidebar's
        // chrome, and the width preference is only read from the view that ends
        // up as the column's content.
        .navigationSplitViewColumnWidth(min: SettingsSidebar.minWidth,
                                        ideal: SettingsSidebar.idealWidth,
                                        max: SettingsSidebar.maxWidth)
    }

    private func sidebarRow(_ item: SettingsItem) -> some View {
        Label {
            Text(item.title)
                .padding(.leading, 1)
        } icon: {
            SettingsIconChip(symbol: item.symbol, tint: item.tint, size: 21)
        }
        .padding(.vertical, 3)
        .tag(item.route)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(alignment: .center, spacing: 7) {
                Circle()
                    .fill(engine.engineRunning ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.engineRunning ? "Proxy engine running" : "Proxy engine stopped")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("v\(appVersion) · \(ProfileManager.shared.activeProfile.name)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            // Holds the column open at the minimum even though SwiftUI ignores
            // the explicit width request — the split view sizes the sidebar
            // from its content instead.
            .frame(minWidth: SettingsSidebar.footerMinWidth, alignment: .leading)
            .padding(.horizontal, SettingsSidebar.footerPadding)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        // The spacer is invisible, but it holds the titlebar's height constant
        // for the panes that declare no toolbar item of their own — see
        // `SettingsToolbarSpacer`.
        //
        // On macOS 26 every toolbar item is given a glass capsule background by
        // default, which turns a 1×30 pt spacer into two hairlines sitting in
        // the titlebar. `sharedBackgroundVisibility(.hidden)` is the documented
        // way to switch that capsule off; it is macOS 26-only, and so is the
        // capsule, hence the branch.
        if #available(macOS 26.0, *) {
            paneContent.toolbar {
                ToolbarItem(placement: .navigation) { SettingsToolbarSpacer() }
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            paneContent.toolbar {
                ToolbarItem(placement: .navigation) { SettingsToolbarSpacer() }
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        let item = SettingsCatalog.item(for: selection)
        switch selection {
        case .vpn:
            VPNConfigurationView()
        case .appearance:
            AppearanceView()
        case .history:
            HistoryView()
        case .setup:
            SetupView()
        case .advanced:
            AdvancedView()
        case .dashboard, .policies, .rules, .routing, .ruleSets, .profiles:
            // These panes own their tables and toolbars; they only need the
            // shared header above them.
            SettingsListPane(title: item.title, subtitle: item.subtitle) {
                switch selection {
                case .dashboard: DashboardView()
                case .policies: PoliciesView()
                case .rules: RulesEditorView()
                case .routing: RoutingView()
                case .ruleSets: RuleSetsView()
                default: ProfilesView()
                }
            }
        }
    }
}

// MARK: - VPN pane

/// Credentials, software token and split tunneling for the active profile.
///
/// This pane keeps the explicit Save/Revert model: the credentials land in the
/// Keychain, and writing a half-typed password on every keystroke would be both
/// noisy and a way to lose the previous one.
struct VPNConfigurationView: View {
    @ObservedObject private var settings = SettingsManager.shared

    @State private var draft = VPNConfigurationDraft()
    @State private var loaded = VPNConfigurationDraft()
    @State private var pickedTokenURL: URL?
    @State private var showFilePicker = false

    var body: some View {
        SettingsPane(title: "VPN", subtitle: "Credentials, software token and split tunneling for the active profile") {
            credentialsGroup
            tokenGroup
            routingGroup
        }
        // Pinned, not part of the scrolling content: the credentials are the one
        // thing here that does not save itself, so Save must never be a scroll
        // away from view.
        .safeAreaInset(edge: .bottom) {
            SettingsSaveBar(isDirty: draft.differs(from: loaded), save: save, revert: revert)
        }
        .onAppear(perform: load)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                draft.tokenFilePath = url.path
                pickedTokenURL = url
            }
        }
    }

    private var credentialsGroup: some View {
        SettingsCard("Credentials", note: "Passwords are kept in your login Keychain, not in the app's preferences.") {
            SettingsRow(label: "Organization domain", caption: "Host name of the VPN gateway") {
                TextField("vpn.company.com", text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 230)
            }
            SettingsRow(label: "Username") {
                TextField("username", text: $draft.username)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 230)
            }
            SettingsRow(label: "VPN password") {
                SettingsSecureField(prompt: "Password", text: $draft.password)
            }
            SettingsRow(label: "Passcode", caption: "If your gateway asks for two credentials: the token from the software token file, then the password") {
                SettingsSecureField(prompt: "Passcode or token", text: $draft.passcode)
            }
            SettingsRow(label: "Administrator password", caption: "Used for sudo: running the VPN helper and changing the system proxy", isLast: true) {
                SettingsSecureField(prompt: "Admin password", text: $draft.adminPassword)
            }
        }
    }

    private var tokenGroup: some View {
        SettingsCard("Software token", note: "stoken reads this file to generate the six-digit passcode for each connection.") {
            SettingsRow(label: "Token file (.stid)",
                        caption: draft.tokenFilePath.isEmpty ? "No token file selected" : nil,
                        isLast: true) {
                HStack(spacing: 8) {
                    Text(draft.tokenFilePath.isEmpty
                         ? "—"
                         : (draft.tokenFilePath as NSString).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(draft.tokenFilePath.isEmpty ? Color.secondary.opacity(0.6) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(draft.tokenFilePath)
                    Button("Choose…") { showFilePicker = true }
                        .controlSize(.small)
                    if !draft.tokenFilePath.isEmpty {
                        Button("Clear") {
                            draft.tokenFilePath = ""
                            pickedTokenURL = nil
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var routingGroup: some View {
        SettingsCard("Traffic routing",
                      note: "Choose how much of your traffic goes through the VPN. The proxy engine routes whatever the VPN does not take.") {
            // Two described tiles instead of a "Mode" segmented control: the
            // labels alone ("Standard VPN" / "Split tunneling") name the
            // options without saying what either one does.
            HStack(alignment: .top, spacing: 10) {
                ForEach(TrafficMode.allCases) { mode in
                    SettingsChoiceTile(
                        icon: mode.icon,
                        title: mode.title,
                        detail: mode.detail,
                        isSelected: draft.useTunneling == mode.isOn,
                        choose: { draft.useTunneling = mode.isOn }
                    )
                }
            }
            .padding(.horizontal, SettingsStyle.rowPaddingH)
            .padding(.vertical, SettingsStyle.rowPaddingV)

            if draft.useTunneling {
                VStack(alignment: .leading, spacing: 6) {
                    Text("vpn-slice targets")
                        .font(.system(size: 12.5))
                    Text("One domain or IP range per line")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $draft.sliceURLsText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 104)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                }
                .padding(.horizontal, SettingsStyle.rowPaddingH)
                .padding(.vertical, SettingsStyle.rowPaddingV)
            }
        }
    }

    // MARK: Load / save

    private func load() {
        let current = VPNConfigurationDraft(
            host: settings.vpnHost,
            username: settings.vpnID,
            password: settings.vpnPassword,
            passcode: settings.vpnPasscode,
            adminPassword: settings.adminPassword,
            tokenFilePath: settings.stokenTokenFilePath,
            useTunneling: settings.useTunneling,
            sliceURLsText: settings.vpnSliceURLs.joined(separator: "\n")
        )
        draft = current
        loaded = current
        pickedTokenURL = nil
    }

    private func revert() {
        draft = loaded
        pickedTokenURL = nil
    }

    private func save() {
        settings.vpnHost = draft.host
        settings.vpnID = draft.username
        settings.vpnPassword = draft.password
        settings.vpnPasscode = draft.passcode
        settings.adminPassword = draft.adminPassword

        // The bookmark only exists for a URL that came from the file importer;
        // a path typed or inherited from before is stored as a path alone.
        if draft.tokenFilePath.isEmpty {
            settings.stokenTokenFilePath = ""
            settings.stokenTokenBookmarkData = nil
        } else if let url = pickedTokenURL {
            settings.updateStokenTokenURL(url)
        } else {
            settings.stokenTokenFilePath = draft.tokenFilePath
        }

        settings.useTunneling = draft.useTunneling
        settings.vpnSliceURLs = draft.sliceURLList

        loaded = draft
        pickedTokenURL = nil
    }
}

// MARK: - Appearance pane

struct AppearanceView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        SettingsPane(title: "Appearance", subtitle: "Follow the system, or pin a light or dark look") {
            SettingsCard("Theme", note: nil) {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        ThemeChoiceTile(
                            theme: theme,
                            isSelected: settings.theme == theme,
                            choose: { settings.theme = theme }
                        )
                    }
                }
                .padding(12)
            }
        }
    }
}

/// A miniature window rendered in the theme it selects, so the choice is a
/// picture rather than a word.
private struct ThemeChoiceTile: View {
    let theme: AppTheme
    let isSelected: Bool
    let choose: () -> Void

    @Environment(\.colorScheme) private var ambientScheme

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                preview
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                    Text(theme.displayName)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.10),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(theme == .system ? "Follow the macOS appearance" : "Always use the \(theme.displayName.lowercased()) look")
    }

    /// Explicit colours rather than `Color.primary` / dynamic `NSColor`s: the
    /// tile has to draw the *other* theme, which the ambient environment knows
    /// nothing about.
    private var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .system: return ambientScheme == .dark
        }
    }

    private var pageBackground: Color { isDark ? Color(white: 0.13) : Color(white: 0.99) }
    private var barColor: Color { isDark ? Color(white: 1, opacity: 0.10) : Color(white: 0, opacity: 0.10) }
    private var lineColor: Color { isDark ? Color(white: 1, opacity: 0.22) : Color(white: 0, opacity: 0.16) }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color.red.opacity(0.75)).frame(width: 3.5, height: 3.5)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 3.5, height: 3.5)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 3.5, height: 3.5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(barColor)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.green.opacity(0.8))
                    .frame(height: 13)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(lineColor)
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(lineColor)
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(lineColor)
                    .frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 76)
        .background(pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .allowsHitTesting(false)
    }
}

// MARK: - History pane

struct HistoryView: View {
    @State private var history: [ConnectionAttempt] = []
    @State private var showClearAlert = false
    @State private var selectedAttempt: ConnectionAttempt?

    var body: some View {
        SettingsPane(title: "History", subtitle: "Past connection attempts and the log of each one") {
            if history.isEmpty {
                SettingsCard {
                    VStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("No connection attempts yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("The result of every connect shows up here, with its log.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }
            } else {
                SettingsCard("Attempts (\(history.count))") {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, attempt in
                        Button {
                            selectedAttempt = attempt
                        } label: {
                            SettingsRow(label: attempt.host,
                                        caption: Self.formattedDate(attempt.timestamp),
                                        isLast: index == history.count - 1,
                                        controlWidth: 150) {
                                HStack(spacing: 10) {
                                    Spacer(minLength: 0)
                                    SettingsPill(text: SettingsDisplay.connectionStatus(attempt.status).title, tone: Self.tone(for: attempt.status))
                                    Text(attempt.duration.map { Self.formattedDuration($0) } ?? "—")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open Log") { selectedAttempt = attempt }
                            Divider()
                            Button("Delete", role: .destructive) { delete(attempt) }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !history.isEmpty {
                    Button(role: .destructive) {
                        showClearAlert = true
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .help("Delete every recorded attempt")
                }
            }
        }
        .alert("Clear History", isPresented: $showClearAlert) {
            Button("Clear", role: .destructive) {
                ConnectionHistoryManager.shared.clearHistory()
                history = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all \(history.count) recorded connection attempts?")
        }
        .sheet(item: $selectedAttempt) { attempt in
            ConnectionDetailView(attempt: attempt)
        }
        .onAppear {
            history = ConnectionHistoryManager.shared.getHistory()
        }
    }

    private func delete(_ attempt: ConnectionAttempt) {
        ConnectionHistoryManager.shared.deleteAttempt(id: attempt.id)
        history = ConnectionHistoryManager.shared.getHistory()
    }

    /// Bridges the pure status mapping to the pill's palette.
    static func tone(for status: String) -> SettingsPill.Tone {
        switch SettingsDisplay.connectionStatus(status).tone {
        case .ok: return .ok
        case .warn: return .warn
        case .error: return .error
        case .neutral: return .neutral
        }
    }

    static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "—"
    }
}

// MARK: - Connection detail (sheet)

struct ConnectionDetailView: View {
    let attempt: ConnectionAttempt

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                SettingsPaneHeader(title: attempt.host,
                                   subtitle: HistoryView.formattedDate(attempt.timestamp))
                Spacer(minLength: 12)
                SettingsPill(text: SettingsDisplay.connectionStatus(attempt.status).title, tone: HistoryView.tone(for: attempt.status))
            }
            .padding(.horizontal, SettingsStyle.panePadding)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsCard("Attempt") {
                        SettingsRow(label: "Host") {
                            SettingsMonoValue(value: attempt.host)
                        }
                        SettingsRow(label: "Started") {
                            Text(HistoryView.formattedDate(attempt.timestamp))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        SettingsRow(label: "Duration", isLast: true) {
                            Text(attempt.duration.map { HistoryView.formattedDuration($0) } ?? "—")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsCard("Log") {
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView {
                                Text(attempt.logOutput.isEmpty ? "(no output)" : attempt.logOutput)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 260)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            )

                            HStack {
                                Text("\(attempt.logOutput.components(separatedBy: .newlines).count) lines")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button(didCopyLog ? "Copied" : "Copy Log") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(attempt.logOutput, forType: .string)
                                    didCopyLog = true
                                }
                                .controlSize(.small)
                                .disabled(attempt.logOutput.isEmpty)
                            }
                        }
                        .padding(SettingsStyle.rowPaddingH)
                    }
                }
                .padding(.horizontal, SettingsStyle.panePadding)
                .padding(.vertical, 14)
                .frame(maxWidth: SettingsStyle.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: 620, height: 540)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
