import SwiftUI

struct QuickConnectView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [Host] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return engine.hosts }
        return engine.hosts.filter { host in
            host.name.localizedCaseInsensitiveContains(trimmed)
                || host.meta.alias.localizedCaseInsensitiveContains(trimmed)
                || (host.effectiveHostName?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || host.meta.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.secondary)
                TextField("连接到…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = results.first {
                            engine.openTerminal(first)
                            dismiss()
                        }
                    }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                ContentUnavailableView("没有匹配的主机", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { host in
                            Button {
                                engine.openTerminal(host)
                                dismiss()
                            } label: {
                                HStack(spacing: 9) {
                                    StatusDot(state: engine.status(for: host).state, size: 7)
                                    Text(host.name)
                                        .font(.callout.weight(.medium))
                                    Text(host.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "terminal")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            Divider()
            Text("回车打开第一项的终端会话 · Esc 关闭")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(8)
        }
        .frame(width: 460, height: 380)
        .onAppear { searchFocused = true }
    }
}
