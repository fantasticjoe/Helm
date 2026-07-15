import Foundation

struct RemoteFile: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case directory
        case file
        case symlink
    }

    var name: String
    var kind: Kind
    var size: Int64?
    var modified: Date?

    var id: String { name }
    var isDirectory: Bool { kind == .directory }
}

struct RemoteFileError: Error, Sendable {
    let message: String
}

/// 远端文件浏览与传输:列目录走 runCommand(BatchMode 复用 master),
/// 传输走 scp 带同一 ControlPath —— 与监控相同的纪律,绝不触发新认证。
enum RemoteFileService {
    static let scpPath = "/usr/bin/scp"

    static func homeDirectory(of host: Host) async -> String? {
        let result = await SSHService.runCommand("printf '%s' \"$HOME\"", on: host, timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, path.hasPrefix("/") else { return nil }
        return path
    }

    static func list(_ path: String, on host: Host) async -> Result<[RemoteFile], RemoteFileError> {
        let quoted = SSHService.shellQuote(path)
        // GNU find:type\tsize\tmtime\tname,对含空格文件名安全
        let command = "find \(quoted) -maxdepth 1 -mindepth 1 -printf '%y\\t%s\\t%T@\\t%f\\n'"
        let result = await SSHService.runCommand(command, on: host, timeout: 20)
        if result.succeeded {
            return .success(parseFindOutput(result.stdout))
        }
        // 降级:非 GNU find(如 BSD/busybox)只拿名字和目录标记
        let fallback = await SSHService.runCommand("ls -1Ap \(quoted)", on: host, timeout: 20)
        if fallback.succeeded {
            return .success(parseSimpleLS(fallback.stdout))
        }
        let error = (fallback.stderr.isEmpty ? result.stderr : fallback.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return .failure(RemoteFileError(message: error ?? "无法读取目录"))
    }

    static func parseFindOutput(_ output: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let kind: RemoteFile.Kind = switch parts[0] {
            case "d": .directory
            case "l": .symlink
            default: .file
            }
            let name = parts[3...].joined(separator: "\t")
            guard !name.isEmpty else { continue }
            files.append(RemoteFile(
                name: name,
                kind: kind,
                size: Int64(parts[1]),
                modified: Double(parts[2]).map { Date(timeIntervalSince1970: $0) }))
        }
        return files
    }

    static func parseSimpleLS(_ output: String) -> [RemoteFile] {
        output.split(separator: "\n").compactMap { line in
            let name = String(line)
            guard !name.isEmpty else { return nil }
            if name.hasSuffix("/") {
                return RemoteFile(name: String(name.dropLast()), kind: .directory, size: nil, modified: nil)
            }
            return RemoteFile(name: name, kind: .file, size: nil, modified: nil)
        }
    }

    // MARK: - 传输

    private static func scpArgs(for host: Host, recursive: Bool) -> [String] {
        var args = [
            "-o", "ControlPath=\(SSHService.socketDirectory)/%C",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-q",
        ]
        if recursive { args.append("-r") }
        if host.meta.source == .manual, let port = host.meta.port {
            args += ["-P", String(port)]
        }
        return args
    }

    /// scp 远端引用前缀:config 主机用 alias,manual 主机用 user@host。
    static func scpHostRef(_ host: Host) -> String {
        switch host.meta.source {
        case .sshConfig:
            return host.meta.alias
        case .manual:
            let hostPart = host.meta.hostName ?? host.meta.alias
            if let user = host.meta.user, !user.isEmpty { return "\(user)@\(hostPart)" }
            return hostPart
        }
    }

    static func download(
        _ file: RemoteFile, in remoteDir: String, from host: Host
    ) async -> Result<URL, RemoteFileError> {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = uniqueDestination(downloads.appendingPathComponent(file.name))
        let remotePath = joinPath(remoteDir, file.name)
        let args = scpArgs(for: host, recursive: file.isDirectory)
            + ["\(scpHostRef(host)):\(remotePath)", destination.path]
        let result = await ProcessRunner.run(scpPath, arguments: args, timeout: 3600)
        if result.succeeded { return .success(destination) }
        return .failure(RemoteFileError(message: errorLine(result) ?? "下载失败"))
    }

    static func upload(
        _ localURL: URL, to remoteDir: String, on host: Host
    ) async -> Result<Void, RemoteFileError> {
        let isDirectory = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let args = scpArgs(for: host, recursive: isDirectory)
            + [localURL.path, "\(scpHostRef(host)):\(remoteDir)/"]
        let result = await ProcessRunner.run(scpPath, arguments: args, timeout: 3600)
        if result.succeeded { return .success(()) }
        return .failure(RemoteFileError(message: errorLine(result) ?? "上传失败"))
    }

    // MARK: -

    static func joinPath(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// 下载重名时按 Finder 习惯追加序号,绝不覆盖本地文件。
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
    }

    private static func errorLine(_ result: ProcessResult) -> String? {
        if result.timedOut { return "传输超时" }
        return result.stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
