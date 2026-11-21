import SwiftUI
import UIKit
import Security

struct BigVipUser: Codable, Identifiable {
    let username: String
    let role: String
    let expiresAt: Double
    let permanent: Bool
    let disabled: Bool
    var id: String { username }
}
struct BigVipReply: Codable {
    var token: String?
    var user: BigVipUser?
    var users: [BigVipUser]?
    var ip: String?
    var code: String?
    var passwordValid: Bool?
    var serverTime: Double?
}
enum BigVipAPIError: LocalizedError {
    case code(String)
    var errorDescription: String? {
        if case .code(let code) = self { return code }; return nil
    }
}
private enum BigVipKeychain {
    static let service = "bigvip.remote.session"
    static func read() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(entry as CFDictionary, nil)
    }
}

@MainActor final class BigVipAuth: ObservableObject {
    @Published var user: BigVipUser?
    @Published private(set) var isLocalKeySession = false
    private var sessionRevision = UUID()
    private let networkSession: URLSession
    init(session: URLSession = .shared) { networkSession = session }
    @Published var ip = ""
    @Published var message = ""
    @Published var busy = false
    @Published var serverURL = UserDefaults.standard.string(forKey: "bigvip.server") ?? "" {
        didSet {
            if oldValue != serverURL {
                UserDefaults.standard.set(serverURL, forKey: "bigvip.server")
                token = nil; BigVipKeychain.write(nil)
                if !isLocalKeySession { user = nil; sessionRevision = UUID() }
            }
        }
    }
    private var token = BigVipKeychain.read()
    private var verifiedServerTime: Double = 0
    private var verifiedUptime: TimeInterval = 0
    var serverNow: Double { verifiedServerTime + (ProcessInfo.processInfo.systemUptime - verifiedUptime) * 1000 }
    var remainingSeconds: Int { guard let user else { return 0 }; return max(0, Int((user.expiresAt - serverNow) / 1000)) }
    var isAdmin: Bool { !isLocalKeySession && user?.role == "admin" }

    @discardableResult
    func signInWithKey(_ key: String) -> Bool {
        guard key == "bigvip" else { message = "invalid_key"; return false }
        sessionRevision = UUID()
        token = nil; BigVipKeychain.write(nil)
        isLocalKeySession = true
        user = BigVipUser(username: "bigvip", role: "local", expiresAt: 0, permanent: true, disabled: false)
        ip = ""; message = "key_mode"; busy = false
        return true
    }

    func request(_ path: String, body: [String: Any]? = nil, requestID: String? = nil) async throws -> BigVipReply {
        guard !isLocalKeySession else { throw BigVipAPIError.code("admin_required") }
        let revision = sessionRevision
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { throw BigVipAPIError.code("server_required") }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let requestID { req.setValue(requestID, forHTTPHeaderField: "Idempotency-Key") }
        if let body { req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await networkSession.data(for: req)
        guard sessionRevision == revision, !isLocalKeySession else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw BigVipAPIError.code("network_error") }
        let reply = try JSONDecoder().decode(BigVipReply.self, from: data)
        if let address = reply.ip { ip = address }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || (response.statusCode == 403 && reply.code != "admin_required") {
                user = nil; token = nil; BigVipKeychain.write(nil)
            }
            throw BigVipAPIError.code(reply.code ?? "server_error")
        }
        return reply
    }
    private func accept(_ reply: BigVipReply) {
        if let newToken = reply.token { token = newToken; BigVipKeychain.write(newToken) }
        user = reply.user
        verifiedServerTime = reply.serverTime ?? 0
        verifiedUptime = ProcessInfo.processInfo.systemUptime
    }
    func signIn(username: String, password: String) async {
        guard !busy else { return }
        isLocalKeySession = false; sessionRevision = UUID()
        let revision = sessionRevision
        busy = true; message = ""
        defer { if sessionRevision == revision { busy = false } }
        do {
            let reply = try await request("v1/login", body: ["username": username, "password": password])
            accept(reply); message = "login_ok"
        } catch { if sessionRevision == revision { message = (error as? BigVipAPIError)?.errorDescription ?? "network_error" } }
    }
    func requireActive() async throws {
        if isLocalKeySession, user != nil { return }
        let revision = sessionRevision
        do { accept(try await request("v1/session")) }
        catch {
            guard sessionRevision == revision, !isLocalKeySession else { throw error }
            user = nil
            message = (error as? BigVipAPIError)?.errorDescription ?? "network_error"
            throw error
        }
    }
    func restoreSession() async {
        guard !isLocalKeySession, token != nil else { return }
        let revision = sessionRevision
        busy = true; defer { if sessionRevision == revision { busy = false } }
        try? await requireActive()
    }
    func expireIfNeeded() {
        if let user, !user.permanent, user.role != "admin", remainingSeconds == 0 {
            self.user = nil; message = "time_required"
        }
    }
    func signOut() async {
        if !isLocalKeySession { _ = try? await request("v1/logout", body: [:]) }
        sessionRevision = UUID(); isLocalKeySession = false
        token = nil; user = nil; BigVipKeychain.write(nil); message = ""
    }
}

