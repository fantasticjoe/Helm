import Foundation
import Observation

struct PasswordRequest: Identifiable, Sendable {
    let alias: String
    var id: String { alias }
}

/// 主窗口 detail 区的一个内嵌终端 Tab。
struct TerminalTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let alias: String
    var title: String
}

enum DetailTab: Hashable, Sendable {
    case hosts
    case terminal(UUID)
}

/// 全局调度中枢:主机清单、状态机、轮询、连接动作、通知阈值。全部 UI 状态在主线程。
@MainActor
@Observable
final class MonitorEngine {
    static let shared = MonitorEngine()

    private(set) var hosts: [Host] = []
    private(set) var statuses: [String: HostStatus] = [:]
    private(set) var pendingImport: [SSHConfigEntry] = []

    var quickConnectPresented = false
    var passwordRequest: PasswordRequest?
    var terminalTabs: [TerminalTab] = []
    var selectedTab: DetailTab = .hosts
    /// 已结束的会话(关闭无需确认)
    private(set) var endedTerminalTabs: Set<UUID> = []
    /// 待确认关闭的活跃会话,由 MainWindow 弹确认框
    var terminalCloseRequest: TerminalTab?

    private var metas: [HostMeta] = []
    private var configEntries: [SSHConfigEntry] = []
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var diskAlerted: Set<String> = []

