import SwiftUI
import UniformTypeIdentifiers
import JavaScriptCore

// MARK: - Navigation Route

enum SettingsRoute: Hashable {
    case configuration
    case appearance
    case proxy
    case history
    case proxyEditor(UUID)
    case connectionDetail(UUID)
}

// MARK: - Root Settings View

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            SettingsMenuView()
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .configuration:
                        ConfigurationView()
                    case .appearance:
                        AppearanceView()
                    case .proxy:
                        ProxySettingsView()
                    case .history:
                        HistoryView()
                    case .proxyEditor(let id):
                        if let config = SettingsManager.shared.proxyConfigurations.first(where: { $0.id == id }) {
                            ProxyEditorView(config: config)
                        }
                    case .connectionDetail(let id):
                        if let attempt = ConnectionHistoryManager.shared.getHistory().first(where: { $0.id == id }) {
                            ConnectionDetailView(attempt: attempt)
                        }
                    }
                }
        }
        .frame(width: 600, height: 600)
    }
}

// MARK: - Settings Menu

struct SettingsMenuView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: SettingsRoute.configuration) {
                    Label("VPN Configuration", systemImage: "network.badge.shield.half.filled")
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 4)
                }
                
                NavigationLink(value: SettingsRoute.appearance) {
                    Label("Appearance", systemImage: "paintbrush")
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("General")
            }
            
            Section {
                NavigationLink(value: SettingsRoute.proxy) {
                    Label("Proxy (PAC)", systemImage: "point.connected.arrow.up.forward")
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Network")
            }
            
            Section {
                NavigationLink(value: SettingsRoute.history) {
                    Label("Connection History", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Advanced")
            }
        }
        .listStyle(.inset)
        .navigationTitle("Settings")
    }
}

// MARK: - Configuration View

struct ConfigurationView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var passcode: String = ""
    @State private var showPassword = false
    @State private var showPasscode = false
    @State private var stokenFilePath: String = ""
    @State private var useTunneling = false
    @State private var sliceURLs: String = ""
    @State private var showFilePicker = false
    @State private var showResetAlert = false
    
    var body: some View {
        Form {
            Section {
                TextField("Organization Domain", text: $host, prompt: Text("vpn.company.com"))
                TextField("Username", text: $username, prompt: Text("Enter username"))
                HStack {
                    if showPassword {
                        TextField("Password", text: $password, prompt: Text("Enter password"))
                    } else {
                        SecureField("Password", text: $password, prompt: Text("Enter password"))
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Hide password" : "Show password")
                }
                HStack {
                    if showPasscode {
                        TextField("Passcode (2FA)", text: $passcode, prompt: Text("Enter passcode or token"))
                    } else {
                        SecureField("Passcode (2FA)", text: $passcode, prompt: Text("Enter passcode or token"))
                    }
                    Button(action: { showPasscode.toggle() }) {
                        Image(systemName: showPasscode ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showPasscode ? "Hide passcode" : "Show passcode")
                }
            } header: {
                Text("Authentication Details")
                    .font(.system(size: 12, weight: .regular))
                    .textCase(.uppercase)
            }
            
            Section {
                HStack(spacing: 12) {
                    TextField("Stoken File (.stid)", text: $stokenFilePath, prompt: Text("~/token.stid"))
                    Button("Browse...") {
                        showFilePicker = true
                    }
                    .controlSize(.regular)
                }
            } header: {
                Text("Configuration")
                    .font(.system(size: 12, weight: .regular))
                    .textCase(.uppercase)
            }
            
            Section {
                Picker("Routing", selection: $useTunneling) {
                    Text("Standard VPN").tag(false)
                    Text("Split Tunneling (vpn-slice)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 4)
                
                if useTunneling {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Slice URLs (One per line)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        TextEditor(text: $sliceURLs)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120)
                    }
                }
            } header: {
                Text("Traffic Routing")
                    .font(.system(size: 12, weight: .regular))
                    .textCase(.uppercase)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .navigationTitle("Configuration")
        
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.return)
            }
            
            ToolbarItemGroup(placement: .automatic) {
                Button("Reset", role: .destructive) {
                    showResetAlert = true
                }
            }
        }
        .alert("Reset All Settings?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                Task {
                    await SettingsManager.shared.resetAllSettings()
                    loadSettings()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all saved configurations. This action cannot be undone.")
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                stokenFilePath = url.path
                SettingsManager.shared.updateStokenTokenURL(url)
            }
        }
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        host = settings.vpnHost
        username = settings.vpnID
        password = settings.vpnPassword
        passcode = settings.vpnPasscode
        stokenFilePath = settings.stokenTokenFilePath
        useTunneling = settings.useTunneling
        sliceURLs = settings.vpnSliceURLs.joined(separator: "\n")
    }
    
    private func saveSettings() {
        settings.vpnHost = host
        settings.vpnPassword = password
        settings.vpnID = username
        settings.vpnPasscode = passcode
        settings.stokenTokenFilePath = stokenFilePath
        settings.useTunneling = useTunneling
        let urls = sliceURLs.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        settings.vpnSliceURLs = urls
        dismiss()
    }
}

