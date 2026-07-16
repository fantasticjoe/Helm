import AppKit
import SwiftUI

@MainActor
@Observable
final class FileBrowserModel {
    struct Transfer: Identifiable {
        enum State: Equatable {
            case running
            case done
            case failed(String)
        }

        let id = UUID()
        var label: String
        var state: State = .running
        var localURL: URL?
    }

    let host: Host
    var path = ""
    var files: [RemoteFile] = []
    var loading = false
    var errorMessage: String?
    var transfers: [Transfer] = []

    init(host: Host) {
        self.host = host
    }

    func open() async {
        loading = true
        path = await RemoteFileService.homeDirectory(of: host) ?? "/"
        await refresh()
    }

    func refresh() async {
        loading = true
        errorMessage = nil
        switch await RemoteFileService.list(path, on: host) {
        case .success(let listed):
            files = listed.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .failure(let error):
            files = []
            errorMessage = error.message
        }
        loading = false
    }

    func enter(_ file: RemoteFile) {
        guard file.isDirectory else { return }
        path = RemoteFileService.joinPath(path, file.name)
        Task { await refresh() }
    }

    func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        Task { await refresh() }
    }

    func goHome() {
        Task { await open() }
    }

    func download(_ names: Set<String>) {
        let targets = files.filter { names.contains($0.id) }
        let directory = path
        for file in targets {
            let transferID = addTransfer(label: "下载 \(file.name)")
            Task {
                switch await RemoteFileService.download(file, in: directory, from: host) {
                case .success(let url):
                    finishTransfer(transferID, state: .done, localURL: url)
                case .failure(let error):
                    finishTransfer(transferID, state: .failed(error.message))
                }
            }
        }
    }

    func upload(_ urls: [URL]) {
        let directory = path
        for url in urls {
            let transferID = addTransfer(label: "上传 \(url.lastPathComponent)")
            Task {
                switch await RemoteFileService.upload(url, to: directory, on: host) {
                case .success:
                    finishTransfer(transferID, state: .done)
                    if path == directory { await refresh() }
                case .failure(let error):
                    finishTransfer(transferID, state: .failed(error.message))
                }
            }
        }
    }

    private func addTransfer(label: String) -> UUID {
        let transfer = Transfer(label: label)
        transfers.append(transfer)
        return transfer.id
    }

    private func finishTransfer(_ id: UUID, state: Transfer.State, localURL: URL? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].localURL = localURL
        if case .failed(let message) = state {
            NotificationService.post(title: "传输失败", body: "\(transfers[index].label):\(message)")
        }
    }
}

struct FileBrowserView: View {
    @Environment(\.panelDismiss) private var dismiss
    @State private var model: FileBrowserModel
    @State private var selection: Set<String> = []
    @State private var pendingUploads: [URL] = []
    @State private var confirmOverwrite = false

    init(host: Host) {
        _model = State(initialValue: FileBrowserModel(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()
            content
            if !model.transfers.isEmpty {
                Divider()
                transferStrip
            }
            Divider()
            Text("双击目录进入 · 双击文件下载到「下载」 · 从 Finder 拖入即上传")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(6)
        }
        .frame(width: 720, height: 540)
        .task { await model.open() }
        .confirmationDialog(
            "覆盖远端同名文件?",
            isPresented: $confirmOverwrite
        ) {
            Button("上传并覆盖", role: .destructive) {
                model.upload(pendingUploads)
                pendingUploads = []
            }
        } message: {
            Text(overwriteMessage)
        }
    }

    private var header: some View {
        HStack {
            Label("文件 — \(model.host.name)", systemImage: "folder")
                .font(.headline)
            Spacer()
            Button("下载所选 (\(selection.count))") { model.download(selection) }
                .disabled(selection.isEmpty)
            Button("关闭") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(12)
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help("上一级")
                .disabled(model.path == "/" || model.loading)
            Button { model.goHome() } label: { Image(systemName: "house") }
                .help("主目录")
                .disabled(model.loading)
            TextField("路径", text: Bindable(model).path)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { Task { await model.refresh() } }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新")
                .disabled(model.loading)
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Text("\(model.files.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("无法读取目录", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await model.refresh() } }
            }
        } else {
            Table(model.files, selection: $selection) {
                TableColumn("名称") { file in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: file))
                            .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                        Text(file.name)
                            .lineLimit(1)
                    }
                }
                TableColumn("大小") { file in
                    Text(sizeString(for: file))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("修改时间") { file in
                    Text(dateString(for: file))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .width(140)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    Button("下载") { model.download(ids) }
                }
                if ids.count == 1,
                   let file = model.files.first(where: { $0.id == ids.first }),
                   file.isDirectory {
                    Button("打开") { model.enter(file) }
                }
            } primaryAction: { ids in
                guard ids.count == 1,
                      let file = model.files.first(where: { $0.id == ids.first }) else { return }
                if file.isDirectory {
                    model.enter(file)
                } else {
                    model.download([file.id])
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
                return true
            }
        }
    }

    private var transferStrip: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(model.transfers.reversed()) { transfer in
                    HStack(spacing: 8) {
                        switch transfer.state {
                        case .running:
                            ProgressView().controlSize(.mini)
                        case .done:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        Text(transfer.label)
                            .font(.caption)
                            .lineLimit(1)
                        if case .failed(let message) = transfer.state {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let url = transfer.localURL {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 96)
    }

    /// 上传前检查远端同名冲突,有冲突先确认。
    private func handleDrop(_ urls: [URL]) {
        let existing = Set(model.files.map(\.name))
        let conflicts = urls.filter { existing.contains($0.lastPathComponent) }
        if conflicts.isEmpty {
            model.upload(urls)
        } else {
            pendingUploads = urls
            confirmOverwrite = true
        }
    }

    private var overwriteMessage: String {
        let existing = Set(model.files.map(\.name))
        let names = pendingUploads.map(\.lastPathComponent).filter { existing.contains($0) }
        let shown = names.prefix(3).joined(separator: "、")
        let suffix = names.count > 3 ? " 等 \(names.count) 个文件" : ""
        return "远端目录已存在:\(shown)\(suffix)"
    }

    private func icon(for file: RemoteFile) -> String {
        switch file.kind {
        case .directory: "folder.fill"
        case .symlink: "link"
        case .file: "doc"
        }
    }

    private func sizeString(for file: RemoteFile) -> String {
        guard !file.isDirectory, let size = file.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func dateString(for file: RemoteFile) -> String {
        guard let modified = file.modified else { return "—" }
        return modified.formatted(.dateTime.month().day().hour().minute())
    }
}