    var onlineCount: Int { statuses.values.filter { $0.state == .online }.count }
    var totalCount: Int { hosts.count }
    var allTags: [String] {
        Array(Set(hosts.flatMap(\.meta.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func status(for host: Host) -> HostStatus {
        statuses[host.id] ?? HostStatus()
    }

    func host(alias: String) -> Host? {
        hosts.first { $0.id == alias }
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        UserDefaults.standard.register(defaults: [
            SettingsKeys.pollInterval: 60.0,
            SettingsKeys.diskThreshold: 90,
            SettingsKeys.notifyOffline: true,
            SettingsKeys.notifyDisk: true,
        ])

        SSHService.prepareSocketDirectory()
        metas = HostStore.load()
        reloadSSHConfig()
        rebuildHosts()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = max(15.0, UserDefaults.standard.double(forKey: SettingsKeys.pollInterval))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func reloadSSHConfig() {
        configEntries = SSHConfigParser.parseDefaultConfig()
        pendingImport = configEntries.filter { entry in
            !metas.contains { $0.alias == entry.alias }
        }
    }

    private func rebuildHosts() {
        hosts = metas
            .map { meta in
                Host(meta: meta, configEntry: configEntries.first { $0.alias == meta.alias })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for host in hosts where statuses[host.id] == nil {
            statuses[host.id] = HostStatus()
        }
    }

    // MARK: - 清单管理

    func importEntries(aliases: Set<String>) {
        for entry in pendingImport where aliases.contains(entry.alias) {
            metas.append(HostMeta(alias: entry.alias, source: .sshConfig))
        }
        persistAndRebuild()
        Task { await refreshAll() }
    }

    func addOrUpdate(meta: HostMeta) {
        if let index = metas.firstIndex(where: { $0.alias == meta.alias }) {
            metas[index] = meta
        } else {
            metas.append(meta)
        }
        persistAndRebuild()
    }

    func remove(alias: String) {
        if let host = host(alias: alias) {
            Task { await SSHService.closeMaster(host) }
        }
        metas.removeAll { $0.alias == alias }
        statuses.removeValue(forKey: alias)
        KeychainStore.deletePassword(for: alias)
        persistAndRebuild()
    }

    private func persistAndRebuild() {
        HostStore.save(metas)
        reloadSSHConfig()
        rebuildHosts()
    }

    // MARK: - ssh config 可视化编辑

    /// 该主机的 config 块是否允许可视化编辑(单一具名别名的块)。
    func configBlockEditable(alias: String) -> Bool {
        SSHConfigStore.isEditable(alias: alias)
    }

    struct ConfigFields: Sendable {
        var hostName = ""
        var user = ""
        var port = ""
        var proxyJump = ""
        var identityFile = ""
    }

    /// 更新既有主机块的连接字段。返回 nil 表示成功。
    func updateConfigHost(alias: String, fields: ConfigFields) async -> String? {
        let error = await SSHConfigStore.mutate(validateAlias: alias) { document in
            document.setDirective(alias: alias, keyword: "hostname",
                                  value: fields.hostName.isEmpty ? nil : fields.hostName)
            document.setDirective(alias: alias, keyword: "user",
                                  value: fields.user.isEmpty ? nil : fields.user)
            document.setDirective(alias: alias, keyword: "port",
                                  value: Int(fields.port).map(String.init))
            document.setDirective(alias: alias, keyword: "proxyjump",
                                  value: fields.proxyJump.isEmpty ? nil : fields.proxyJump)
            document.setDirective(alias: alias, keyword: "identityfile",
                                  value: fields.identityFile.isEmpty ? nil : fields.identityFile)
        }
        if error == nil { persistAndRebuild() }
        return error
    }

    /// 新增主机块并纳入 Helm 管理。返回 nil 表示成功。
    func addConfigHost(alias: String, fields: ConfigFields, meta: HostMeta) async -> String? {
        var directives: [(String, String)] = []
        if !fields.hostName.isEmpty { directives.append(("hostname", fields.hostName)) }
        if !fields.user.isEmpty { directives.append(("user", fields.user)) }
        if let port = Int(fields.port), port != 22 { directives.append(("port", String(port))) }
        if !fields.proxyJump.isEmpty { directives.append(("proxyjump", fields.proxyJump)) }
        if !fields.identityFile.isEmpty { directives.append(("identityfile", fields.identityFile)) }
        let finalDirectives = directives

        let error = await SSHConfigStore.mutate(validateAlias: alias) { document in
            document.addHostBlock(alias: alias, directives: finalDirectives)
        }
        if error == nil {
            var configMeta = meta
            configMeta.source = .sshConfig
            configMeta.hostName = nil
            configMeta.user = nil
            configMeta.port = nil
            addOrUpdate(meta: configMeta)
        }
        return error
    }

    /// 从 ~/.ssh/config 移除主机块并删除 Helm 记录。返回 nil 表示成功。
    func removeFromConfig(alias: String) async -> String? {
        let error = await SSHConfigStore.mutate(validateAlias: nil) { document in
            document.removeHostBlock(alias: alias)
        }
        if error == nil { remove(alias: alias) }
        return error
    }

    // MARK: - 连接动作

    func connect(_ host: Host) {
        Task { await performConnect(host) }
    }

    private func performConnect(_ host: Host) async {
        guard statuses[host.id]?.state != .connecting else { return }
        if await SSHService.checkMaster(host) {
            setState(host.id, .online)
            await refresh(host)
            return
        }
        setState(host.id, .connecting)

        switch host.meta.auth {
        case .key:
            let result = await SSHService.establishMasterWithKey(host)
            var established = result.succeeded
            if !established { established = await SSHService.checkMaster(host) }
            if established {
                setState(host.id, .online)
                await refresh(host)
            } else {
                let authFailed = result.stderr.lowercased().contains("permission denied")
                failConnect(host.id,
                            error: lastLine(result.stderr),
                            state: authFailed ? .authFailed : .unreachable)
            }

        case .password:
            guard KeychainStore.hasPassword(for: host.meta.alias) else {
                setState(host.id, .disconnected)
                passwordRequest = PasswordRequest(alias: host.meta.alias)
                return
            }
            let result = await SSHService.establishMasterWithStoredPassword(host)
            var established = result.succeeded
            if !established { established = await SSHService.checkMaster(host) }
            if established {
                setState(host.id, .online)
                await refresh(host)
            } else {
                let stderr = result.stderr.lowercased()
                let authFailed = stderr.contains("permission denied") || stderr.contains("authentication")
                failConnect(host.id,
                            error: lastLine(result.stderr),
                            state: authFailed ? .authFailed : .unreachable)
            }

        case .interactive:
            // askpass 原生流程:密码提示走 Keychain/密码框,验证码提示弹原生输入框
            let result = await SSHService.establishMasterInteractively(host)
            var established = result.succeeded
            if !established { established = await SSHService.checkMaster(host) }
            if established {
                setState(host.id, .online)
                await refresh(host)
            } else if result.timedOut {
                failConnect(host.id, error: "认证超时", state: .unreachable)
            } else {
                // 用户取消输入与认证失败都会走到这里,静默回到待连接
                failConnect(host.id, error: lastLine(result.stderr), state: .disconnected)
            }
        }
    }

    func savePasswordAndConnect(alias: String, password: String) {
        guard KeychainStore.setPassword(password, for: alias) else { return }
        passwordRequest = nil
        if let host = host(alias: alias) { connect(host) }
    }

    func disconnect(_ host: Host) {
        Task {
            await SSHService.closeMaster(host)
            setState(host.id, .disconnected)
        }
    }

    func disconnectAll() {
        for host in hosts { disconnect(host) }
    }

    /// 打开终端会话的唯一入口:偏好内嵌 → 主窗口新 Tab;否则调起外部终端 app。
    func openTerminal(_ host: Host) {
        if TerminalLauncher.useBuiltin {
            let tab = TerminalTab(id: UUID(), alias: host.meta.alias, title: host.name)
            terminalTabs.append(tab)
            selectedTab = .terminal(tab.id)
        } else {
            TerminalLauncher.open(command: SSHService.sessionCommandLine(for: host))
        }
    }

    func markTerminalTabEnded(_ id: UUID) {
        endedTerminalTabs.insert(id)
    }

    /// 关闭入口:活跃会话先请求二次确认,已结束的直接关。
    func requestCloseTerminalTab(_ id: UUID) {
        if endedTerminalTabs.contains(id) {
            closeTerminalTab(id)
        } else if let tab = terminalTabs.first(where: { $0.id == id }) {
            terminalCloseRequest = tab
        }
    }

    func closeTerminalTab(_ id: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        terminalTabs.remove(at: index)
        endedTerminalTabs.remove(id)
        if selectedTab == .terminal(id) {
            if terminalTabs.isEmpty {
                selectedTab = .hosts
            } else {
                selectedTab = .terminal(terminalTabs[min(index, terminalTabs.count - 1)].id)
            }
        }
    }

    /// 会话结束后原位重连:同位置换新 UUID → 视图重建 → 新 ssh 会话。
    func reopenTerminalTab(_ id: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        endedTerminalTabs.remove(id)
        let old = terminalTabs[index]
        let fresh = TerminalTab(
            id: UUID(), alias: old.alias,
            title: host(alias: old.alias)?.name ?? old.alias)
        terminalTabs[index] = fresh
        selectedTab = .terminal(fresh.id)
    }

    func updateTerminalTabTitle(_ id: UUID, title: String) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        terminalTabs[index].title = title
    }

    /// 把本地公钥装到远端 authorized_keys,返回 (是否成功, 给用户的消息)。
    func installPublicKey(_ host: Host) async -> (success: Bool, message: String) {
        let current = status(for: host)
        guard current.state == .online || current.masterAlive else {
            return (false, "请先建立连接,再安装公钥。")
        }
        guard let key = SSHService.localPublicKey() else {
            return (false, "本地没有找到公钥(~/.ssh/id_*.pub)。请先用 ssh-keygen 生成密钥。")
        }
        let result = await SSHService.installPublicKey(key, on: host)
        if result.succeeded, result.stdout.contains("HELM_KEY_OK") {
            return (true, "公钥已安装到 \(host.name)。切换为密钥认证后即可免密登录。")
        }
        let error = result.stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return (false, error ?? "安装失败,请稍后重试。")
    }

    func switchToKeyAuth(alias: String) {
        guard var meta = host(alias: alias)?.meta else { return }
        meta.auth = .key
        addOrUpdate(meta: meta)
    }

    // MARK: - 轮询与探测

    func refreshAll() async {
        let snapshot = hosts
        await withTaskGroup(of: Void.self) { group in
            for host in snapshot {
                group.addTask { await MonitorEngine.shared.refresh(host) }
            }
        }
    }

    func refresh(_ host: Host) async {
        let alias = host.id
        guard statuses[alias]?.state != .connecting else { return }

        let masterAlive = await SSHService.checkMaster(host)
        guard statuses[alias]?.state != .connecting else { return }

        var status = statuses[alias] ?? HostStatus()
        status.masterAlive = masterAlive

        // 密码/2FA 主机没有 master 时不探测(BatchMode 必失败),保持"待连接"。
        let canProbe = masterAlive || host.meta.auth == .key
        guard canProbe else {
            if status.state == .online {
                status.state = .disconnected
                notifyOfflineIfNeeded(host)
            } else if status.state != .authFailed {
                status.state = .disconnected
            }
            statuses[alias] = status
            return
        }

        let result = await SSHService.probe(host)
        guard statuses[alias]?.state != .connecting else { return }
        status.masterAlive = await SSHService.checkMaster(host)

        if result.succeeded {
            let metrics = ProbeParsers.parseMetrics(result.stdout)
            status.metrics = metrics
            status.state = .online
            status.consecutiveFailures = 0
            status.lastError = nil
            statuses[alias] = status
            checkDiskThreshold(host, metrics: metrics)
            checkGPUIdle(host, metrics: metrics)
        } else {
            status.consecutiveFailures += 1
            if status.consecutiveFailures >= 2 {
                let wasOnline = status.state == .online
                status.state = .unreachable
                status.lastError = result.timedOut ? "连接超时" : lastLine(result.stderr)
                if wasOnline { notifyOfflineIfNeeded(host) }
            }
            statuses[alias] = status
        }
    }

    // MARK: - 通知

    private func notifyOfflineIfNeeded(_ host: Host) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyOffline) else { return }
        NotificationService.post(title: "\(host.name) 掉线", body: "主机连接已断开")
    }

    private func checkDiskThreshold(_ host: Host, metrics: HostMetrics) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyDisk),
              let worst = metrics.worstDisk else { return }
        let threshold = UserDefaults.standard.integer(forKey: SettingsKeys.diskThreshold)
        if worst.usedPercent >= threshold {
            if !diskAlerted.contains(host.id) {
                diskAlerted.insert(host.id)
                NotificationService.post(
                    title: "\(host.name) 磁盘告急",
                    body: "\(worst.mount) 已使用 \(worst.usedPercent)%")
            }
        } else if worst.usedPercent < threshold - 5 {
            diskAlerted.remove(host.id)
        }
    }

    func setGPUWatch(alias: String, enabled: Bool) {
        guard var meta = host(alias: alias)?.meta else { return }
        meta.watchGPU = enabled
        addOrUpdate(meta: meta)
    }

    /// 一次性抢卡提醒:发现空闲 GPU 即推送并自动解除监视,避免刷屏。
    private func checkGPUIdle(_ host: Host, metrics: HostMetrics) {
        guard host.meta.isWatchingGPU else { return }
        let idle = metrics.idleGPUs
        guard !idle.isEmpty else { return }
        let indices = idle.map { "#\($0.index)" }.joined(separator: " ")
        NotificationService.post(
            title: "\(host.name) 有空闲 GPU",
            body: "\(idle.count) 张空闲(\(indices))。本次监视已完成,需要可再次开启。")
        setGPUWatch(alias: host.id, enabled: false)
    }

    // MARK: -

    private func setState(_ alias: String, _ state: ConnectionState) {
        var status = statuses[alias] ?? HostStatus()
        status.state = state
        if state == .online { status.consecutiveFailures = 0; status.lastError = nil }
        statuses[alias] = status
    }

    private func failConnect(_ alias: String, error: String?, state: ConnectionState) {
        var status = statuses[alias] ?? HostStatus()
        status.state = state
        status.lastError = error
        statuses[alias] = status
    }

    private func lastLine(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { !$0.isEmpty }
    }
}
