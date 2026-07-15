import Foundation

/// hosts.json 持久化:只存元数据,密码永远在 Keychain。
enum HostStore {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Helm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    static func load() -> [HostMeta] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([HostMeta].self, from: data)) ?? []
    }

    static func save(_ metas: [HostMeta]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metas) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
