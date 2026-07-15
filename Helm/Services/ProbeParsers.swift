import Foundation

/// 解析监控探测脚本的分段文本输出。所有解析器对缺失/畸形输入静默降级。
enum ProbeParsers {
    static func parseMetrics(_ output: String) -> HostMetrics {
        let sections = splitSections(output)
        var metrics = HostMetrics()

        if let lines = sections["LOAD"], let loads = parseUptime(lines) {
            (metrics.load1, metrics.load5, metrics.load15) = loads
        }
        if let lines = sections["MEM"], let mem = parseFree(lines) {
            metrics.memTotalMB = mem.totalMB
            metrics.memAvailableMB = mem.availableMB
        }
        metrics.disks = parseDisks(sections["DISK"] ?? [])
        metrics.gpus = parseGPUs(sections["GPU"] ?? [])
        metrics.users = parseWho(sections["WHO"] ?? [])
        metrics.slurmJobs = parseSlurm(sections["SLURM"] ?? [])
        metrics.updatedAt = .now
        return metrics
    }

    static func splitSections(_ output: String) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@@") {
                current = String(trimmed.dropFirst(2))
                if let current, sections[current] == nil { sections[current] = [] }
                continue
            }
            if let current, !trimmed.isEmpty {
                sections[current, default: []].append(line)
            }
        }
        return sections
    }

    static func parseUptime(_ lines: [String]) -> (Double, Double, Double)? {
        let pattern = /load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/
        for line in lines {
            if let match = line.firstMatch(of: pattern),
               let l1 = Double(match.1), let l5 = Double(match.2), let l15 = Double(match.3) {
                return (l1, l5, l15)
            }
        }
        return nil
    }

    static func parseFree(_ lines: [String]) -> (totalMB: Int, availableMB: Int)? {
        for line in lines where line.hasPrefix("Mem:") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Mem: total used free shared buff/cache available
            guard columns.count >= 4, let total = Int(columns[1]) else { continue }
            let available: Int?
            if columns.count >= 7 {
                available = Int(columns[6])
            } else {
                available = Int(columns[3])
            }
            guard let available else { continue }
            return (total, available)
        }
        return nil
    }

    static func parseDisks(_ lines: [String]) -> [DiskUsage] {
        var disks: [DiskUsage] = []
        var seenMounts = Set<String>()
        let excludedMountPrefixes = ["/boot", "/run", "/sys", "/proc", "/dev", "/snap", "/var/lib/docker"]

        for line in lines {
            if line.hasPrefix("Filesystem") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 6 else { continue }
            let filesystem = columns[0]
            // 真实设备(/dev/...)或网络挂载(host:/export);排除 tmpfs/overlay 等伪文件系统
            guard filesystem.hasPrefix("/") || filesystem.contains(":") else { continue }
            guard let totalKB = Int64(columns[1]), totalKB > 0,
                  let usedKB = Int64(columns[2]) else { continue }
            let mount = columns[5...].joined(separator: " ")
            guard !excludedMountPrefixes.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) else { continue }
            guard seenMounts.insert(mount).inserted else { continue }

            let percent: Int
            if let p = Int(columns[4].replacingOccurrences(of: "%", with: "")) {
                percent = p
            } else {
                percent = Int((Double(usedKB) / Double(totalKB) * 100).rounded())
            }
            disks.append(DiskUsage(
                filesystem: filesystem, mount: mount,
                totalKB: totalKB, usedKB: usedKB, usedPercent: percent))
        }
        return disks
    }

    static func parseGPUs(_ lines: [String]) -> [GPUStat] {
        var gpus: [GPUStat] = []
        for line in lines {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5,
                  let index = Int(parts[0]),
                  let utilization = Int(parts[2]),
                  let memUsed = Int(parts[3]),
                  let memTotal = Int(parts[4]) else { continue }
            gpus.append(GPUStat(
                index: index, name: parts[1],
                utilization: utilization, memUsedMB: memUsed, memTotalMB: memTotal))
        }
        return gpus
    }

    static func parseWho(_ lines: [String]) -> [String] {
        var users: [String] = []
        for line in lines {
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
            let user = String(first)
            if !users.contains(user) { users.append(user) }
        }
        return users
    }

    static func parseSlurm(_ lines: [String]) -> [SlurmJob] {
        var jobs: [SlurmJob] = []
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5, !parts[0].isEmpty else { continue }
            jobs.append(SlurmJob(
                id: parts[0], name: parts[1], state: parts[2],
                time: parts[3], partition: parts[4]))
        }
        return jobs
    }
}
