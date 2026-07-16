import SwiftUI

struct PasswordPromptView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let alias: String
    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("连接 \(alias)")
                .font(.headline)
            Text("密码将存入 macOS 钥匙串,仅 Helm 可静默读取;其他程序访问会触发系统授权弹窗。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("账户密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(saveAndConnect)
            HStack {
                Button("取消") {
                    engine.passwordRequest = nil
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("保存并连接", action: saveAndConnect)
                    .buttonStyle(HelmButtonStyle(prominent: true))
                    .disabled(password.isEmpty)
            }
        }
        .buttonStyle(HelmButtonStyle())
        .padding(22)
        .frame(width: 340)
        .onAppear { fieldFocused = true }
    }

    private func saveAndConnect() {
        guard !password.isEmpty else { return }
        engine.savePasswordAndConnect(alias: alias, password: password)
        dismiss()
    }
}
