import Foundation

/// 只读解析 ~/.ssh/config:提取具名 Host 块的 HostName/User/Port/ProxyJump。
/// 通配模式(* ? !)与 Match 块跳过——运行时行为交给系统 ssh 本身。
enum SSHConfigParser {
    static func parseDefaultConfig() -> [SSHConfigEntry] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var currentAliases: [String] = []
        var currentValues: [String: String] = [:]
        var inMatchBlock = false

        func flush() {
            for alias in currentAliases {
                var entry = SSHConfigEntry(alias: alias)
                entry.hostName = currentValues["hostname"]
                entry.user = currentValues["user"]
                entry.port = currentValues["port"].flatMap(Int.init)
                if let jump = currentValues["proxyjump"] {
                    entry.proxyJump = jump
                } else if currentValues["proxycommand"] != nil {
                    entry.proxyJump = "(ProxyCommand)"
                }
                entries.append(entry)
            }
            currentAliases = []
            currentValues = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let (keyword, value) = splitKeywordValue(line) else { continue }

            switch keyword {
            case "host":
                flush()
                inMatchBlock = false
                currentAliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            case "match":
                flush()
                inMatchBlock = true
            default:
                guard !inMatchBlock, !currentAliases.isEmpty else { continue }
                // ssh 语义:先出现者生效
                if currentValues[keyword] == nil { currentValues[keyword] = value }
            }
        }
        flush()
        return entries
    }

    private static func splitKeywordValue(_ line: String) -> (String, String)? {
        guard let separatorIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        let keyword = line[..<separatorIndex].lowercased()
        var value = line[line.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("="), value.count > 1 {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !keyword.isEmpty, !value.isEmpty else { return nil }
        return (keyword, value)
    }
}
