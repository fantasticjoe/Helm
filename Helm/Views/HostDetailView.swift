import SwiftUI

struct HostDetailView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.panelDismiss) private var dismiss
    let initial: Host
    var onEdit: (HostMeta) -> Void
    var onBrowse: (Host) -> Void

    @State private var confirmDelete = false
    @State private var installingKey = false
    @State private var keyInstallMessage: String?
    @State private var keyInstallSucceeded = false

    private var host: Host { engine.host(alias: initial.id) ?? initial }
    private var status: HostStatus { engine.status(for: host) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            Form {
                connectionSection
                if host.meta.auth != .key {
                    keyMigrationSection
                }
                if let metrics = status.metrics {
                    systemSection(metrics)
                    if !metrics.disks.isEmpty { diskSection(metrics) }
                    if !metrics.gpus.isEmpty { gpuSection(metrics) }
                    if !metrics.slurmJobs.isEmpty { slurmSection(metrics) }
                }
                if let error = status.lastError {
                    Section("最近错误") {
                        Text(error)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(12)
        }
        .frame(width: 500, height: 580)
        .confirmationDialog("删除主机 \u{201C}\(host.name)\u{201D}?", isPresented: $confirmDelete) {
            Button("仅从 Helm 删除", role: .destructive) {
                engine.remove(alias: host.id)
                dismiss()
            }
            if host.meta.source == .sshConfig && engine.configBlockEditable(alias: host.id) {
                Button("同时从 ssh config 移除", role: .destructive) {
                    Task {
                        if let error = await engine.removeFromConfig(alias: host.id) {
                            NotificationService.post(title: "移除失败", body: error)
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        } message: {
            Text("两种方式都会删除钥匙串中保存的密码;「仅从 Helm 删除」不改动 ~/.ssh/config。")
        }
        .alert(
            keyInstallSucceeded ? "公钥已安装" : "安装公钥失败",
            isPresented: Binding(
                get: { keyInstallMessage != nil },
                set: { if !$0 { keyInstallMessage = nil } })
        ) {
            if keyInstallSucceeded {
                Button("切换为密钥认证") { engine.switchToKeyAuth(alias: host.id) }
                Button("暂不", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(keyInstallMessage ?? "")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(state: status.state, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(status.state.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.state.color)
                    Text(host.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 16)
            switch status.state {
            case .connecting:
                ProgressView().controlSize(.small)
            case .online:
                Button("断开") { engine.disconnect(host) }
            default:
                Button("连接") { engine.connect(host) }
                    .buttonStyle(.borderedProminent)
            }
            Button {
                engine.openTerminal(host)
                dismiss()
            } label: {
                Image(systemName: "terminal")
            }
            .help("打开终端会话")
            Button {
                onBrowse(host)
            } label: {
                Image(systemName: "folder")
            }
            .help("浏览文件")
            Button {
                onEdit(host.meta)
            } label: {
                Image(systemName: "pencil")
            }
            .help("编辑主机")
        }
    }

    // MARK: - 分组内容

    private var connectionSection: some View {
        Section("连接信息") {
            LabeledContent("别名", value: host.meta.alias)
            if let hostName = host.effectiveHostName {
                LabeledContent("地址", value: hostName)
            }
            if let user = host.effectiveUser {
                LabeledContent("用户", value: user)
            }
            if let port = host.effectivePort {
                LabeledContent("端口", value: String(port))
            }
            if let jump = host.proxyJump {
                LabeledContent("跳板", value: jump)
            }
            LabeledContent("认证", value: host.meta.auth.label)
            if host.meta.auth == .password {
                LabeledContent("密码", value: KeychainStore.hasPassword(for: host.meta.alias) ? "已存入钥匙串" : "未保存")
            }
            LabeledContent("来源", value: host.meta.source == .sshConfig ? "~/.ssh/config" : "手动添加")
            if !host.meta.tags.isEmpty {
                LabeledContent("标签", value: host.meta.tags.joined(separator: ", "))
            }
        }
    }

    private var keyMigrationSection: some View {
        Section("迁移到密钥登录") {
            HStack {
                Button {
                    installingKey = true
                    Task {
                        let result = await engine.installPublicKey(host)
                        keyInstallSucceeded = result.success
                        keyInstallMessage = result.message
                        installingKey = false
                    }
                } label: {
                    Label("安装我的公钥", systemImage: "key.viewfinder")
                }
                .disabled(installingKey || !(status.state == .online || status.masterAlive))
                if installingKey {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(status.state == .online || status.masterAlive
                     ? "写入远端 authorized_keys"
                     : "需要先建立连接")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func systemSection(_ metrics: HostMetrics) -> some View {
        Section("系统") {
            if let l1 = metrics.load1, let l5 = metrics.load5, let l15 = metrics.load15 {
                LabeledContent("负载") {
                    Text(String(format: "%.2f · %.2f · %.2f", l1, l5, l15))
                        .monospacedDigit()
                }
            }
            if let percent = metrics.memUsedPercent,
               let total = metrics.memTotalMB, let avail = metrics.memAvailableMB {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("内存") {
                        Text("\(percent)% · 可用 \(gigabytesFromMB(avail)) / \(gigabytesFromMB(total))")
                            .monospacedDigit()
                    }
                    CapacityBar(fraction: Double(percent) / 100, tint: usageColor(percent))
                }
            }
            if !metrics.users.isEmpty {
                LabeledContent("在线用户") {
                    Text(metrics.users.joined(separator: ", "))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("更新于") {
                Text(metrics.updatedAt, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
            }
        }
    }

    private func diskSection(_ metrics: HostMetrics) -> some View {
        Section("磁盘") {
            ForEach(metrics.disks.sorted { $0.usedPercent > $1.usedPercent }, id: \.mount) { disk in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(disk.mount)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(disk.usedPercent)% · \(gigabytesFromKB(disk.usedKB)) / \(gigabytesFromKB(disk.totalKB))")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    CapacityBar(fraction: Double(disk.usedPercent) / 100, tint: usageColor(disk.usedPercent))
                }
            }
        }
    }

    private func gpuSection(_ metrics: HostMetrics) -> some View {
        Section {
            ForEach(metrics.gpus, id: \.index) { gpu in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("#\(gpu.index) \(gpu.name)")
                            .lineLimit(1)
                        Spacer()
                        Text("\(gpu.utilization)% · 显存 \(gigabytesFromMB(gpu.memUsedMB)) / \(gigabytesFromMB(gpu.memTotalMB))")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    CapacityBar(fraction: Double(gpu.utilization) / 100, tint: usageColor(gpu.utilization))
                }
            }
        } header: {
            HStack {
                Text("GPU")
                Spacer()
                Toggle("空闲时提醒一次", isOn: Binding(
                    get: { host.meta.isWatchingGPU },
                    set: { engine.setGPUWatch(alias: host.id, enabled: $0) }))
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func slurmSection(_ metrics: HostMetrics) -> some View {
        Section("SLURM 作业") {
            ForEach(metrics.slurmJobs, id: \.id) { job in
                HStack {
                    Text(job.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(job.name)
                        .lineLimit(1)
                    Spacer()
                    Text(job.state)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(job.state.uppercased().hasPrefix("R") ? .green : .orange)
                    Text(job.time)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(job.partition)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("删除主机…", role: .destructive) { confirmDelete = true }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
    }
}