@MainActor final class BigVipPreferences: ObservableObject {
    @Published var appearance = UserDefaults.standard.string(forKey: "bigvip.appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "bigvip.appearance") }
    }
    @Published var textSize = UserDefaults.standard.string(forKey: "bigvip.textSize") ?? "system" {
        didSet { UserDefaults.standard.set(textSize, forKey: "bigvip.textSize") }
    }
    @Published var largeButtons = UserDefaults.standard.object(forKey: "bigvip.largeButtons") as? Bool ?? true {
        didSet { UserDefaults.standard.set(largeButtons, forKey: "bigvip.largeButtons") }
    }
    @Published var haptics = UserDefaults.standard.object(forKey: "bigvip.haptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(haptics, forKey: "bigvip.haptics") }
    }
    @Published var reduceMotion = UserDefaults.standard.bool(forKey: "bigvip.reduceMotion") {
        didSet { UserDefaults.standard.set(reduceMotion, forKey: "bigvip.reduceMotion") }
    }
    @Published var highContrast = UserDefaults.standard.bool(forKey: "bigvip.highContrast") {
        didSet { UserDefaults.standard.set(highContrast, forKey: "bigvip.highContrast") }
    }
    @Published var showFileSize = UserDefaults.standard.object(forKey: "bigvip.showFileSize") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFileSize, forKey: "bigvip.showFileSize") }
    }
    @Published var showGameID = UserDefaults.standard.bool(forKey: "bigvip.showGameID") {
        didSet { UserDefaults.standard.set(showGameID, forKey: "bigvip.showGameID") }
    }
    @Published var showHints = UserDefaults.standard.object(forKey: "bigvip.showHints") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHints, forKey: "bigvip.showHints") }
    }
    @Published var confirmApply = UserDefaults.standard.object(forKey: "bigvip.confirmApply") as? Bool ?? true {
        didSet { UserDefaults.standard.set(confirmApply, forKey: "bigvip.confirmApply") }
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : (appearance == "light" ? .light : nil) }
    func feedback() { if haptics { UISelectionFeedbackGenerator().selectionChanged() } }
    func resetAppearance() {
        appearance = "system"; textSize = "system"; theme = 0
        largeButtons = true; haptics = true; reduceMotion = false; highContrast = false
        showFileSize = true; showGameID = false; showHints = true; confirmApply = true
    }
    @Published var language = UserDefaults.standard.string(forKey: "bigvip.language") ?? "vi" {
        didSet { UserDefaults.standard.set(language, forKey: "bigvip.language") }
    }
    @Published var theme = UserDefaults.standard.integer(forKey: "bigvip.theme") {
        didSet { UserDefaults.standard.set(theme, forKey: "bigvip.theme") }
    }
    static let languages = [("vi","Tiếng Việt"),("en","English"),("zh","中文"),("th","ไทย"),("ja","日本語"),
                            ("ko","한국어"),("es","Español"),("fr","Français"),("de","Deutsch"),("id","Bahasa Indonesia")]
    static let colors: [Color] = [.cyan, .blue, .purple, .pink, .red, .orange, .green, .mint]
    var accent: Color { Self.colors[max(0, min(theme, Self.colors.count-1))] }
    private static let translations: [String: [String: String]] = {
        guard let data = NSDataAsset(name: "BigVipTranslations")?.data,
              let dictionary = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return dictionary
    }()
    func text(_ key: String) -> String { Self.translations[language]?[key] ?? Self.translations["en"]?[key] ?? key }
}

