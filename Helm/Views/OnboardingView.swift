import SwiftUI

struct OnboardingView: View {
    @Environment(MonitorEngine.self) private var engine
    var addManually: () -> Void

    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "helm")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            if engine.pendingImport.isEmpty {
                Text("还没有主机")
                    .font(.title3.bold())
                Text("~/.ssh/config 中没有发现可导入的主机")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("手动添加主机", action: addManually)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("在 ~/.ssh/config 中发现 \(engine.pendingImport.count) 台主机")
                    .font(.title3.bold())
                Text("选择要纳入 Helm 管理的主机 — 不会改动你的 ssh 配置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ImportListView(selection: $selection)
                    .frame(maxWidth: 440, maxHeight: 240)
                HStack(spacing: 12) {
                    Button("全选") {
                        selection = Set(engine.pendingImport.map(\.alias))
                    }
                    Button("导入 \(selection.count) 台主机") {
                        engine.importEntries(aliases: selection)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
                }
                Button("或手动添加主机", action: addManually)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selection = Set(engine.pendingImport.map(\.alias)) }
    }
}
