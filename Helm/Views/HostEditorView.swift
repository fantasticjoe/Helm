import SwiftUI

struct HostEditorView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    enum Destination: String, CaseIterable, Identifiable {
        case sshConfig
        case helmOnly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sshConfig: "写入 ~/.ssh/config"
            case .helmOnly: "仅 Helm 内部"
            }
        }
    }

    @State private var alias = ""
    @State private var displayName = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var proxyJump = ""
    @State private var identityFile = ""
    @State private var destination: Destination = .sshConfig
    @State private var auth: AuthKind = .key
    @State private var tagsText = ""
    @State private var gpuEnabled = false
    @State private var slurmEnabled = false
    @State private var notes = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var configEditable = false
    @State private var proxyCommandManaged = false
    @State private var saving = false
    @State private var saveError: String?

    private var originalMeta: HostMeta? {
        if case .edit(let meta) = target { return meta }
        return nil
    }

    private var isNew: Bool { originalMeta == nil }
    private var isConfigSourced: Bool { originalMeta?.source == .sshConfig }

    private var canSave: Bool {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else { return false }
        guard port.isEmpty || Int(port) != nil else { return false }
        if isNew {
            guard engine.host(alias: trimmedAlias) == nil else { return false }
            return !hostName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "添加主机" : "编辑 \(originalMeta!.alias)")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)
            Form {
                Section("基本") {
                    TextField("别名", text: $alias)
                        .disabled(!isNew)
                    TextField("显示名称(可选)", text: $displayName)
                }
                connectionSection
                Section("认证") {
                    Picker("方式", selection: $auth) {
                        ForEach(AuthKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if auth == .password {
                        SecureField(hasStoredPassword ? "密码已保存(输入以更新)" : "账户密码", text: $password)
                        HStack {
                            if hasStoredPassword {
                                Label("已存入钥匙串", systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("删除已存密码", role: .destructive) {
                                    KeychainStore.deletePassword(for: alias)
                                    hasStoredPassword = false
                                }
                                .controlSize(.small)
                            } else {
                                Text("保存后密码仅存于 macOS 钥匙串,仅 Helm 可读取")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Section("监控能力") {
                    Toggle("GPU(nvidia-smi)", isOn: $gpuEnabled)
                    Toggle("SLURM 队列(squeue)", isOn: $slurmEnabled)
                }
                Section("其他") {
                    TextField("标签(逗号分隔,如:GPU集群, 实验室)", text: $tagsText)
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canSave || saving)
            }
            .padding(14)
        }
        .frame(width: 480, height: 640)
        .onAppear(perform: populate)
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - 连接配置区

    @ViewBuilder
    private var connectionSection: some View {
        if isNew {
            Section("连接") {
                Picker("保存位置", selection: $destination) {
                    ForEach(Destination.allCases) { d in
                        Text(d.label).tag(d)
                    }
                }
                connectionFields(full: destination == .sshConfig)
                if destination == .sshConfig {
                    blockPreview
                }
            }
        } else if isConfigSourced {
            Section("连接 — ~/.ssh/config") {
                if configEditable {
                    connectionFields(full: true)
                    Text("保存时写回 ~/.ssh/config:自动备份到 Application Support/Helm/config-backups,校验失败自动回滚")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    if let entry = engine.host(alias: alias)?.configEntry {
                        LabeledContent("地址", value: entry.hostName ?? "—")
                        if let u = entry.user { LabeledContent("用户", value: u) }
                        if let j = entry.proxyJump { LabeledContent("跳板", value: j) }
                    }
                    Text("该 Host 块包含多个别名或通配模式,改动会影响其他主机——请直接在文件中修改")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Section("连接") {
                connectionFields(full: false)
            }
        }
    }

    @ViewBuilder
    private func connectionFields(full: Bool) -> some View {
        TextField("主机地址", text: $hostName)
        TextField("用户名(可选)", text: $user)
        TextField("端口(默认 22)", text: $port)
        if full {
            if proxyCommandManaged {
                LabeledContent("跳板", value: "由 ProxyCommand 管理,此处不可编辑")
                    .font(.callout)
            } else {
                TextField("跳板机 ProxyJump(可选)", text: $proxyJump)
            }
            TextField("身份文件 IdentityFile(可选)", text: $identityFile)
        }
    }

    private var blockPreview: some View {
        Text(previewText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private var previewText: String {
        var lines = ["Host \(alias.isEmpty ? "<别名>" : alias)"]
        if !hostName.isEmpty { lines.append("    HostName \(hostName)") }
        if !user.isEmpty { lines.append("    User \(user)") }
        if let p = Int(port), p != 22 { lines.append("    Port \(p)") }
        if !proxyJump.isEmpty { lines.append("    ProxyJump \(proxyJump)") }
        if !identityFile.isEmpty { lines.append("    IdentityFile \(SSHConfigDocument.quoteIfNeeded(identityFile))") }
        return lines.joined(separator: "\n")
    }

    // MARK: -

    private func populate() {
        guard let meta = originalMeta else { return }
        alias = meta.alias
        displayName = meta.displayName ?? ""
        auth = meta.auth
        tagsText = meta.tags.joined(separator: ", ")
        gpuEnabled = meta.capabilities.contains(.gpu)
        slurmEnabled = meta.capabilities.contains(.slurm)
        notes = meta.notes
        hasStoredPassword = KeychainStore.hasPassword(for: meta.alias)

        if meta.source == .sshConfig {
            configEditable = engine.configBlockEditable(alias: meta.alias)
            let entry = engine.host(alias: meta.alias)?.configEntry
            hostName = entry?.hostName ?? ""
            user = entry?.user ?? ""
            port = entry?.port.map(String.init) ?? ""
            identityFile = entry?.identityFile ?? ""
            if entry?.proxyJump == "(ProxyCommand)" {
                proxyCommandManaged = true
            } else {
                proxyJump = entry?.proxyJump ?? ""
            }
        } else {
            hostName = meta.hostName ?? ""
            user = meta.user ?? ""
            port = meta.port.map(String.init) ?? ""
        }
    }

    private func save() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        var meta = originalMeta ?? HostMeta(
            alias: trimmedAlias,
            source: destination == .sshConfig ? .sshConfig : .manual)
        meta.displayName = displayName.isEmpty ? nil : displayName
        meta.auth = auth
        meta.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var capabilities: Set<Capability> = []
        if gpuEnabled { capabilities.insert(.gpu) }
        if slurmEnabled { capabilities.insert(.slurm) }
        meta.capabilities = capabilities
        meta.notes = notes
        if auth == .password, !password.isEmpty {
            KeychainStore.setPassword(password, for: meta.alias)
        }
        if auth != .password {
            KeychainStore.deletePassword(for: meta.alias)
        }

        let fields = MonitorEngine.ConfigFields(
            hostName: hostName.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            port: port.trimmingCharacters(in: .whitespaces),
            proxyJump: proxyCommandManaged ? "" : proxyJump.trimmingCharacters(in: .whitespaces),
            identityFile: identityFile.trimmingCharacters(in: .whitespaces))

        // 新增 → 写入 ssh config
        if isNew, destination == .sshConfig {
            saving = true
            Task {
                if let error = await engine.addConfigHost(alias: trimmedAlias, fields: fields, meta: meta) {
                    saveError = error
                    saving = false
                } else {
                    dismiss()
                }
            }
            return
        }
        // 编辑 config 主机 → 写回文件
        if let original = originalMeta, original.source == .sshConfig, configEditable {
            saving = true
            Task {
                if let error = await engine.updateConfigHost(alias: original.alias, fields: fields) {
                    saveError = error
                    saving = false
                } else {
                    engine.addOrUpdate(meta: meta)
                    dismiss()
                }
            }
            return
        }
        // manual 主机 / 不可编辑的 config 块:只更新 Helm 元数据
        if meta.source == .manual {
            meta.hostName = fields.hostName.isEmpty ? nil : fields.hostName
            meta.user = fields.user.isEmpty ? nil : fields.user
            meta.port = Int(fields.port)
        }
        engine.addOrUpdate(meta: meta)
        dismiss()
    }
}
