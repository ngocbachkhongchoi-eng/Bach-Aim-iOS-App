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
    @State private var showPatches = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var filesSession = FilesTabSession()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image("BigVipLogo").resizable().scaledToFit()
                        .frame(maxWidth: 300).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                    Text("CHỌN PHIÊN BẢN").font(.caption.weight(.bold)).tracking(2)
                        .foregroundStyle(.secondary)
                    ForEach(BigVipGame.games) { game in
                        NavigationLink {
                            BigVipGameView(game: game, onBrowse: { showFiles = true })
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: game.title == "FF MAX" ? "bolt.shield.fill" : "flame.fill")
                                    .font(.title).frame(width: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(game.title).font(.title2.weight(.bold))
                                    Text("Aim · ESP").font(.subheadline).opacity(0.8)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .foregroundStyle(.white).padding(24)
                            .background(LinearGradient(colors: [.blue, Color(red: 0.02, green: 0.2, blue: 0.5)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        }.buttonStyle(.plain)
                    }
                    Button { showPatches = true } label: {
                        Label("Quản lý patch & file", systemImage: "folder.badge.gearshape")
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
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        .onAppear(perform: loadConfiguration)
        .onChange(of: scenePhase) { phase in if phase == .active { refreshReceipt() } }
        .alert("bigvip", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("Đóng", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private var aimPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AIM NECK", systemImage: "scope")
                .font(.title2.weight(.heavy)).foregroundStyle(AppTheme.accent)
            Toggle(isOn: Binding(get: { applied }, set: setAimEnabled)) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aim Neck").font(.headline)
                    Text(applied ? "Đã áp dụng file" : (configured ? "Sẵn sàng áp dụng" : "Cần chọn file cache đích"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(working || (!configured && receipt == nil))
            if working { ProgressView("Đang xử lý file…").frame(maxWidth: .infinity) }
            if receipt != nil {
                Button("Khôi phục file gốc") { setAimEnabled(false) }
                    .buttonStyle(.bordered).disabled(working)
            }
            if !lastAction.isEmpty {
                Label(lastAction, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
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
                    .buttonStyle(.borderedProminent).disabled(working || receipt != nil)
                Button("Duyệt file", action: onBrowse)
                    .buttonStyle(.bordered).disabled(working)
            }
            Text("Thiết lập đúng đường dẫn một lần. Bật để thay file bằng dữ liệu đã gửi; tắt để khôi phục bản sao gốc. Đóng game trước khi thao tác.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("File thay thế đã kèm theo app. Hiệu quả Aim Neck trong game chưa được kiểm chứng.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var espPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("ESP", systemImage: "viewfinder").font(.title2.weight(.heavy))
                .foregroundStyle(AppTheme.accent)
            Text("Chưa có mô-đun ESP").font(.headline)
            Text("Bản này chưa có dữ liệu vị trí người chơi để hiển thị dây, hộp hoặc xương.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func loadConfiguration() {
        if let stored = UserDefaults.standard.string(forKey: key + ".id"), let id = UUID(uuidString: stored) {
            projectID = id
        } else {
            UserDefaults.standard.set(projectID.uuidString, forKey: key + ".id")
        }
        targetPath = UserDefaults.standard.string(forKey: key + ".path") ?? ""
        configured = !targetPath.isEmpty
        refreshReceipt()
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
        guard configured, receipt == nil,
              let payload = NSDataAsset(name: "AimNeckPayload")?.data else {
            notice = "Cần cấu hình file đích và khôi phục bản patch cũ trước khi bật."
            return
        }
        let project = PatchProject(id: projectID, name: "Aim Neck • " + game.title,
                                   bundleIdentifiers: [game.id],
                                   rules: [PatchRule(bundleID: game.id, relativePath: targetPath,
                                                     replacementFilename: "cache_res", replacementData: payload)])
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
