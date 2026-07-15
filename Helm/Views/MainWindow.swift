import SwiftUI

enum SidebarFilter: Hashable {
    case all
    case tag(String)
}

enum EditorTarget: Identifiable {
    case new
    case edit(HostMeta)

    var id: String {
        switch self {
        case .new: "@new"
        case .edit(let meta): meta.alias
        }
    }
}

struct MainWindow: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var filter: SidebarFilter? = .all
    @State private var searchText = ""
    @State private var selectedHost: Host?
    @State private var editorTarget: EditorTarget?
    @State private var importPresented = false
    @State private var batchPresented = false
    @State private var fileBrowserHost: Host?

    private var filteredHosts: [Host] {
        var hosts = engine.hosts
        if case .tag(let tag) = filter {
            hosts = hosts.filter { $0.meta.tags.contains(tag) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hosts }
        return hosts.filter { host in
            host.name.localizedCaseInsensitiveContains(query)
                || host.meta.alias.localizedCaseInsensitiveContains(query)
                || (host.effectiveHostName?.localizedCaseInsensitiveContains(query) ?? false)
                || host.meta.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            SidebarView(filter: $filter)
        } detail: {
            detailContent
                .navigationTitle(navigationTitle)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机、地址或标签")
        .toolbar {
            if !engine.pendingImport.isEmpty && !engine.hosts.isEmpty {
                ToolbarItem {
                    Button {
                        importPresented = true
                    } label: {
                        Label("导入 \(engine.pendingImport.count) 台新主机", systemImage: "square.and.arrow.down")
                    }
                    .help("在 ~/.ssh/config 中发现尚未导入的主机")
                }
            }
            // 会话操作一组
            ToolbarItemGroup {
                Button {
                    engine.quickConnectPresented = true
                } label: {
                    Label("快速连接", systemImage: "bolt")
                }
                .keyboardShortcut("k")
                .help("快速连接 (⌘K)")
                Button {
                    batchPresented = true
                } label: {
                    Label("批量命令", systemImage: "square.stack.3d.down.right")
                }
                .keyboardShortcut("b")
                .help("在多台主机上执行同一条命令 (⌘B)")
                .disabled(engine.hosts.isEmpty)
            }
            // 视图与新建各自独立成组
            ToolbarItem {
                Button {
                    Task { await engine.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("立即刷新全部主机 (⌘R)")
            }
            ToolbarItem {
                Button {
                    editorTarget = .new
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("添加主机 (⌘N)")
            }
        }
        .sheet(item: $selectedHost) { host in
            HostDetailView(initial: host) { meta in
                selectedHost = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    editorTarget = .edit(meta)
                }
            } onBrowse: { browseHost in
                selectedHost = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    fileBrowserHost = browseHost
                }
            }
        }
        .sheet(item: $fileBrowserHost) { host in
            FileBrowserView(host: host)
        }
        .sheet(item: $editorTarget) { target in
            HostEditorView(target: target)
        }
        .sheet(isPresented: $engine.quickConnectPresented) {
            QuickConnectView()
        }
        .sheet(item: $engine.passwordRequest) { request in
            PasswordPromptView(alias: request.alias)
        }
        .sheet(isPresented: $importPresented) {
            ImportSheet()
        }
        .sheet(isPresented: $batchPresented) {
            BatchCommandView()
        }
    }

    private var navigationTitle: String {
        if case .tag(let tag) = filter { return tag }
        return "全部主机"
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            if !engine.terminalTabs.isEmpty {
                TerminalTabBar()
                Divider()
            }
            // opacity 切换而非 if-else:终端 NSView 必须常驻层级,否则会话被杀
            ZStack {
                hostsContent
                    .opacity(engine.selectedTab == .hosts ? 1 : 0)
                    .allowsHitTesting(engine.selectedTab == .hosts)
                ForEach(engine.terminalTabs) { tab in
                    TerminalTabView(tab: tab)
                        .opacity(engine.selectedTab == .terminal(tab.id) ? 1 : 0)
                        .allowsHitTesting(engine.selectedTab == .terminal(tab.id))
                }
            }
        }
    }

    private var onlineHosts: [Host] {
        filteredHosts.filter { host in
            let state = engine.status(for: host).state
            return state == .online || state == .connecting
        }
    }

    private var offlineHosts: [Host] {
        filteredHosts.filter { host in
            let state = engine.status(for: host).state
            return state != .online && state != .connecting
        }
    }

    @ViewBuilder
    private var hostsContent: some View {
        if engine.hosts.isEmpty {
            OnboardingView { editorTarget = .new }
        } else if filteredHosts.isEmpty {
            ContentUnavailableView("没有匹配的主机", systemImage: "magnifyingglass")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !onlineHosts.isEmpty {
                        sectionHeader("在线", count: onlineHosts.count, dotColor: .green)
                        hostGrid(onlineHosts)
                    }
                    if !offlineHosts.isEmpty {
                        sectionHeader("未连接", count: offlineHosts.count, dotColor: .gray.opacity(0.45))
                            .padding(.top, onlineHosts.isEmpty ? 0 : 10)
                        hostGrid(offlineHosts)
                    }
                }
                .padding(20)
                .animation(.default, value: onlineHosts.map(\.id))
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, dotColor: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func hostGrid(_ hosts: [Host]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 310, maximum: 480), spacing: 16)],
            spacing: 16
        ) {
            ForEach(hosts) { host in
                HostCardView(
                    host: host,
                    onOpen: { selectedHost = host },
                    onEdit: { editorTarget = .edit(host.meta) },
                    onBrowse: { fileBrowserHost = host })
            }
        }
    }
}

