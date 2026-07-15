import Foundation

/// ~/.ssh/config 的无损文档模型:注释、空行、缩进、Match 块、通配 Host 块
/// 全部逐字节保留,只修改用户明确编辑的指令行。
struct SSHConfigDocument {
    enum Node {
        /// 块外的原始行(注释、Include、Match 块内容、通配 Host 块等)
        case raw(String)
        case host(HostBlock)
    }

    struct HostBlock {
        /// 原始 Host 行(保留大小写与缩进)
        var hostLine: String
        var aliases: [String]
        /// 块内所有原始行(指令、注释、空行)
        var lines: [String]

        /// 只有"单一具名别名"的块才允许可视化编辑;
        /// 多别名共享块与通配块改动会影响其他主机,保持只读。
        var isEditable: Bool {
            aliases.count == 1
                && !aliases[0].contains("*")
                && !aliases[0].contains("?")
                && !aliases[0].hasPrefix("!")
        }
    }

    var nodes: [Node]

    // MARK: - 解析 / 序列化

    static func parse(_ text: String) -> SSHConfigDocument {
        var nodes: [Node] = []
        var currentBlock: HostBlock?
        // Match 块或通配 Host 块:内容按原始行透传
        var inRawRegion = false

        func flushBlock() {
            if let block = currentBlock {
                nodes.append(.host(block))
                currentBlock = nil
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // split 会在结尾产生一个空元素(文件以换行结束时),序列化时统一补换行
        var allLines = lines
        if allLines.last == "" { allLines.removeLast() }

        for line in allLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let keyword = firstKeyword(of: trimmed)

            if keyword == "host" {
                flushBlock()
                inRawRegion = false
                let aliases = hostAliases(of: trimmed)
                currentBlock = HostBlock(hostLine: line, aliases: aliases, lines: [])
                continue
            }
            if keyword == "match" {
                flushBlock()
                inRawRegion = true
                nodes.append(.raw(line))
                continue
            }
            if inRawRegion {
                nodes.append(.raw(line))
            } else if currentBlock != nil {
                currentBlock!.lines.append(line)
            } else {
                nodes.append(.raw(line))
            }
        }
        flushBlock()
        return SSHConfigDocument(nodes: nodes)
    }

    func serialize() -> String {
        var lines: [String] = []
        for node in nodes {
            switch node {
            case .raw(let line):
                lines.append(line)
            case .host(let block):
                lines.append(block.hostLine)
                lines.append(contentsOf: block.lines)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 查询

    func block(for alias: String) -> HostBlock? {
        for node in nodes {
            if case .host(let block) = node, block.aliases.contains(alias) {
                return block
            }
        }
        return nil
    }

    func isEditable(alias: String) -> Bool {
        block(for: alias)?.isEditable ?? false
    }

    // MARK: - 修改

    /// 设置/替换/删除某主机块内的指令。value 为 nil 时删除该指令的所有出现。
    /// 只允许作用于 isEditable 的块。
    mutating func setDirective(alias: String, keyword: String, value: String?) {
        guard let index = blockIndex(for: alias) else { return }
        guard case .host(var block) = nodes[index], block.isEditable else { return }

        let lowered = keyword.lowercased()
        let indent = Self.detectIndent(in: block.lines)

        // 删除所有同名指令行(first-wins 语义下,残留行是僵尸配置)
        var insertAt: Int?
        var newLines: [String] = []
        for line in block.lines {
            if Self.firstKeyword(of: line.trimmingCharacters(in: .whitespaces)) == lowered {
                if insertAt == nil { insertAt = newLines.count }
                continue
            }
            newLines.append(line)
        }
        block.lines = newLines

        if let value, !value.isEmpty {
            let rendered = indent + Self.canonicalKeyword(lowered) + " " + Self.quoteIfNeeded(value)
            if let position = insertAt {
                block.lines.insert(rendered, at: position)
            } else {
                block.lines.insert(rendered, at: Self.appendPosition(in: block.lines))
            }
        }
        nodes[index] = .host(block)
    }

    /// 在文件末尾追加一个新的 Host 块。
    mutating func addHostBlock(alias: String, directives: [(keyword: String, value: String)]) {
        if let last = nodes.last {
            let lastIsBlank: Bool
            switch last {
            case .raw(let line): lastIsBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            case .host(let block): lastIsBlank = block.lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? false
            }
            if !lastIsBlank { nodes.append(.raw("")) }
        }
        let lines = directives.map { "    " + Self.canonicalKeyword($0.keyword.lowercased()) + " " + Self.quoteIfNeeded($0.value) }
        nodes.append(.host(HostBlock(hostLine: "Host \(alias)", aliases: [alias], lines: lines)))
    }

    /// 移除主机块(仅限 isEditable 的块)。
    mutating func removeHostBlock(alias: String) {
        guard let index = blockIndex(for: alias) else { return }
        guard case .host(let block) = nodes[index], block.isEditable else { return }
        nodes.remove(at: index)
        // 清理由此产生的连续空行开头(文件首行是空行时)
        if index == 0, case .raw(let line) = nodes.first ?? .raw("x"),
           line.trimmingCharacters(in: .whitespaces).isEmpty {
            nodes.removeFirst()
        }
    }

    // MARK: - 内部工具

    private func blockIndex(for alias: String) -> Int? {
        nodes.firstIndex { node in
            if case .host(let block) = node { return block.aliases.contains(alias) }
            return false
        }
    }

    static func firstKeyword(of trimmedLine: String) -> String? {
        guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }
        guard let end = trimmedLine.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        return trimmedLine[..<end].lowercased()
    }

    private static func hostAliases(of trimmedLine: String) -> [String] {
        guard let end = trimmedLine.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return []
        }
        return trimmedLine[trimmedLine.index(after: end)...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    private static func detectIndent(in lines: [String]) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            if !indent.isEmpty { return indent }
        }
        return "    "
    }

    /// 追加位置:最后一条非空、非注释行之后(跳过块尾的空行,保持块间距)。
    private static func appendPosition(in lines: [String]) -> Int {
        var position = 0
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { position = offset + 1 }
        }
        return position
    }

    static func canonicalKeyword(_ lowered: String) -> String {
        switch lowered {
        case "hostname": "HostName"
        case "user": "User"
        case "port": "Port"
        case "proxyjump": "ProxyJump"
        case "identityfile": "IdentityFile"
        default: lowered
        }
    }

    static func quoteIfNeeded(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}

/// ~/.ssh/config 的读写与安全网:备份 → 原子写 → ssh -G 校验 → 失败回滚。
enum SSHConfigStore {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Helm/config-backups", isDirectory: true)
    }

    static func isEditable(alias: String) -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return SSHConfigDocument.parse(text).isEditable(alias: alias)
    }