// MARK: - Appearance View

struct AppearanceView: View {
    @ObservedObject private var settings = SettingsManager.shared
    
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.theme) {
                    Text("System Default").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
                    .font(.system(size: 12, weight: .regular))
                    .textCase(.uppercase)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .navigationTitle("Appearance")
    }
}

// MARK: - History View

struct HistoryView: View {
    @State private var history: [ConnectionAttempt] = []
    @State private var showClearAlert = false
    @State private var selectedAttemptID: UUID? = nil
    @State private var showDetail = false
    
    var body: some View {
        Form {
            if history.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 36))
                            .foregroundColor(.tertiary)
                        Text("No connection history")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                Section {
                    ForEach(history) { attempt in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(attempt.host)
                                    .font(.system(size: 13, weight: .medium))
                                
                                Text(formattedDate(attempt.timestamp))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(attempt.status)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(statusColor(attempt.status))
                            
                            if let duration = attempt.duration {
                                Text(formattedDuration(duration))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 65, alignment: .trailing)
                            } else {
                                Text("--")
                                    .font(.system(size: 11))
                                    .foregroundColor(.tertiary)
                                    .frame(width: 65, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAttemptID = attempt.id
                            showDetail = true
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                ConnectionHistoryManager.shared.deleteAttempt(id: attempt.id)
                                history = ConnectionHistoryManager.shared.getHistory()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("History (\(history.count))")
                        .font(.system(size: 12, weight: .regular))
                        .textCase(.uppercase)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !history.isEmpty {
                    Button(role: .destructive) {
                        showClearAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear History")
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
            Text("Are you sure you want to clear all connection history?")
        }
        .sheet(isPresented: $showDetail) {
            if let id = selectedAttemptID,
               let attempt = history.first(where: { $0.id == id }) {
                ConnectionDetailView(attempt: attempt)
            }
        }
        .onAppear {
            history = ConnectionHistoryManager.shared.getHistory()
        }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "--"
    }
    
    private func statusColor(_ status: String) -> Color {
        let lower = status.lowercased()
        if lower.contains("connected") {
            return .green
        } else if lower.contains("error") || lower.contains("failed") {
            return .red
        }
        return .primary
    }
}

// MARK: - Proxy Settings View

struct ProxySettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var proxyConfigs: [ProxyConfiguration] = []
    @State private var showEditor = false
    @State private var editingConfigID: UUID? = nil
    @State private var showAddAlert = false
    @State private var newProxyName: String = ""
    @State private var showDeleteAlert = false
    @State private var deletingConfigID: UUID? = nil
    
    var body: some View {
        Form {
            Section {
                Toggle("Use Proxy for VPN Connection", isOn: $settings.useProxy)
                    .padding(.vertical, 4)
                
                if settings.useProxy {
                    Picker("Select Proxy", selection: $settings.selectedProxyID) {
                        Text("(None)").tag(nil as UUID?)
                        ForEach(proxyConfigs) { config in
                            Text(config.name).tag(config.id as UUID?)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            if !proxyConfigs.isEmpty {
                Section {
                    ForEach(proxyConfigs) { config in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.name)
                                    .font(.system(size: 13))
                                if let path = config.pacFilePath {
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else if config.pacCode != nil {
                                    Text("Custom PAC Code")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            if settings.selectedProxyID == config.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.selectedProxyID = config.id
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deletingConfigID = config.id
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Proxy List")
                        .font(.system(size: 12, weight: .regular))
                        .textCase(.uppercase)
                }
            }
            
            Section {
                HStack(spacing: 12) {
                    Button("+ Add Proxy") {
                        showAddAlert = true
                    }
                    .controlSize(.regular)
                    
                    Button("Edit Selected") {
                        if let id = settings.selectedProxyID {
                            editingConfigID = id
                            showEditor = true
                        }
                    }
                    .controlSize(.regular)
                    .disabled(settings.selectedProxyID == nil)
                    
                    if proxyConfigs.isEmpty {
                        Spacer()
                        Text("Click + Add Proxy to create one")
                            .font(.system(size: 11))
                            .foregroundColor(.tertiary)
                    } else {
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .navigationTitle("Proxy Configuration")
        
        .onAppear {
            loadConfigs()
        }
        .alert("New Proxy Configuration", isPresented: $showAddAlert) {
            TextField("Proxy name", text: $newProxyName)
            Button("Create") {
                let name = newProxyName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let newConfig = ProxyConfiguration(name: name, isActive: false)
                SettingsManager.shared.addProxyConfiguration(newConfig)
                loadConfigs()
                editingConfigID = newConfig.id
                showEditor = true
                newProxyName = ""
            }
            Button("Cancel", role: .cancel) {
                newProxyName = ""
            }
        }
        .alert("Delete Proxy?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = deletingConfigID {
                    SettingsManager.shared.deleteProxyConfiguration(id: id)
                    loadConfigs()
                }
                deletingConfigID = nil
            }
            Button("Cancel", role: .cancel) {
                deletingConfigID = nil
            }
        } message: {
            if let id = deletingConfigID,
               let config = proxyConfigs.first(where: { $0.id == id }) {
                Text("Are you sure you want to delete \"\(config.name)\"?")
            }
        }
        .sheet(isPresented: $showEditor) {
            if let id = editingConfigID,
               let config = proxyConfigs.first(where: { $0.id == id }) {
                ProxyEditorView(config: config)
            }
        }
    }
    
    private func loadConfigs() {
        proxyConfigs = settings.proxyConfigurations
    }
}

// MARK: - Proxy Editor View

struct ProxyEditorView: View {
    let config: ProxyConfiguration
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var useFileSource = true
    @State private var filePath: String = ""
    @State private var pacCode: String = ""
    @State private var showFilePicker = false
    @State private var showValidationError = false
    @State private var validationError: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Enter proxy name", text: $name)
                }
                
                Section("Proxy Source") {
                    Picker("Source Type", selection: $useFileSource) {
                        Text("PAC File").tag(true)
                        Text("Inline PAC Code").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    
                    if useFileSource {
                        HStack {
                            TextField("Select a .pac file", text: $filePath)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .disabled(true)
                            
                            Button("Browse") {
                                showFilePicker = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        TextEditor(text: $pacCode)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 200)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.separatorColor, lineWidth: 1)
                            )
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Button("Save") {
                    saveConfig()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadConfig()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType(filenameExtension: "pac") ?? .plainText]) { result in
            if case .success(let url) = result {
                filePath = url.path
            }
        }
        .alert("Invalid PAC Code", isPresented: $showValidationError) {
            Button("OK") {}
        } message: {
            Text(validationError)
        }
    }
    
    private func loadConfig() {
        name = config.name
        if let path = config.pacFilePath {
            filePath = path
            useFileSource = true
        } else if let code = config.pacCode {
            pacCode = code
            useFileSource = false
        } else {
            useFileSource = true
        }
    }
    
    private func saveConfig() {
        var updatedConfig = config
        updatedConfig.name = name
        
        if useFileSource {
            let path = filePath
            if !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    updatedConfig.pacBookmarkData = data
                }
                updatedConfig.pacFilePath = path
            }
            updatedConfig.pacCode = nil
        } else {
            let code = pacCode.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !code.isEmpty else {
                validationError = "Please enter PAC script content or switch to file-based source."
                showValidationError = true
                return
            }
            
            if let error = validatePACCode(code) {
                validationError = "The PAC script contains a syntax error:\n\n\(error)"
                showValidationError = true
                return
            }
            
            updatedConfig.pacCode = code
            updatedConfig.pacFilePath = nil
            updatedConfig.pacBookmarkData = nil
        }
        
        SettingsManager.shared.updateProxyConfiguration(updatedConfig)
        dismiss()
    }
    
    private func validatePACCode(_ code: String) -> String? {
        let context = JSContext()!
        context.evaluateScript(code)
        if let exception = context.exception {
            let message = exception.toString() ?? "Unknown error"
            let line = exception.objectForKeyedSubscript("line")?.toString() ?? "?"
            let column = exception.objectForKeyedSubscript("column")?.toString() ?? "?"
            return "Line \(line), Column \(column): \(message)"
        }
        let checkResult = context.evaluateScript("typeof FindProxyForURL === 'function'")
        if checkResult?.toBool() != true {
            return "Missing required function: FindProxyForURL(url, host) must be defined."
        }
        return nil
    }
}

// MARK: - Connection Detail View

struct ConnectionDetailView: View {
    let attempt: ConnectionAttempt
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                DetailRow(label: "Host", value: attempt.host)
                DetailRow(label: "Date", value: formattedDate(attempt.timestamp))
                DetailRow(label: "Status", value: attempt.status)
                DetailRow(label: "Duration", value: attempt.duration.map { formattedDuration($0) } ?? "--")
            }
            
            Divider()
            
            Text("Log Output")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
            ScrollView {
                Text(attempt.logOutput)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 600, height: 500)
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func formattedDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "--"
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Color Extension

extension Color {
    static let separatorColor = Color(nsColor: .separatorColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
}