/// detail 区顶部的终端 Tab 栏:「主机」固定第一个,每个会话一个 chip。
struct TerminalTabBar: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                TabChipFrame(selected: engine.selectedTab == .hosts) {
                    engine.selectedTab = .hosts
                } content: {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption)
                    Text("主机")
                        .font(.caption)
                }
                ForEach(engine.terminalTabs) { tab in
                    TerminalTabChip(tab: tab)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct TerminalTabChip: View {
    @Environment(MonitorEngine.self) private var engine
    let tab: TerminalTab

    var body: some View {
        TabChipFrame(selected: engine.selectedTab == .terminal(tab.id)) {
            engine.selectedTab = .terminal(tab.id)
        } content: {
            if let host = engine.host(alias: tab.alias) {
                StatusDot(state: engine.status(for: host).state, size: 6)
            }
            Text(tab.title.isEmpty ? tab.alias : tab.title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 150)
            Button {
                engine.closeTerminalTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("关闭标签页")
        }
    }
}

private struct TabChipFrame<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture(perform: action)
    }
}

struct SidebarView: View {
    @Environment(MonitorEngine.self) private var engine
    @Binding var filter: SidebarFilter?

    var body: some View {
        List(selection: $filter) {
            Label("全部主机", systemImage: "square.grid.2x2")
                .tag(SidebarFilter.all)
                .badge(engine.totalCount)
            if !engine.allTags.isEmpty {
                Section("标签") {
                    ForEach(engine.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .tag(SidebarFilter.tag(tag))
                            .badge(engine.hosts.filter { $0.meta.tags.contains(tag) }.count)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(engine.onlineCount)/\(engine.totalCount) 在线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

struct ImportSheet: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 16) {
            Text("从 ssh config 导入主机")
                .font(.headline)
            ImportListView(selection: $selection)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("全选") { selection = Set(engine.pendingImport.map(\.alias)) }
                Button("导入 \(selection.count) 台") {
                    engine.importEntries(aliases: selection)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 460)
        .onAppear { selection = Set(engine.pendingImport.map(\.alias)) }
    }
}

struct ImportListView: View {
    @Environment(MonitorEngine.self) private var engine
    @Binding var selection: Set<String>

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(engine.pendingImport, id: \.alias) { entry in
                    Toggle(isOn: binding(for: entry.alias)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.alias).font(.callout.weight(.medium))
                            Text(subtitle(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func binding(for alias: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(alias) },
            set: { included in
                if included { selection.insert(alias) } else { selection.remove(alias) }
            })
    }

    private func subtitle(for entry: SSHConfigEntry) -> String {
        var core = entry.hostName ?? entry.alias
        if let user = entry.user { core = "\(user)@\(core)" }
        if let jump = entry.proxyJump { core += " · 经 \(jump)" }
        return core
    }
}
