import Foundation

struct DiskUsage: Hashable, Sendable {
    var filesystem: String
    var mount: String
    var totalKB: Int64
    var usedKB: Int64
    var usedPercent: Int
}

struct GPUStat: Hashable, Sendable {
    var index: Int
    var name: String
    var utilization: Int
    var memUsedMB: Int
    var memTotalMB: Int

    var memPercent: Int {
        guard memTotalMB > 0 else { return 0 }
        return Int((Double(memUsedMB) / Double(memTotalMB) * 100).rounded())
    }
}

struct SlurmJob: Hashable, Sendable {
    var id: String
    var name: String
    var state: String
    var time: String
    var partition: String
}

struct HostMetrics: Sendable, Equatable {
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var memTotalMB: Int?
    var memAvailableMB: Int?
    var disks: [DiskUsage] = []
    var gpus: [GPUStat] = []
    var users: [String] = []
    var slurmJobs: [SlurmJob] = []
    var updatedAt: Date = .now

    var memUsedPercent: Int? {
        guard let total = memTotalMB, total > 0, let avail = memAvailableMB else { return nil }
        return Int((Double(total - avail) / Double(total) * 100).rounded())
    }

    var worstDisk: DiskUsage? {
        disks.max { $0.usedPercent < $1.usedPercent }
    }

    var averageGPUUtilization: Int? {
        guard !gpus.isEmpty else { return nil }
        return gpus.reduce(0) { $0 + $1.utilization } / gpus.count
    }

    /// 空闲判定:利用率 ≤10% 且显存占用 <5%(有人挂着进程占显存不算空闲)。
    var idleGPUs: [GPUStat] {
        gpus.filter { gpu in
            guard gpu.utilization <= 10 else { return false }
            guard gpu.memTotalMB > 0 else { return true }
            return Double(gpu.memUsedMB) / Double(gpu.memTotalMB) < 0.05
        }
    }

    // squeue %T 输出长格式(RUNNING/PENDING),%t 输出短格式(R/PD),两者都兼容
    var runningJobs: Int {
        slurmJobs.filter { ["RUNNING", "R"].contains($0.state.uppercased()) }.count
    }
    var pendingJobs: Int {
        slurmJobs.filter { ["PENDING", "PD"].contains($0.state.uppercased()) }.count
    }
}
