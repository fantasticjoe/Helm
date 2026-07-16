import AppKit
import SwiftTerm
import SwiftUI

/// 主窗口 detail 区的内嵌终端面板:SwiftTerm 跑 ssh,带 ControlPath 复用 master。
/// 注意:该视图靠 opacity 切换显隐——一旦移出视图层级,PTY 关闭、会话结束。
struct TerminalTabView: View {
    @Environment(MonitorEngine.self) private var engine
    let tab: TerminalTab

    @State private var sessionEnded = false

    var body: some View {
        if let host = engine.host(alias: tab.alias) {
            VStack(spacing: 0) {
                SSHTerminal(
                    host: host,
                    title: Binding(
                        get: { tab.title },
                        set: { engine.updateTerminalTabTitle(tab.id, title: $0) }),
                    sessionEnded: $sessionEnded)
                if sessionEnded {
                    // 已结束的会话上报引擎,关闭时免二次确认
                    Color.clear.frame(height: 0)
                        .onAppear { engine.markTerminalTabEnded(tab.id) }
                    Divider()
                    HStack {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.secondary)
                        Text("会话已结束")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新连接") { engine.reopenTerminalTab(tab.id) }
                            .buttonStyle(HelmButtonStyle())
                        Button("关闭标签页") { engine.closeTerminalTab(tab.id) }
                            .buttonStyle(HelmButtonStyle())
                    }
                    .padding(8)
                }
            }
        } else {
            ContentUnavailableView("主机已删除", systemImage: "questionmark.circle")
        }
    }
}

struct SSHTerminal: NSViewRepresentable {
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
