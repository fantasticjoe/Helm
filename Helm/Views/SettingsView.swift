import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.pollInterval) private var pollInterval = 60.0
    @AppStorage(SettingsKeys.preferredTerminal) private var preferredTerminal = ""
    @AppStorage(SettingsKeys.diskThreshold) private var diskThreshold = 90
    @AppStorage(SettingsKeys.notifyOffline) private var notifyOffline = true
    @AppStorage(SettingsKeys.notifyDisk) private var notifyDisk = true

    var body: some View {
        Form {
            Section("监控") {
                Picker("轮询间隔", selection: $pollInterval) {
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("2 分钟").tag(120.0)
                    Text("5 分钟").tag(300.0)
                }
                Slider(
                    value: Binding(
                        get: { Double(diskThreshold) },
                        set: { diskThreshold = Int($0) }),
                    in: 70...95, step: 5
                ) {
                    Text("磁盘告警阈值:\(diskThreshold)%")
                }
            }
            Section("通知") {
                Toggle("磁盘超过阈值时通知", isOn: $notifyDisk)
                Toggle("主机掉线时通知", isOn: $notifyOffline)
            }
            Section("终端") {
                Picker("打开会话使用", selection: $preferredTerminal) {
                    Text("内嵌终端").tag(TerminalLauncher.builtinValue)
                    ForEach(TerminalLauncher.TerminalApp.allCases.filter(\.isInstalled)) { app in
                        Text(app.rawValue).tag(app.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}
