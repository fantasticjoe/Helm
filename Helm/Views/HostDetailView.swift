import SwiftUI

struct HostDetailView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
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
                .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    connectionInfo
                    if host.meta.auth != .key {
                        keyMigration
                    }
                    if let metrics = status.metrics {
                        metricsSections(metrics)
                    }
                    if let error = status.lastError {
                        GroupBox("最近错误") {
                            Text(error)
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            footer
                .padding(14)
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

    private var keyMigration: some View {
        GroupBox("迁移到密钥登录") {
            HStack(spacing: 10) {
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
                     ? "写入远端 authorized_keys,之后可免密登录"
                     : "需要先建立连接")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(state: status.state, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.title2.bold())
                HStack(spacing: 6) {
                    Text(status.state.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.state.color)
                    Text(host.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
                // 内嵌 Tab 在主窗口里,关掉详情页让用户直接看到终端
                dismiss()
            } label: {
                Label("终端", systemImage: "terminal")
            }
            Button {
                onBrowse(host)
            } label: {
                Label("文件", systemImage: "folder")
            }
            Button("编辑") { onEdit(host.meta) }
        }
    }

    private var connectionInfo: some View {
        GroupBox("连接信息") {
            VStack(spacing: 6) {
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
            .font(.callout)
        }
    }

    @ViewBuilder
    private func metricsSections(_ metrics: HostMetrics) -> some View {
        GroupBox("系统") {
            VStack(spacing: 6) {
                if let l1 = metrics.load1, let l5 = metrics.load5, let l15 = metrics.load15 {
                    LabeledContent("负载", value: String(format: "%.2f · %.2f · %.2f", l1, l5, l15))
                }
                if let percent = metrics.memUsedPercent,
                   let total = metrics.memTotalMB, let avail = metrics.memAvailableMB {
                    VStack(spacing: 4) {
                        LabeledContent("内存") {
                            Text("\(percent)% · 可用 \(gigabytesFromMB(avail)) / \(gigabytesFromMB(total))")
                                .monospacedDigit()
                        }
                        CapacityBar(fraction: Double(percent) / 100, tint: usageColor(percent))
                    }
                }
                if !metrics.users.isEmpty {
                    LabeledContent("在线用户", value: metrics.users.joined(separator: ", "))
                }
                LabeledContent("更新于") {
                    Text(metrics.updatedAt, format: .dateTime.hour().minute().second())
                }
            }
            .font(.callout)
        }

        if !metrics.disks.isEmpty {
            GroupBox("磁盘") {
                VStack(spacing: 8) {
                    ForEach(metrics.disks.sorted { $0.usedPercent > $1.usedPercent }, id: \.mount) { disk in
                        VStack(spacing: 3) {
                            HStack {
                                Text(disk.mount)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(disk.usedPercent)% · \(gigabytesFromKB(disk.usedKB)) / \(gigabytesFromKB(disk.totalKB))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            CapacityBar(fraction: Double(disk.usedPercent) / 100, tint: usageColor(disk.usedPercent))
                        }
                    }
                }
            }
        }

        if !metrics.gpus.isEmpty {
            GroupBox("GPU") {
                VStack(spacing: 8) {
                    Toggle("有 GPU 空闲时提醒我一次(利用率 ≤10% 且显存基本空置)", isOn: Binding(
                        get: { host.meta.isWatchingGPU },
                        set: { engine.setGPUWatch(alias: host.id, enabled: $0) }))
                        .font(.caption)
                    ForEach(metrics.gpus, id: \.index) { gpu in
                        VStack(spacing: 3) {
                            HStack {
                                Text("#\(gpu.index) \(gpu.name)")
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(gpu.utilization)% · 显存 \(gigabytesFromMB(gpu.memUsedMB)) / \(gigabytesFromMB(gpu.memTotalMB))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            CapacityBar(fraction: Double(gpu.utilization) / 100, tint: usageColor(gpu.utilization))
                        }
                    }
                }
            }
        }

        if !metrics.slurmJobs.isEmpty {
            GroupBox("SLURM 作业") {
                VStack(spacing: 4) {
                    ForEach(metrics.slurmJobs, id: \.id) { job in
                        HStack {
                            Text(job.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(job.name)
                                .font(.callout)
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
