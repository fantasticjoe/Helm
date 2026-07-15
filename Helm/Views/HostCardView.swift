import SwiftUI

struct HostCardView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    let host: Host
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onBrowse: () -> Void

    @State private var confirmDelete = false

    private var status: HostStatus { engine.status(for: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let metrics = status.metrics {
                metricsGrid(metrics)
            } else {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            footer
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("查看详情") { onOpen() }
            Button("打开终端") { SessionLauncher.open(host, openWindow: openWindow) }
            Button("浏览文件…") { onBrowse() }
            Button("立即刷新") { Task { await engine.refresh(host) } }
            if host.meta.capabilities.contains(.gpu) || !(status.metrics?.gpus.isEmpty ?? true) {
                Button(host.meta.isWatchingGPU ? "取消 GPU 空闲提醒" : "GPU 空闲时提醒我") {
                    engine.setGPUWatch(alias: host.id, enabled: !host.meta.isWatchingGPU)
                }
            }
            Divider()
            Button("编辑…") { onEdit() }
            if status.state == .online || status.masterAlive {
                Button("断开连接") { engine.disconnect(host) }
            }
            Divider()
            Button("删除主机…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(
            "删除主机 \u{201C}\(host.name)\u{201D}?",
            isPresented: $confirmDelete
        ) {
            Button("仅从 Helm 删除", role: .destructive) { engine.remove(alias: host.id) }
            if host.meta.source == .sshConfig && engine.configBlockEditable(alias: host.id) {
                Button("同时从 ssh config 移除", role: .destructive) {
                    Task {
                        if let error = await engine.removeFromConfig(alias: host.id) {
                            NotificationService.post(title: "移除失败", body: error)
                        }
                    }
                }
            }
        } message: {
            Text("两种方式都会删除钥匙串中保存的密码;「仅从 Helm 删除」不改动 ~/.ssh/config。")
        }
        .animation(.easeInOut(duration: 0.2), value: status.state)
    }

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(state: status.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(host.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if host.meta.isWatchingGPU {
                Image(systemName: "bell.badge.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("正在监视空闲 GPU,发现即提醒")
            }
            ForEach(Array(host.meta.capabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { cap in
                CapabilityChip(text: cap.label)
            }
            Image(systemName: host.meta.auth.symbolName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("认证方式:\(host.meta.auth.label)")
        }
    }

    private func metricsGrid(_ metrics: HostMetrics) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            alignment: .leading, spacing: 10
        ) {
            if let load = metrics.load1 {
                MetricCell(label: "负载", value: String(format: "%.2f", load))
            }
            if let memPercent = metrics.memUsedPercent, let total = metrics.memTotalMB {
                MetricCell(
                    label: "内存 \(gigabytesFromMB(total))",
                    value: "\(memPercent)%",
                    percent: memPercent)
            }
            if let disk = metrics.worstDisk {
                MetricCell(
                    label: "磁盘 \(disk.mount)",
                    value: "\(disk.usedPercent)%",
                    percent: disk.usedPercent)
            }
            if let gpu = metrics.averageGPUUtilization {
                MetricCell(
                    label: metrics.gpus.count > 1 ? "GPU ×\(metrics.gpus.count)" : "GPU",
                    value: "\(gpu)%",
                    percent: gpu)
            }
            if host.meta.capabilities.contains(.slurm) || !metrics.slurmJobs.isEmpty {
                MetricCell(
                    label: "作业",
                    value: "\(metrics.runningJobs) R · \(metrics.pendingJobs) PD")
            }
            if !metrics.users.isEmpty {
                MetricCell(label: "在线用户", value: "\(metrics.users.count) 人")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch status.state {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text("连接中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .online:
                Button("断开") { engine.disconnect(host) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            default:
                Button("连接") { engine.connect(host) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button {
                SessionLauncher.open(host, openWindow: openWindow)
            } label: {
                Label("终端", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            if let updated = status.metrics?.updatedAt {
                Text(updated, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hint: String {
        switch status.state {
        case .connecting: return "连接中…"
        case .unreachable: return status.lastError ?? "无法连接"
        case .authFailed: return "认证失败 — 请检查保存的密码"
        case .online: return "已连接,等待首次监控数据…"
        case .disconnected:
            switch host.meta.auth {
            case .key: return "等待检测…"
            case .password: return "待连接 — 点击「连接」使用钥匙串中的密码"
            case .interactive: return "待连接 — 点击「连接」在终端中完成认证"
            }
        }
    }
}
