import PoscarCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 540)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("alwaysLoadImages") private var alwaysLoadImages = false
    @AppStorage("showMascot") private var showMascot = true

    @State private var recordingHotKey = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("App") {
                Toggle("Show in Dock", isOn: $model.showInDock)
                Toggle("Show in menu bar with unread count", isOn: $model.showInMenuBar)
                Toggle("Show Žuća in background?", isOn: $showMascot)
                LabeledContent("Show or hide Pošćar from anywhere") {
                    HStack {
                        if recordingHotKey {
                            ShortcutRecorder { sequence in
                                recordingHotKey = false
                                guard let sequence else { return }
                                model.toggleHotKey = sequence.chords.first
                            }
                        } else {
                            Button {
                                recordingHotKey = true
                            } label: {
                                if let chord = model.toggleHotKey {
                                    KeyHint(sequence: KeySequence([chord]), prominent: true)
                                } else {
                                    Text("Record").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if model.toggleHotKey != nil {
                            Button("Clear") { model.toggleHotKey = nil }.buttonStyle(.link)
                        }
                    }
                }
                if let error = model.hotKeyError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Notifications") {
                LabeledContent("New mail notifications") {
                    HStack {
                        switch model.notificationsAllowed {
                        case true?: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case false?: Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                        case nil: Text("Checking…").foregroundStyle(.secondary)
                        }
                        Button("Open System Settings") {
                            let id = Bundle.main.bundleIdentifier ?? ""
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Text("Turn notifications on or off per account in Accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { model.notifications.refreshStatus() }
            Section("Privacy") {
                Toggle("Always load remote images", isOn: $alwaysLoadImages)
                Text("Remote images can tell senders when you opened a message. When off, press I to load them for one conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Mail cache") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MailDatabase.defaultURL])
                    }
                }
                Text("Headers of all mail and bodies of the last 90 days are kept locally for speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var addingAccount = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.accounts) { account in
                        HStack {
                            Circle().fill(account.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(account.name)
                                Text(account.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(account.id)
                    }
                    .onMove { model.moveAccount(from: $0, to: $1) }
                }
                Divider()
                HStack {
                    Button {
                        addingAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 220)
            Divider()
            if let id = selection, let account = model.account(id) {
                AccountEditor(account: account)
                    .id(id)
            } else {
                Text("Select an account").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $addingAccount) {
            AccountSetupView { addingAccount = false }
                .padding(20)
                .frame(width: 480)
        }
        .onAppear { selection = selection ?? model.accounts.first?.id }
    }
}

private struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: Account
    @State private var password = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmingRemoval = false
    @State private var checkSteps: [ConnectionStep] = []
    @State private var isChecking = false

    init(account: Account) {
        _draft = State(initialValue: account)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Your name", text: $draft.name)
                LabeledContent("Email", value: draft.email)
                LabeledContent("Color") {
                    AccountColorPicker(colorIndex: $draft.colorIndex, customColor: $draft.customColor)
                }
                // Colour is cosmetic, so it applies right away instead of waiting for Save.
                .onChange(of: draft.colorIndex) { model.setColor(of: draft.id, index: draft.colorIndex, custom: draft.customColor) }
                .onChange(of: draft.customColor) { model.setColor(of: draft.id, index: draft.colorIndex, custom: draft.customColor) }
                Toggle("Notifications for new mail", isOn: $draft.notificationsEnabled)
            }
            Section("Signature (Markdown)") {
                TextEditor(text: $draft.signature)
                    .font(.body)
                    .frame(height: 80)
            }
            Section("Sign-in") {
                if draft.usesGoogleOAuth {
                    LabeledContent("Method") { Label("Google sign-in", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                    Button("Sign in with Google again…") { googleSignIn() }
                } else {
                    LabeledContent("Method", value: draft.isGmail ? "App Password" : "Password")
                    if draft.isGmail, GoogleClient.config.isConfigured {
                        Button("Switch to Google sign-in…") { googleSignIn() }
                    }
                    SecureField("New password", text: $password, prompt: Text("Leave empty to keep"))
                }
                LabeledContent("IMAP", value: "\(draft.imap.host):\(draft.imap.port)")
                LabeledContent("SMTP", value: "\(draft.smtp.host):\(draft.smtp.port) (\(draft.smtp.security == .tls ? "TLS" : "STARTTLS"))")
            }
            Section("Connection") {
                if let error = model.accountErrors[draft.id], checkSteps.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(checkSteps) { step in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: step.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(step.succeeded ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Button("Check Connection") { checkConnection() }
                        .disabled(isChecking)
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Remove Account…", role: .destructive) { confirmingRemoval = true }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(draft.email)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                Task { await model.removeAccount(draft.id) }
            }
        } message: {
            Text("Local mail and the saved password are deleted. Nothing changes on the server.")
        }
    }

    private func checkConnection() {
        isChecking = true
        checkSteps = []
        Task {
            checkSteps = await model.checkConnection(draft)
            isChecking = false
        }
    }

    private func googleSignIn() {
        isSaving = true
        error = nil
        Task {
            do {
                try await model.signInWithGoogle(draft)
                draft.authMethod = .googleOAuth
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                try await model.updateAccount(draft, newPassword: password.isEmpty ? nil : password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    @State private var preset: AccountPreset = .gmail
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var smtpSecurity: ConnectionSecurity = .tls
    @State private var isWorking = false
    @State private var error: String?
    @State private var usesAppPassword = false

    private var offersGoogleSignIn: Bool {
        preset == .gmail && GoogleClient.config.isConfigured && !usesAppPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.title2.bold())
            Picker("Provider", selection: $preset) {
                ForEach(AccountPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)

            if offersGoogleSignIn {
                googleSignIn
            } else {
                passwordForm
            }
        }
    }

    private var googleSignIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your Google account in the browser and allow Pošćar to read and send mail. No password is stored.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                Button("Use an App Password instead") { usesAppPassword = true }
                    .buttonStyle(.link)
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…").foregroundStyle(.secondary)
                }
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .opacity(model.accounts.isEmpty ? 0 : 1)
                Button {
                    signInWithGoogle()
                } label: {
                    Label("Sign in with Google", systemImage: "globe")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
    }

    private func signInWithGoogle() {
        error = nil
        isWorking = true
        Task {
            do {
                try await model.addGoogleAccount()
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                SecureField("Password", text: $password)
                Text(preset.passwordHelp).font(.caption).foregroundStyle(.secondary)
                if preset == .gmail {
                    Link("Create a Google App Password", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                        .font(.caption)
                }
                if preset == .other {
                    TextField("Username", text: $username, prompt: Text("Same as email"))
                    HStack {
                        TextField("IMAP server", text: $imapHost, prompt: Text("imap.example.com"))
                        TextField("Port", text: $imapPort).frame(width: 70)
                    }
                    HStack {
                        TextField("SMTP server", text: $smtpHost, prompt: Text("smtp.example.com"))
                        TextField("Port", text: $smtpPort).frame(width: 70)
                    }
                    Picker("SMTP security", selection: $smtpSecurity) {
                        Text("TLS (465)").tag(ConnectionSecurity.tls)
                        Text("STARTTLS (587)").tag(ConnectionSecurity.startTLS)
                    }
                    .onChange(of: smtpSecurity) { _, security in
                        smtpPort = security == .tls ? "465" : "587"
                    }
                }
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }

            HStack {
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").foregroundStyle(.secondary)
                }
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .opacity(model.accounts.isEmpty ? 0 : 1)
                Button("Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
            }
        }
    }

    private func signIn() {
        error = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard EmailAddress(email: trimmedEmail).isValid else {
            error = "Enter a valid email address"
            return
        }
        let imap: ServerEndpoint
        let smtp: ServerEndpoint
        if let presetIMAP = preset.imap, let presetSMTP = preset.smtp {
            imap = presetIMAP
            smtp = presetSMTP
        } else {
            guard let imapPortNumber = Int(imapPort), let smtpPortNumber = Int(smtpPort), !imapHost.isEmpty, !smtpHost.isEmpty else {
                error = "Enter IMAP and SMTP servers and ports"
                return
            }
            imap = ServerEndpoint(host: imapHost.trimmingCharacters(in: .whitespaces), port: imapPortNumber, security: .tls)
            smtp = ServerEndpoint(host: smtpHost.trimmingCharacters(in: .whitespaces), port: smtpPortNumber, security: smtpSecurity)
        }

        let account = Account(
            kind: preset.kind,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedEmail : name,
            email: trimmedEmail,
            username: username.isEmpty ? trimmedEmail : username,
            imap: imap,
            smtp: smtp,
            colorIndex: model.accounts.count % AccountPalette.colors.count
        )
        // App passwords are often pasted with spaces ("abcd efgh ijkl mnop").
        let cleanedPassword = preset == .gmail ? password.replacingOccurrences(of: " ", with: "") : password

        isWorking = true
        Task {
            do {
                try await model.addAccount(account, password: cleanedPassword)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Swatches plus a custom hex colour, used for the account's avatar tint and sidebar dot.
struct AccountColorPicker: View {
    @Binding var colorIndex: Int
    @Binding var customColor: String?
    @State private var hexText = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AccountPalette.displayOrder, id: \.self) { index in
                    swatch(AccountPalette.colors[index], selected: customColor == nil && colorIndex == index) {
                        colorIndex = index
                        customColor = nil
                        hexText = ""
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Custom").foregroundStyle(.secondary)
                TextField("", text: $hexText, prompt: Text("#f97316"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit(applyHex)
                    .onChange(of: hexText) { _, _ in applyHex() }
                ColorPicker("", selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .onAppear { hexText = customColor ?? "" }
    }

    private func swatch(_ color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private func applyHex() {
        let value = hexText.trimmingCharacters(in: .whitespaces)
        guard Color(hex: value) != nil else { return }
        customColor = value.hasPrefix("#") ? value.lowercased() : "#" + value.lowercased()
    }

    /// The system colour well, kept in sync with the hex field.
    private var customBinding: Binding<Color> {
        Binding {
            customColor.flatMap(Color.init(hex:)) ?? AccountPalette.colors[colorIndex % AccountPalette.colors.count]
        } set: { color in
            guard let hex = color.hexString else { return }
            customColor = hex
            hexText = hex
        }
    }
}