struct BigVipGate: View {
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var systemTextSize
    var body: some View {
        Group {
            if auth.user != nil { ContentView() }
            else { BigVipLoginView() }
        }
        .tint(prefs.accent)
        .preferredColorScheme(prefs.colorScheme)
        .environment(\.dynamicTypeSize, prefs.textSize == "large" ? .xxxLarge : (prefs.textSize == "extra" ? .accessibility1 : systemTextSize))
        .task { await auth.restoreSession() }
        .task(id: auth.user?.username) {
            guard auth.user != nil, !auth.isLocalKeySession else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard auth.user != nil, scenePhase == .active else { continue }
                try? await auth.requireActive()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, auth.user != nil, !auth.isLocalKeySession { Task { try? await auth.requireActive() } }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in auth.expireIfNeeded() }
    }
}

private struct BigVipLoginView: View {
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var accessKey = ""
    @State private var keyError = false
    @State private var keyAccepted = false
    @State private var showSettings = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image("BigVipLogo").resizable().scaledToFit().frame(height: 235)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .rotation3DEffect(.degrees(reduceMotion || prefs.reduceMotion ? 0 : -7), axis: (x: 1, y: 0, z: 0))
                        .shadow(color: prefs.accent.opacity(0.4), radius: 22, y: 12)
                    Text("BIG VIP").font(.system(size: 32, weight: .black, design: .rounded))
                    VStack(spacing: 16) {
                        Text(prefs.text("login")).font(.title2.bold())
                        TextField(prefs.text("username"), text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        SecureField(prefs.text("password"), text: $password)
                            .textContentType(.password).textFieldStyle(.roundedBorder)
                        Button {
                            Task { await auth.signIn(username: username, password: password); if auth.user != nil { password = ""; accessKey = "" } }
                        } label: {
                            Group { if auth.busy { ProgressView() } else { Text(prefs.text("login")).bold() } }
                                .frame(maxWidth: .infinity).padding(10)
                        }.buttonStyle(BigVipPrimaryButtonStyle()).disabled(auth.busy || username.isEmpty || password.isEmpty)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(prefs.text("access_key")).font(.subheadline.bold())
                            SecureField(prefs.text("enter_key"), text: $accessKey)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: accessKey) { _ in keyError = false; keyAccepted = false }
                                .submitLabel(.go)
                                .onSubmit { keyAccepted = auth.signInWithKey(accessKey); keyError = !keyAccepted }
                            Button {
                                prefs.feedback()
                                keyAccepted = auth.signInWithKey(accessKey)
                                keyError = !keyAccepted
                            } label: {
                                Label(prefs.text("key_login"), systemImage: "key.fill")
                                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(10)
                            }
                            .buttonStyle(BigVipPrimaryButtonStyle()).disabled(accessKey.isEmpty)
                            if keyAccepted {
                                Label(prefs.text("key_accepted"), systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                            if keyError { Text(prefs.text("invalid_key")).font(.caption).foregroundStyle(.red) }
                        }
                        if !auth.message.isEmpty {
                            Text(prefs.text(auth.message)).font(.footnote)
                                .foregroundStyle(auth.message == "login_ok" ? .green : .red)
                                .multilineTextAlignment(.center)
                        }
                        if !auth.ip.isEmpty { Text("IP: " + auth.ip).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }.padding(24).background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).stroke(prefs.accent.opacity(0.4)))
                    Text(prefs.text("contact_admin")).font(.footnote).multilineTextAlignment(.center)
                    HStack {
                        Link("@kaicaythue", destination: URL(string: "https://www.tiktok.com/@kaicaythue")!)
                        Link("@gumballrealmenu", destination: URL(string: "https://www.tiktok.com/@gumballrealmenu")!)
                    }.font(.footnote.bold())
                }.padding(24)
            }
            .background(LinearGradient(colors: [prefs.accent.opacity(0.16), Color(uiColor: .systemBackground)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            .sheet(isPresented: $showSettings) { BigVipAccountSettings() }
        }
    }
}

