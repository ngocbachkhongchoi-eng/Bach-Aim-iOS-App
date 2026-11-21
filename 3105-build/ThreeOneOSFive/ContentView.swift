import SwiftUI
import UIKit

private struct BigVipGame: Identifiable, Hashable {
    let id: String
    let title: String
    static let games = [
        BigVipGame(id: "com.dts.freefireth", title: "FF thường"),
        BigVipGame(id: "com.dts.freefiremax", title: "FF MAX")
    ]
}

struct ContentView: View {
    @EnvironmentObject private var drafts: PatchDraftCoordinator
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @State private var mainTab = 0
    @State private var showPatches = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var filesSession = FilesTabSession()

    var body: some View {
        TabView(selection: $mainTab) {
            homePage.tabItem { Label(prefs.text("home"), systemImage: "house.fill") }.tag(0)
            if auth.isAdmin {
                NavigationStack { BigVipAdminView() }
                    .tabItem { Label("Admin", systemImage: "person.badge.key.fill") }.tag(1)
            }
            BigVipAccountSettings(isPresentedAsTab: true).tabItem { Label(prefs.text("settings"), systemImage: "gearshape") }.tag(2)
        }.tint(prefs.accent)
    }

    private var homePage: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image("BigVipLogo").resizable().scaledToFit()
                        .frame(maxWidth: 300).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .shadow(color: prefs.accent.opacity(0.35), radius: 18, y: 10)
                    Text(prefs.text("choose_game")).font(.caption.weight(.bold)).tracking(2)
                        .foregroundStyle(.secondary)
                    Text(auth.isLocalKeySession ? prefs.text("key_mode") : prefs.text("login_ok") + " · IP: " + auth.ip).font(.caption).foregroundStyle(.secondary)
                    ForEach(BigVipGame.games) { game in
                        NavigationLink {
                            BigVipGameView(game: game, onBrowse: { showFiles = true })
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: game.title == "FF MAX" ? "bolt.shield.fill" : "flame.fill")
                                    .font(.title).frame(width: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(game.title).font(.title2.weight(.bold))
                                    Text("Aim · ESP · Chams").font(.subheadline).opacity(0.8)
                                    if prefs.showGameID { Text(game.id).font(.caption2.monospaced()).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundStyle(.white).padding(24)
                            .background(LinearGradient(colors: [Color(red: 0.02, green: 0.12, blue: 0.23), prefs.accent.opacity(0.8)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        }.buttonStyle(.plain)
                    }
                    Button { showPatches = true } label: {
                        Label(prefs.text("patch_manager"), systemImage: "folder.badge.gearshape")
                            .frame(maxWidth: .infinity).padding(12)
                    }.buttonStyle(.bordered)
                }.padding(22)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("bigvip")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showLogs = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .accessibilityLabel("Nhật ký")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Cài đặt")
                }
            }
        }
        .tint(AppTheme.accent)
        .sheet(isPresented: $showPatches) {
            PatchProjectsView().bigVipCloseButton()
        }
        .sheet(isPresented: $showFiles, onDismiss: presentPendingDraft) {
            AppDataBrowserView(tabSession: $filesSession).bigVipCloseButton()
        }
        .sheet(isPresented: $showSettings) { BigVipAccountSettings() }
        .sheet(isPresented: $showLogs) { LogView() }
        .onChange(of: drafts.request?.id) { _ in routeDraft() }
        .onChange(of: drafts.importRequest?.id) { _ in routeDraft() }
    }

    private func routeDraft() {
        guard drafts.request != nil || drafts.importRequest != nil else { return }
        if showFiles { showFiles = false }
        else { showPatches = true }
    }

    private func presentPendingDraft() {
        if drafts.request != nil || drafts.importRequest != nil { showPatches = true }
    }
}

private struct BigVipCloseModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("Đóng") { dismiss() }.fontWeight(.semibold) }.padding()
            content
        }
    }
}

private extension View {
    func bigVipCloseButton() -> some View { modifier(BigVipCloseModifier()) }
}

private struct BigVipGameView: View {
    let game: BigVipGame
    let onBrowse: () -> Void
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var auth: BigVipAuth
    @EnvironmentObject private var prefs: BigVipPreferences
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var targetPath = ""
    @State private var projectID = UUID()
    @State private var receipt: PatchTransactionReceipt?
    @State private var applied = false
    @State private var working = false
    @State private var configured = false
    @State private var notice: String?
    @State private var lastAction = ""
    @State private var selectedCache: BigVipCacheFile?
    @State private var showCacheImporter = false
    @State private var showApplyConfirmation = false
    @State private var pendingCacheSelection: Result<[URL], Error>?

