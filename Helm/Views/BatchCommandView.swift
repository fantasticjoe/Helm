import AppKit
import SwiftUI

struct BatchCommandView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.panelDismiss) private var dismiss
    @State private var runner = BatchRunner()
    @State private var command = ""
    @State private var selection: Set<String> = []
    @FocusState private var commandFocused: Bool

    private var selectedHosts: [Host] {
        engine.hosts.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("批量命令", systemImage: "square.stack.3d.down.right")
                    .font(.headline)
                Spacer()
                Text("\(selection.count) 台主机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                hostPicker
                    .frame(width: 200)
                Divider()
                VStack(spacing: 0) {
                    commandBar
                    Divider()
                    results
                }
            }
        }
        .frame(width: 760, height: 540)
        .onAppear {
            // 默认选中当前在线的主机
            selection = Set(engine.hosts
                .filter { engine.status(for: $0).state == .online }
                .map(\.id))
            commandFocused = true
        }
    }

    private var hostPicker: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(engine.hosts) { host in
                        Toggle(isOn: binding(for: host.id)) {
                            HStack(spacing: 7) {
                                StatusDot(state: engine.status(for: host).state, size: 7)
                                Text(host.name)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            HStack {
                Button("全选") { selection = Set(engine.hosts.map(\.id)) }
                Button("仅在线") {
                    selection = Set(engine.hosts
                        .filter { engine.status(for: $0).state == .online }
                        .map(\.id))
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(8)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            TextField("在所选主机上执行的命令…", text: $command)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .focused($commandFocused)
                .onSubmit(runCommand)
            if !runner.history.isEmpty {
                Menu {
                    ForEach(runner.history, id: \.self) { item in
                        Button(item) { command = item }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("最近使用的命令")
            }
            Button("执行", action: runCommand)
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning
                          || command.trimmingCharacters(in: .whitespaces).isEmpty
                          || selection.isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if runner.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("勾选主机,输入命令,回车执行")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("命令通过已建立的连接执行,不会触发新的认证;未连接的主机会快速失败")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(runner.entries) { entry in
                        BatchResultCard(entry: entry)
                    }
                }
                .padding(12)
            }
        }
    }

    private func runCommand() {
        runner.run(command: command, hosts: selectedHosts)
    }

    private func binding(for alias: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(alias) },
            set: { included in
                if included { selection.insert(alias) } else { selection.remove(alias) }
            })
    }
}

private struct BatchResultCard: View {
    let entry: BatchRunner.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stateIcon
                Text(entry.host.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                if case .done = entry.state {
                    if let duration = entry.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.stdout, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("复制输出")
                }
            }
            if case .done(let success) = entry.state {
                outputBody(success: success)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch entry.state {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done(true):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .done(false):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func outputBody(success: Bool) -> some View {
        let stdout = entry.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty && stderr.isEmpty {
            Text(entry.timedOut ? "(执行超时)" : success ? "(无输出)" : "(退出码 \(entry.exitCode ?? -1),无输出)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !stdout.isEmpty {
                        Text(stdout)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !stderr.isEmpty {
                        Text(stderr)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}
