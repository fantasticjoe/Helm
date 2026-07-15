import SwiftUI

struct HostEditorView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var alias = ""
    @State private var displayName = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var auth: AuthKind = .key
    @State private var tagsText = ""
    @State private var gpuEnabled = false
    @State private var slurmEnabled = false
    @State private var notes = ""
    @State private var password = ""
    @State private var hasStoredPassword = false

    private var originalMeta: HostMeta? {
        if case .edit(let meta) = target { return meta }
        return nil
    }

    private var isConfigSourced: Bool { originalMeta?.source == .sshConfig }

    private var canSave: Bool {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else { return false }
        if originalMeta == nil {
            // 新增时 alias 不能与现有主机重复
            guard engine.host(alias: trimmedAlias) == nil else { return false }
            return !hostName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(originalMeta == nil ? "添加主机" : "编辑 \(originalMeta!.alias)")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)
            Form {
                Section("基本") {
                    TextField("别名", text: $alias)
                        .disabled(originalMeta != nil)
                    TextField("显示名称(可选)", text: $displayName)
                    if isConfigSourced {
                        if let entry = engine.host(alias: alias)?.configEntry {
                            LabeledContent("地址", value: entry.hostName ?? "—")
                            if let u = entry.user { LabeledContent("用户", value: u) }
                            if let j = entry.proxyJump { LabeledContent("跳板", value: j) }
                            Text("连接参数来自 ~/.ssh/config,请在该文件中修改")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        TextField("主机地址", text: $hostName)
                        TextField("用户名(可选)", text: $user)
                        TextField("端口(默认 22)", text: $port)
                    }
                }
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
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 460, height: 600)
        .onAppear(perform: populate)
    }

    private func populate() {
        guard let meta = originalMeta else { return }
        alias = meta.alias
        displayName = meta.displayName ?? ""
        hostName = meta.hostName ?? ""
        user = meta.user ?? ""
        port = meta.port.map(String.init) ?? ""
        auth = meta.auth
        tagsText = meta.tags.joined(separator: ", ")
        gpuEnabled = meta.capabilities.contains(.gpu)
        slurmEnabled = meta.capabilities.contains(.slurm)
        notes = meta.notes
        hasStoredPassword = KeychainStore.hasPassword(for: meta.alias)
    }

    private func save() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        var meta = originalMeta ?? HostMeta(alias: trimmedAlias, source: .manual)
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
        if meta.source == .manual {
            meta.hostName = hostName.trimmingCharacters(in: .whitespaces)
            meta.user = user.isEmpty ? nil : user
            meta.port = Int(port)
        }
        if auth == .password, !password.isEmpty {
            KeychainStore.setPassword(password, for: meta.alias)
        }
        if auth != .password {
            // 切换走密码认证后清掉旧密码,避免钥匙串残留
            KeychainStore.deletePassword(for: meta.alias)
        }
        engine.addOrUpdate(meta: meta)
        dismiss()
    }
}