    private var key: String { "bigvip.aimNeck." + game.id }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Chức năng", selection: $tab) {
                Text("Aim").tag(0)
                Text("ESP").tag(1)
            }.pickerStyle(.segmented).padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == 0 { aimPanel } else { espPanel }
                }.padding()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCacheImporter, onDismiss: consumeCacheSelection) {
            FileDocumentPicker(allowsMultipleSelection: false,
                onSelection: { result in pendingCacheSelection = result; showCacheImporter = false },
                onCancel: { showCacheImporter = false })
        }
        .confirmationDialog("Áp dụng file cache?", isPresented: $showApplyConfirmation, titleVisibility: .visible) {
            Button("Áp dụng") { authorizeAndApply() }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Đóng game trước khi áp dụng. File gốc sẽ được lưu để khôi phục.") }
        .onAppear(perform: loadConfiguration)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BigVipAimTargetSelected"))) { _ in loadConfiguration() }
        .onChange(of: scenePhase) { phase in if phase == .active { refreshReceipt() } }
        .alert("bigvip", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("Đóng", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private var aimPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AIM CACHE", systemImage: "scope")
                .font(.title2.weight(.heavy)).foregroundStyle(AppTheme.accent)
            Toggle(isOn: Binding(get: { applied }, set: setAimEnabled)) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bật file cache").font(.headline)
                    Text(applied ? "Đã áp dụng file" : (selectedCache == nil ? "Chưa nhập file cache" : (configured ? "Sẵn sàng áp dụng" : "Cần chọn file cache đích")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(working || ((!configured || selectedCache == nil) && receipt == nil))
            Text("40% thì bật chức năng").font(.footnote.weight(.semibold)).foregroundStyle(AppTheme.accent)
            if working { ProgressView("Đang xử lý file…").frame(maxWidth: .infinity) }
            if receipt != nil {
                Button("Khôi phục file gốc") { setAimEnabled(false) }
                    .buttonStyle(.bordered).disabled(working)
            }
            if !lastAction.isEmpty {
                Label(lastAction, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("File cache của bạn").font(.headline)
            if let cache = selectedCache {
                Label(cache.filename, systemImage: "doc.fill").font(.subheadline)
                if prefs.showFileSize { Text(ByteCountFormatter.string(fromByteCount: Int64(cache.data.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
            Button(selectedCache == nil ? "Nhập file cache" : "Đổi file cache") { showCacheImporter = true }
                .buttonStyle(BigVipPrimaryButtonStyle()).disabled(working || receipt != nil)
            if prefs.showHints { Text("Nhận tên cache… hoặc đuôi .cache, tối đa 64 MB. Khôi phục file gốc trước khi đổi sang cache khác.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("File cache đích").font(.headline)
            TextField("Đường dẫn trong dữ liệu game, gồm tên file", text: $targetPath, axis: .vertical)
                .font(.footnote.monospaced()).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                .disabled(working || receipt != nil)
                .onChange(of: targetPath) { _ in
                    configured = targetPath == UserDefaults.standard.string(forKey: key + ".path")
                }
            HStack {
                Button("Lưu đường dẫn", action: saveConfiguration)
                    .buttonStyle(BigVipPrimaryButtonStyle()).disabled(working || receipt != nil)
                Button("Duyệt file", action: onBrowse)
                    .buttonStyle(.bordered).disabled(working)
            }
            Text("Chọn file cache của bạn và đúng file đích trong game. Bật để áp dụng; tắt để khôi phục bản sao gốc. Đóng game trước khi thao tác.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Hiệu quả trong game phụ thuộc nội dung và độ tương thích của file cache; chưa được kiểm chứng trên thiết bị.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var espPanel: some View {
        BigVipVisualImportView(bundleID: game.id)
    }

    private func loadConfiguration() {
        if let stored = UserDefaults.standard.string(forKey: key + ".id"), let id = UUID(uuidString: stored) {
            projectID = id
        } else {
            UserDefaults.standard.set(projectID.uuidString, forKey: key + ".id")
        }
        targetPath = UserDefaults.standard.string(forKey: key + ".path") ?? ""
        configured = !targetPath.isEmpty
        selectedCache = BigVipCacheFile.load(bundleID: game.id)
        refreshReceipt()
    }

    private func consumeCacheSelection() {
        guard let result = pendingCacheSelection else { return }
        pendingCacheSelection = nil
        guard receipt == nil, !working else { return }
        switch result {
        case .failure(let error): notice = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { notice = "Chưa chọn file cache."; return }
            working = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let cache = try BigVipCacheFile.readSource(url)
                    try cache.save(bundleID: game.id)
                    DispatchQueue.main.async {
                        selectedCache = cache; working = false
                        lastAction = "Đã nhập cache; chưa thay file trong game"
                    }
                } catch { finishWithError(error) }
            }
        }
    }

    private func refreshReceipt() {
        guard !working else { return }
        receipt = DevicePatchService.latestReceipt(projectID: projectID)
        applied = receipt.map { PatchTransaction.isApplied(receipt: $0) } ?? false
    }

    private func saveConfiguration() {
        do {
            let path = try PatchPathValidator.canonicalRelativePath(targetPath.trimmingCharacters(in: .whitespacesAndNewlines))
            targetPath = path
            UserDefaults.standard.set(path, forKey: key + ".path")
            configured = true
            notice = "Đã lưu đường dẫn. Khi bật, app kiểm tra file đích tồn tại trước khi thay."
        } catch { notice = "Đường dẫn không hợp lệ. Cần đường dẫn tương đối đầy đủ trong dữ liệu game, gồm tên file." }
    }

    private func setAimEnabled(_ enabled: Bool) {
        guard !working else { return }
        prefs.feedback()
        if !enabled { applyAimChange(false); return }
        if prefs.confirmApply { showApplyConfirmation = true } else { authorizeAndApply() }
    }

    private func authorizeAndApply() {
        working = true
        Task {
            do {
                try await auth.requireActive()
                working = false
                applyAimChange(true)
            } catch {
                working = false
                notice = "Không xác minh được thời hạn sử dụng trên máy chủ."
            }
        }
    }

    private func applyAimChange(_ enabled: Bool) {
        guard !working else { return }
        if !enabled {
            guard let receipt else { applied = false; return }
            working = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try DevicePatchService.restore(receipt: receipt)
                    DispatchQueue.main.async {
                        working = false; refreshReceipt()
                        lastAction = "Đã khôi phục file gốc"
                    }
                } catch { finishWithError(error) }
            }
            return
        }
        guard configured, receipt == nil, let cache = selectedCache else {
            notice = "Cần cấu hình file đích và khôi phục bản patch cũ trước khi bật."
            return
        }
        let project = PatchProject(id: projectID, name: "Aim Cache • " + game.title,
                                   bundleIdentifiers: [game.id],
                                   rules: [PatchRule(bundleID: game.id, relativePath: targetPath,
                                                     replacementFilename: cache.filename, replacementData: cache.data)])
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PatchPackageCodec.validate(project)
                // Never create a guessed cache file: require the user-selected existing target.
                guard let root = ContainerStore.resolveAppContainerPath(bundleID: game.id),
                      ContainerStore.isApplicationContainerPath(root) else {
                    throw PatchPackageError.targetAppUnavailable(game.id)
                }
                let target = URL(fileURLWithPath: root).appendingPathComponent(project.rules[0].relativePath)
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw PatchPackageError.invalidProject
                }
                _ = try DevicePatchService.apply(project: project)
                DispatchQueue.main.async {
                    working = false; refreshReceipt()
                    lastAction = "Đã thay file và lưu bản sao gốc"
                }
            } catch { finishWithError(error) }
        }
    }

    private func finishWithError(_ error: Error) {
        DispatchQueue.main.async {
            working = false
            refreshReceipt()
            if let patchError = error as? PatchPackageError {
                notice = patchError.localizationArgument.map { language.text(patchError.localizationKey, $0) }
                    ?? language.text(patchError.localizationKey)
            } else {
                notice = error.localizedDescription
            }
            lastAction = "Thao tác chưa hoàn tất — xem thông báo"
        }
    }
}

struct BigVipCacheFile: Codable {
    let filename: String
    let data: Data
    static let maximumBytes = 64 * 1024 * 1024

    static func acceptsFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("cache") || lower.hasSuffix(".cache")
    }

    static func readSource(_ source: URL) throws -> BigVipCacheFile {
        guard acceptsFilename(source.lastPathComponent) else {
            throw NSError(domain: "bigvip.cache", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Chỉ nhận file có tên bắt đầu bằng cache hoặc đuôi .cache. Gói .3105 nhập ở mục Quản lý patch."])
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw NSError(domain: "bigvip.cache", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cần một file cache không rỗng, tối đa 64 MB."])
        }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty, data.count <= maximumBytes,
              !data.starts(with: Data("3105PATCH\0".utf8)) else {
            throw NSError(domain: "bigvip.cache", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Đây không phải file cache thô hợp lệ. Không đổi tên gói .3105 thành file cache."])
        }
        return BigVipCacheFile(filename: source.lastPathComponent, data: data)
    }

    private static func location(bundleID: String) throws -> URL {
        let bundle = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BigVipCache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(bundle + ".plist")
    }

    func save(bundleID: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: Self.location(bundleID: bundleID), options: .atomic)
    }

    static func load(bundleID: String) -> BigVipCacheFile? {
        guard let url = try? location(bundleID: bundleID),
              let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(Self.self, from: data),
              acceptsFilename(cache.filename), !cache.data.isEmpty,
              cache.data.count <= maximumBytes else { return nil }
        return cache
    }
}
