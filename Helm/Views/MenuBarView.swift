import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingDisconnectAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "helm")
                    .foregroundStyle(Color.accentColor)
                Text("Helm")
                    .font(.headline)
                Spacer()
                Text("\(engine.onlineCount)/\(engine.totalCount) 在线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if engine.hosts.isEmpty {
                Text("还没有主机 — 打开 Helm 导入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(engine.hosts) { host in
                            MenuBarHostRow(host: host)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Button("打开 Helm") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                // 内联二段式确认:第一次点变红提示,3 秒不点自动还原
                Button(confirmingDisconnectAll ? "确认全部断开?" : "全部断开") {
                    if confirmingDisconnectAll {
                        engine.disconnectAll()
                        confirmingDisconnectAll = false
                    } else {
                        confirmingDisconnectAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            confirmingDisconnectAll = false
                        }
                    }
                }
                .foregroundStyle(confirmingDisconnectAll ? .red : .primary)
                .animation(.easeOut(duration: 0.12), value: confirmingDisconnectAll)
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(10)
        }
        .frame(width: 300)
    }
}

private struct MenuBarHostRow: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    let host: Host

    private var status: HostStatus { engine.status(for: host) }

    private var summary: String? {
        guard let metrics = status.metrics else { return nil }
        var parts: [String] = []
        if let load = metrics.load1 { parts.append(String(format: "L %.1f", load)) }
        if let gpu = metrics.averageGPUUtilization { parts.append("GPU \(gpu)%") }
        if let disk = metrics.worstDisk { parts.append("盘 \(disk.usedPercent)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: status.state, size: 7)
            Text(host.name)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if let summary {
                Text(summary)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if status.state == .connecting {
                ProgressView().controlSize(.mini)
            }
            if status.state != .online && status.state != .connecting {
                Button {
                    engine.connect(host)
                } label: {
                    Image(systemName: "bolt")
                }
                .buttonStyle(.borderless)
                .help("建立连接")
            }
            Button {
                // 内嵌 Tab 在主窗口里,先确保主窗口在前
                if TerminalLauncher.useBuiltin {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                engine.openTerminal(host)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("打开终端会话")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .hoverHighlight(cornerRadius: 6)
        .padding(.horizontal, 6)
    }
}
