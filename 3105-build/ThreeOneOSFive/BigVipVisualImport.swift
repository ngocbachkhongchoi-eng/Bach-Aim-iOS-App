import SwiftUI
import CryptoKit

struct BigVipVisualFile: Codable {
    let filename: String
    let data: Data
    let importedAt: Date
    let sha256: String
    static let maximumBytes = 64 * 1024 * 1024

    static func readSource(_ source: URL) throws -> Self {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw NSError(domain: "bigvip.visual", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Chọn một file không rỗng, tối đa 64 MB."])
        }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty, data.count <= maximumBytes,
              source.pathExtension.lowercased() != "3105",
              !data.starts(with: Data("3105PATCH\0".utf8)) else {
            throw NSError(domain: "bigvip.visual", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Gói .3105 cần nhập trong Quản lý patch. Mục này lưu file ESP hoặc Chams riêng."])
        }
        return Self(filename: source.lastPathComponent, data: data, importedAt: Date(),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    static func location(bundleID: String, kind: String) throws -> URL {
        guard ["esp", "chams"].contains(kind) else { throw PatchPackageError.invalidProject }
        let bundle = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("BigVipVisualFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(bundle + "-" + kind + ".plist")
    }
    func save(bundleID: String, kind: String) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(self).write(to: Self.location(bundleID: bundleID, kind: kind), options: .atomic)
    }
    static func load(bundleID: String, kind: String) -> Self? {
        guard let url = try? location(bundleID: bundleID, kind: kind),
              let data = try? Data(contentsOf: url),
              let file = try? PropertyListDecoder().decode(Self.self, from: data),
              !file.data.isEmpty, file.data.count <= maximumBytes else { return nil }
        return file
    }
}

struct BigVipVisualImportView: View {
    let bundleID: String
    @EnvironmentObject private var prefs: BigVipPreferences
    @State private var files: [String: BigVipVisualFile] = [:]
    @State private var selectedKind = "esp"
    @State private var showPicker = false
    @State private var pendingSelection: Result<[URL], Error>?
    @State private var working = false
    @State private var message: String?
    @State private var removal: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ESP / CHAMS").font(.system(.title2, design: .rounded).weight(.black))
                Text(prefs.text("visual_import_help")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(["esp", "chams"], id: \.self) { kind in card(kind) }
            if working { ProgressView(prefs.text("importing")).frame(maxWidth: .infinity) }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showPicker, onDismiss: consumeSelection) {
            FileDocumentPicker(allowsMultipleSelection: false,
                onSelection: { result in pendingSelection = result; showPicker = false },
                onCancel: { showPicker = false })
        }
        .alert("bigvip", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(prefs.text("close"), role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog(prefs.text("remove_import"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let kind = removal {
                    Button(prefs.text("remove_import"), role: .destructive) {
                        do {
                            try FileManager.default.removeItem(at: BigVipVisualFile.location(bundleID: bundleID, kind: kind))
                            removal = nil; reload()
                        } catch { message = error.localizedDescription; removal = nil }
                    }
                }
                Button(prefs.text("cancel"), role: .cancel) { removal = nil }
            } message: { Text(prefs.text("remove_import_help")) }
    }
    private func card(_ kind: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: kind == "esp" ? "viewfinder" : "square.3.layers.3d")
                    .font(.title).foregroundStyle(prefs.accent)
                Text(kind == "esp" ? "ESP" : "CHAMS").font(.title3.bold())
                Spacer()
                Image(systemName: files[kind] == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                    .foregroundStyle(files[kind] == nil ? prefs.accent : .green)
            }
            if let file = files[kind] {
                Text(file.filename).font(.headline).lineLimit(2).textSelection(.enabled)
                if prefs.showFileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(file.importedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("SHA-256") { Text(file.sha256).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Button {
                prefs.feedback(); selectedKind = kind; showPicker = true
            } label: {
                Label(prefs.text(kind == "esp" ? "import_esp" : "import_chams"), systemImage: "folder.badge.plus")
            }.buttonStyle(BigVipPrimaryButtonStyle()).disabled(working)
            if files[kind] != nil {
                Button(prefs.text("remove_import"), role: .destructive) { removal = kind }.disabled(working)
            }
        }.bigVipCard()
    }
    private func reload() {
        for kind in ["esp", "chams"] { files[kind] = BigVipVisualFile.load(bundleID: bundleID, kind: kind) }
    }
    private func consumeSelection() {
        guard let result = pendingSelection else { return }
        pendingSelection = nil
        switch result {
        case .failure(let error): message = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let kind = selectedKind
            working = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let file = try BigVipVisualFile.readSource(url)
                    try file.save(bundleID: bundleID, kind: kind)
                    DispatchQueue.main.async {
                        files[kind] = file; working = false
                        message = prefs.text("visual_imported")
                    }
                } catch {
                    DispatchQueue.main.async { working = false; message = error.localizedDescription }
                }
            }
        }
    }
}
