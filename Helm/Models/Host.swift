import Foundation

enum AuthKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case key
    case password
    case interactive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .key: "密钥"
        case .password: "密码"
        case .interactive: "2FA / 交互"
        }
    }

    var symbolName: String {
        switch self {
        case .key: "key.fill"
        case .password: "lock.fill"
        case .interactive: "person.badge.key.fill"
        }
    }
}

enum Capability: String, Codable, CaseIterable, Sendable {
    case gpu
    case slurm

    var label: String {
        switch self {
        case .gpu: "GPU"
        case .slurm: "SLURM"
        }
    }
}

enum HostSource: String, Codable, Sendable {
    case sshConfig
    case manual
}

/// App 自有的主机元数据,以 alias 为主键,持久化到 hosts.json。密码绝不进此结构。
struct HostMeta: Codable, Identifiable, Hashable, Sendable {
    var alias: String
    var source: HostSource = .sshConfig
    var displayName: String?
    var tags: [String] = []
    var auth: AuthKind = .key
    var capabilities: Set<Capability> = []
    var notes: String = ""
    // Optional 以兼容旧版 hosts.json(缺 key 时 decodeIfPresent 为 nil);nil 视为 false
    var watchGPU: Bool?
    // 仅 manual 主机使用:
    var hostName: String?
    var user: String?
    var port: Int?

    var id: String { alias }

    var isWatchingGPU: Bool { watchGPU == true }
}

/// 从 ~/.ssh/config 解析出的条目。
struct SSHConfigEntry: Hashable, Sendable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var proxyJump: String?
    var identityFile: String?
}

/// 运行时主机 = 元数据 + (可选的)ssh config 条目。
struct Host: Identifiable, Hashable, Sendable {
    var meta: HostMeta
    var configEntry: SSHConfigEntry?

    var id: String { meta.alias }
    var name: String {
        if let d = meta.displayName, !d.isEmpty { return d }
        return meta.alias
    }

    var effectiveHostName: String? { meta.source == .manual ? meta.hostName : configEntry?.hostName }
    var effectiveUser: String? { meta.source == .manual ? meta.user : configEntry?.user }
    var effectivePort: Int? { meta.source == .manual ? meta.port : configEntry?.port }
    var proxyJump: String? { configEntry?.proxyJump }

    /// ssh 命令的目标参数:config 主机用 alias(继承用户全部配置),manual 主机显式拼。
    var sshTargetArgs: [String] {
        switch meta.source {
        case .sshConfig:
            return [meta.alias]
        case .manual:
            var args: [String] = []
            if let port = meta.port { args += ["-p", String(port)] }
            let hostPart = meta.hostName ?? meta.alias
            if let user = meta.user, !user.isEmpty {
                args.append("\(user)@\(hostPart)")
            } else {
                args.append(hostPart)
            }
            return args
        }
    }

    var subtitle: String {
        var core = effectiveHostName ?? meta.alias
        if let user = effectiveUser, !user.isEmpty { core = "\(user)@\(core)" }
        if let port = effectivePort, port != 22 { core += ":\(port)" }
        return core
    }
}

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case online
    case unreachable
    case authFailed
}

struct HostStatus: Sendable, Equatable {
    var state: ConnectionState = .disconnected
    var masterAlive = false
    var metrics: HostMetrics?
    var consecutiveFailures = 0
    var lastError: String?
}
