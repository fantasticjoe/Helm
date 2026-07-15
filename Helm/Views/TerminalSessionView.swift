import AppKit
import SwiftTerm
import SwiftUI

/// 一次内嵌终端会话的窗口参数。id 保证同一主机可以开多个窗口。
struct TerminalSessionRequest: Codable, Hashable {
    var id = UUID()
    var alias: String
}

/// 内嵌终端窗口内容:SwiftTerm 跑 ssh,带 ControlPath 复用 master。
struct TerminalWindow: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let request: TerminalSessionRequest

    @State private var title = ""
    @State private var sessionEnded = false

    var body: some View {
        if let host = engine.host(alias: request.alias) {
            VStack(spacing: 0) {
                SSHTerminal(host: host, title: $title, sessionEnded: $sessionEnded)
                if sessionEnded {
                    Divider()
                    HStack {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.secondary)
                        Text("会话已结束")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭窗口") { dismiss() }
                            .controlSize(.small)
                    }
                    .padding(8)
                }
            }
            .navigationTitle(title.isEmpty ? host.name : title)
            .frame(minWidth: 480, minHeight: 300)
        } else {
            ContentUnavailableView("主机不存在", systemImage: "questionmark.circle")
                .frame(minWidth: 480, minHeight: 300)
        }
    }
}

private struct SSHTerminal: NSViewRepresentable {
    let host: Host
    @Binding var title: String
    @Binding var sessionEnded: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(title: $title, sessionEnded: $sessionEnded)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = context.coordinator

        // 完整继承 app 环境(含 SSH_AUTH_SOCK),补上终端类型
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        view.startProcess(
            executable: SSHService.sshPath,
            args: SSHService.sessionArgs(for: host),
            environment: envArray,
            execName: nil)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private let title: Binding<String>
        private let sessionEnded: Binding<Bool>

        init(title: Binding<String>, sessionEnded: Binding<Bool>) {
            self.title = title
            self.sessionEnded = sessionEnded
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title newTitle: String) {
            let binding = title
            DispatchQueue.main.async { binding.wrappedValue = newTitle }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let binding = sessionEnded
            DispatchQueue.main.async { binding.wrappedValue = true }
        }
    }
}