struct BigVipAccountSettings: View {
    var isPresentedAsTab = false
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var showReset = false
    @State private var showLogout = false
    @State private var showPatches = false
    @State private var storageText = ""
    var body: some View {
        NavigationStack {
            Form {
                if let user = auth.user { accountSection(user) }
                appearanceSection
                interactionSection
                fileSection
                if auth.user == nil { serverSection }
                Section(prefs.text("app_information")) {
                    LabeledContent(prefs.text("version"), value: version)
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                    LabeledContent(prefs.text("stored_files"), value: storageText)
                    Button(prefs.text("refresh")) { storageText = describeStorage(); prefs.feedback() }
                    NavigationLink(prefs.text("logs")) { LogView() }
                    ShareLink(item: "bigvip \(version)\niOS \(UIDevice.current.systemVersion)\nMode: \(auth.isLocalKeySession ? "local key" : "account")\nLanguage: \(prefs.language)\nTheme: \(prefs.theme)") {
                        Label(prefs.text("share_info"), systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Button(prefs.text("reset_preferences")) { showReset = true }
                    if auth.user != nil {
                        Button(prefs.text("logout"), role: .destructive) { showLogout = true }
                    }
                }
            }
            .navigationTitle(prefs.text("settings"))
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar { if !isPresentedAsTab { Button(prefs.text("close")) { dismiss() } } }
            .onAppear { storageText = describeStorage() }
            .confirmationDialog(prefs.text("reset_preferences"), isPresented: $showReset, titleVisibility: .visible) {
                Button(prefs.text("reset_preferences"), role: .destructive) { prefs.resetAppearance() }
                Button(prefs.text("cancel"), role: .cancel) {}
            } message: { Text(prefs.text("reset_preferences_help")) }
            .confirmationDialog(prefs.text("logout"), isPresented: $showLogout, titleVisibility: .visible) {
                Button(prefs.text("logout"), role: .destructive) { Task { await auth.signOut(); dismiss() } }
                Button(prefs.text("cancel"), role: .cancel) {}
            }
            .sheet(isPresented: $showPatches) {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button(prefs.text("close")) { showPatches = false } }.padding()
                    PatchProjectsView()
                }
            }
        }.tint(prefs.accent)
    }
    private func accountSection(_ user: BigVipUser) -> some View {
        Section(prefs.text("account")) {
            LabeledContent(prefs.text("username"), value: user.username)
            if auth.isLocalKeySession {
                Label(prefs.text("key_mode"), systemImage: "key.horizontal.fill").foregroundStyle(prefs.accent)
            } else {
                LabeledContent("IP", value: auth.ip)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(prefs.text("time_left")).font(.caption)
                        Text(user.permanent || user.role == "admin" ? prefs.text("permanent") : countdown)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(user.permanent || auth.remainingSeconds > 3600 ? prefs.accent : .red)
                    }.padding(.vertical, 8)
                }
                Button(prefs.text("refresh")) { Task { try? await auth.requireActive() } }
            }
        }
    }
    private var appearanceSection: some View {
        Section(prefs.text("appearance")) {
            Picker(prefs.text("language"), selection: $prefs.language) {
                ForEach(BigVipPreferences.languages, id: \.0) { code, name in Text(name).tag(code) }
            }
            Picker(prefs.text("display_mode"), selection: $prefs.appearance) {
                Text(prefs.text("system")).tag("system")
                Text(prefs.text("light")).tag("light")
                Text(prefs.text("dark")).tag("dark")
            }
            Picker(prefs.text("text_size"), selection: $prefs.textSize) {
                Text(prefs.text("system")).tag("system")
                Text(prefs.text("large")).tag("large")
                Text(prefs.text("extra_large")).tag("extra")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                ForEach(0..<BigVipPreferences.colors.count, id: \.self) { index in
                    Button { prefs.theme = index; prefs.feedback() } label: {
                        Circle().fill(BigVipPreferences.colors[index]).frame(width: 38, height: 38)
                            .overlay { if prefs.theme == index { Image(systemName: "checkmark").foregroundStyle(.black).bold() } }
                            .frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(prefs.text("color") + " \(index+1)")
                }
            }.padding(.vertical, 6)
            Toggle(prefs.text("high_contrast"), isOn: $prefs.highContrast)
        }
    }
    private var interactionSection: some View {
        Section(prefs.text("interaction")) {
            Toggle(prefs.text("large_buttons"), isOn: $prefs.largeButtons)
            Toggle(prefs.text("haptics"), isOn: $prefs.haptics)
                .onChange(of: prefs.haptics) { _ in prefs.feedback() }
            Toggle(prefs.text("reduce_motion"), isOn: $prefs.reduceMotion)
            Toggle(prefs.text("show_hints"), isOn: $prefs.showHints)
            Toggle(prefs.text("show_game_id"), isOn: $prefs.showGameID)
            Button(prefs.text("preview_button")) { prefs.feedback() }
                .buttonStyle(BigVipPrimaryButtonStyle()).padding(.vertical, 4)
        }
    }
    private var fileSection: some View {
        Section(prefs.text("files_and_patch")) {
            Toggle(prefs.text("show_file_size"), isOn: $prefs.showFileSize)
            Toggle(prefs.text("confirm_patch"), isOn: $prefs.confirmApply)
            if auth.user != nil {
                Button { showPatches = true } label: {
                    Label(prefs.text("patch_manager"), systemImage: "folder.badge.gearshape")
                }
            }
        }
    }
    private var serverSection: some View {
        Section(prefs.text("server")) {
            TextField("https://api.example.com", text: $auth.serverURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Text(prefs.text("server_help")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") +
        " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
    }
    private var countdown: String {
        let total = auth.remainingSeconds
        return String(format: "%dd %02d:%02d:%02d", total/86400, (total/3600)%24, (total/60)%60, total%60)
    }
    private func describeStorage() -> String {
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return "0 B" }
        var bytes: Int64 = 0
        for folder in ["BigVipCache", "BigVipVisualFiles"] {
            let url = root.appendingPathComponent(folder)
            guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for file in files {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct BigVipAdminView: View {
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @State private var username = ""
    @State private var password = ""
    @State private var creditName = ""
    @State private var amount = "1"
    @State private var unit = "hours"
    @State private var users: [BigVipUser] = []
    @State private var busy = false
    @State private var feedback = ""
    @State private var isError = false
    @State private var requestID = UUID().uuidString
    var body: some View {
        Form {
            if !feedback.isEmpty {
                Section { Text(prefs.text(feedback)).foregroundStyle(isError ? .red : .green) }
            }
            Section(prefs.text("create_account")) {
                TextField(prefs.text("username"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(prefs.text("password"), text: $password)
                Button(prefs.text("create_account")) {
                    perform {
                        _ = try await auth.request("v1/admin/users", body: ["username":username,"password":password])
                        creditName = username; username = ""; password = ""; feedback = "created_no_time"
                    }
                }.disabled(busy || username.isEmpty || password.isEmpty)
                Text(prefs.text("new_account_help")).font(.caption).foregroundStyle(.secondary)
            }
            Section(prefs.text("add_time")) {
                TextField(prefs.text("username"), text: $creditName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker(prefs.text("unit"), selection: $unit) {
                    ForEach(["hours","days","months","years","permanent"], id: \.self) { Text(prefs.text($0)).tag($0) }
                }
                if unit != "permanent" {
                    TextField(prefs.text("amount"), text: $amount).keyboardType(.numberPad)
                }
                Button(prefs.text("add_time")) {
                    perform {
                        guard let number = Int(amount), number > 0 else { throw BigVipAPIError.code("invalid_duration") }
                        _ = try await auth.request("v1/admin/credit", body: ["username":creditName,"unit":unit,"amount":number],
                                                   requestID: requestID)
                        requestID = UUID().uuidString; feedback = "credited"
                    }
                }.disabled(busy || creditName.isEmpty)
            }
            Section(prefs.text("customers")) {
                Button(prefs.text("refresh")) { perform { try await reload() } }.disabled(busy)
                ForEach(users) { user in
                    VStack(alignment: .leading, spacing: 8) {
                        Button(user.username) { creditName = user.username }
                        Text(user.disabled ? prefs.text("account_disabled") :
                            (user.permanent ? prefs.text("permanent") :
                                (user.expiresAt == 0 ? prefs.text("time_required") :
                                    Date(timeIntervalSince1970: user.expiresAt/1000).formatted())))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(prefs.text(user.disabled ? "enable_account" : "disable_account")) {
                            perform {
                                _ = try await auth.request("v1/admin/account", body: ["username":user.username,"disabled":!user.disabled])
                                feedback = "updated"
                            }
                        }.disabled(busy)
                    }
                }
            }
            if busy { ProgressView() }
        }
        .navigationTitle("Admin")
        .disabled(busy)
        .task { perform { } }
        .onChange(of: creditName) { _ in requestID = UUID().uuidString }
        .onChange(of: amount) { _ in requestID = UUID().uuidString }
        .onChange(of: unit) { _ in requestID = UUID().uuidString }
    }
    private func reload() async throws { users = try await auth.request("v1/admin/users").users ?? [] }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard auth.isAdmin, !busy else { return }
        busy = true; isError = false
        Task {
            defer { busy = false }
            do { try await action(); try await reload() }
            catch { isError = true; feedback = (error as? BigVipAPIError)?.errorDescription ?? "network_error" }
        }
    }
}
