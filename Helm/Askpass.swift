import AppKit
import Foundation

/// SSH_ASKPASS 入口。Helm 以自身可执行文件作为 askpass 程序传给 ssh,
/// 因此读取 Keychain 的代码身份与主 app 完全一致,无需给第二个二进制授权。
///
/// 提示分流:
/// - 密码类提示 → 优先 Keychain,缺失时弹原生密码框
/// - 2FA/验证码等其他提示 → 弹原生输入框(明文,便于核对验证码)
/// - passphrase / yes-no 确认 → 拒绝(密钥口令交给 agent,host key 由 accept-new 处理)
@MainActor
enum Askpass {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["HELM_ASKPASS"] == "1" else { return }

        let rawPrompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let prompt = rawPrompt.lowercased()
        guard let alias = env["HELM_HOST_ALIAS"], !alias.isEmpty else { exit(1) }

        if prompt.contains("passphrase") || prompt.contains("yes/no") { exit(1) }

        if prompt.contains("password") || prompt.contains("密码") {
            if let password = KeychainStore.password(for: alias) {
                emit(password)
            }
            if let typed = presentDialog(
                title: "输入密码 — \(alias)",
                prompt: rawPrompt,
                secure: true) {
                emit(typed)
            }
            exit(1)
        }

        // 2FA / 验证码 / Duo 选项等交互提示
        if let typed = presentDialog(
            title: "SSH 验证 — \(alias)",
            prompt: rawPrompt,
            secure: false) {
            emit(typed)
        }
        exit(1)
    }

    private static func emit(_ response: String) -> Never {
        FileHandle.standardOutput.write(Data(response.utf8))
        exit(0)
    }

    private static func presentDialog(title: String, prompt: String, secure: Bool) -> String? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = prompt.isEmpty ? "服务器请求额外验证" : prompt
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")

        let frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let field: NSTextField = secure ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        app.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }
}