    /// 修改配置的唯一入口。返回 nil 表示成功,否则为用户可读的错误信息。
    static func mutate(
        validateAlias: String?,
        _ body: @Sendable (inout SSHConfigDocument) -> Void
    ) async -> String? {
        let fm = FileManager.default
        let sshDir = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: sshDir.path) {
            try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        var document = SSHConfigDocument.parse(original)
        body(&document)
        let output = document.serialize()
        guard output != original else { return nil }

        if !original.isEmpty { backup(original) }

        do {
            try write(output)
        } catch {
            return "写入失败:\(error.localizedDescription)"
        }

        if let alias = validateAlias {
            let result = await ProcessRunner.run(
                "/usr/bin/ssh",
                arguments: ["-G", "-F", configURL.path, alias],
                timeout: 5)
            if !result.succeeded {
                try? write(original)
                let reason = result.stderr
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty }
                return "配置校验未通过,已自动回滚:\(reason ?? "未知错误")"
            }
        }
        return nil
    }

    private static func write(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private static func backup(_ original: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "config-\(formatter.string(from: .now))"
        try? original.write(
            to: backupDirectory.appendingPathComponent(name),
            atomically: true, encoding: .utf8)
        // 只保留最近 20 份
        if let files = try? fm.contentsOfDirectory(atPath: backupDirectory.path) {
            let sorted = files.filter { $0.hasPrefix("config-") }.sorted()
            for stale in sorted.dropLast(20) {
                try? fm.removeItem(at: backupDirectory.appendingPathComponent(stale))
            }
        }
    }
}
