import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @AppStorage(FeatureVisibility.developerModeStorageKey)
    private var developerModeEnabled = false
    @State private var tabNavigation: AppTabNavigationState
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var openingBundleID: String?
    @State private var gameOpenError: String?

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab: Int
        if arguments.contains("--simulate-new-tab") {
            initialTab = 1
        } else if arguments.contains("--simulate-sources-tab") {
            initialTab = 2
        } else if arguments.contains("--simulate-installed-tab")
                    || arguments.contains("--simulate-patch-tab")
                    || arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 3
        } else if arguments.contains("--simulate-files-tab") {
            initialTab = 4
        } else if arguments.contains("--simulate-search-tab") {
            initialTab = 5
        } else {
            initialTab = 0
        }
        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: initialTab))
        _showSettings = State(
            initialValue: arguments.contains("--simulate-settings")
        )
#else
        _tabNavigation = State(initialValue: AppTabNavigationState())
#endif
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onChange(of: developerModeEnabled) { _ in
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
        .onAppear {
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showLogs) { LogView() }
        .alert("Không mở được dữ liệu game", isPresented: Binding(
            get: { gameOpenError != nil },
            set: { if !$0 { gameOpenError = nil } }
        )) {
            Button("Đóng", role: .cancel) { gameOpenError = nil }
        } message: {
            Text(gameOpenError ?? "")
        }
        .patchStorePresentation(patchStore)
        .repositoryStorePresentation(repositoryStore, patchStore: patchStore)
    }

    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections) { section in
                sectionContent(section)
                    .tabItem {
                        CompactTabLabel(
                            title: language.text(section.titleKey),
                            systemImage: section.systemImage
                        )
                    }
                    .tag(section.rawValue)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(language.text(section.titleKey), systemImage: section.systemImage)
                            .fontWeight(section.rawValue == tabNavigation.selectedTab ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent.opacity(0.14)
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        section.rawValue == tabNavigation.selectedTab ? .isSelected : []
                    )
                }
            }
            .navigationTitle("bigvip")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection)
                .id(selectedVisibleSection.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .home:
            BigVipHomeView(
                openingBundleID: openingBundleID,
                onChooseGame: openGame,
                onOpenPatches: { tabNavigation.select(AppSection.installed.rawValue) },
                onBrowseApps: {
                    developerModeEnabled = true
                    tabNavigation.setFilesNavigationPath([])
                    tabNavigation.select(AppSection.files.rawValue)
                },
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .new:
            RepositoryNewView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .sources:
            RepositorySourcesView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .installed:
            PatchProjectsView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .files:
            AppDataBrowserView(
                tabSession: filesTabSession,
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: { tabNavigation.select($0) }
        )
    }

    private var filesTabSession: Binding<FilesTabSession> {
        Binding(
            get: { tabNavigation.filesTabs },
            set: { tabNavigation.setFilesTabs($0) }
        )
    }

    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(developerModeEnabled: developerModeActive)
    }

    private var developerModeActive: Bool {
#if targetEnvironment(simulator)
        developerModeEnabled
            || ProcessInfo.processInfo.arguments.contains("--simulate-developer-mode")
            || ProcessInfo.processInfo.arguments.contains("--simulate-files-tab")
#else
        developerModeEnabled
#endif
    }

    private var selectedVisibleSection: AppSection {
        let selected = AppSection(rawValue: tabNavigation.selectedTab)
        return selected.flatMap {
            featureVisibility.isVisible($0) ? $0 : nil
        } ?? .home
    }

    private func openSettings() {
        showSettings = true
    }

    private func openLogs() {
        showLogs = true
    }

    private func openGame(_ title: String, _ bundleID: String) {
        guard openingBundleID == nil else { return }
        openingBundleID = bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID)
            DispatchQueue.main.async {
                openingBundleID = nil
                guard let path, ContainerStore.isApplicationContainerPath(path) else {
                    gameOpenError = "Không tìm thấy hoặc chưa truy cập được \(title) (\(bundleID)). Kiểm tra game đã cài, phiên bản iOS và cách ký 3105. Nếu bundle ID khác, dùng ‘Chọn ứng dụng khác’. Chưa thay file nào."
                    return
                }
                developerModeEnabled = true
                tabNavigation.setFilesNavigationPath([
                    FileBrowserDestination(containerPath: path, startPath: path,
                                           title: title, bundleID: bundleID)
                ])
                tabNavigation.select(AppSection.files.rawValue)
            }
        }
    }
}

private struct BigVipHomeView: View {
    let openingBundleID: String?
    let onChooseGame: (String, String) -> Void
    let onOpenPatches: () -> Void
    let onBrowseApps: () -> Void
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 32, weight: .semibold))
                        Text("bigvip")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("FREE FIRE • PATCH MANAGER")
                            .font(.caption.weight(.semibold)).tracking(2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Chọn phiên bản game để mở dữ liệu và tạo patch.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(26)
                    .background(LinearGradient(colors: [Color(red: 0.04, green: 0.24, blue: 0.66), Color(red: 0.08, green: 0.52, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                    Text("CHỌN GAME").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    gameCard("FF thường", bundleID: "com.dts.freefireth", icon: "flame.fill", detail: "Free Fire")
                    gameCard("FF MAX", bundleID: "com.dts.freefiremax", icon: "bolt.shield.fill", detail: "Free Fire MAX")

                    Button(action: onOpenPatches) {
                        Label("Patch đã lưu • Áp dụng / Khôi phục", systemImage: "tray.full.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(18)
                    }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    Button("Chọn ứng dụng khác", action: onBrowseApps)
                        .font(.subheadline).frame(maxWidth: .infinity)
                        .disabled(openingBundleID != nil)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Patch bằng luồng 3105", systemImage: "doc.badge.gearshape")
                            .font(.subheadline.weight(.semibold))
                        Text("Mở game ở trên → tìm file đích → nhấn giữ file → Thay thế hoặc Tạo Patch. Nhập file thay thế rồi áp dụng trong Patch đã lưu.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Chưa chọn file đích thì chưa ghi dữ liệu. Đóng game trước khi áp dụng hoặc khôi phục patch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("bigvip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: onOpenLogs) { Image(systemName: "doc.text.magnifyingglass") }
                        .accessibilityLabel("Nhật ký")
                    Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Cài đặt")
                }
            }
        }
    }

    private func gameCard(_ title: String, bundleID: String, icon: String, detail: String) -> some View {
        Button { onChooseGame(title, bundleID) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 56, height: 60)
                    .background(AppTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if openingBundleID == bundleID { ProgressView().tint(AppTheme.accent) }
                else { Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(AppTheme.accent) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(AppTheme.accent.opacity(0.18)))
        }
        .buttonStyle(.plain).disabled(openingBundleID != nil)
    }
}

private struct CompactTabLabel: View {
    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private extension AppSection {
    var titleKey: String {
        switch self {
        case .home: return "tab.home"
        case .new: return "tab.new"
        case .sources: return "tab.sources"
        case .installed: return "tab.installed"
        case .files: return "tab.files"
        case .search: return "tab.search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .new: return "clock.fill"
        case .sources: return "shippingbox.fill"
        case .installed: return "tray.full.fill"
        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
        }
    }
}
