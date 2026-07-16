import Testing

@Suite("ProbeParsers")
struct ProbeParsersTests {
    static let fullOutput = """
    @@LOAD
     10:14:32 up 123 days,  4:05, 12 users,  load average: 3.15, 2.80, 2.42
    @@CORES
    64
    @@MEM
                  total        used        free      shared  buff/cache   available
    Mem:         515690       94321      201234        1234      220135      417000
    Swap:          8191           0        8191
    @@DISK
    Filesystem     1024-blocks       Used  Available Capacity Mounted on
    /dev/nvme0n1p2   937284000  562370400  374913600      61% /
    tmpfs             32934020          0   32934020       0% /dev/shm
    /dev/sda1      11718885376 9948573696 1770311680      85% /data
    overlay           937284000  562370400  374913600     61% /var/lib/docker/overlay2/x
    @@GPU
    0, NVIDIA A100-SXM4-80GB, 96, 67542, 81920
    1, NVIDIA A100-SXM4-80GB, 0, 3, 81920
    @@WHO
    alice    pts/0        2026-07-15 09:12 (10.0.0.5)
    bob      pts/1        2026-07-15 10:01 (10.0.0.8)
    alice    pts/2        2026-07-15 10:30 (10.0.0.5)
    @@SLURM
    123456|train_llm|RUNNING|2-03:44:10|gpu
    123457|preprocess|PENDING|0:00|cpu
    @@END
    """

    @Test func parsesFullOutput() {
        let m = ProbeParsers.parseMetrics(Self.fullOutput)
        #expect(m.load1 == 3.15)
        #expect(m.load5 == 2.80)
        #expect(m.load15 == 2.42)
        #expect(m.cores == 64)
        #expect(m.loadPercent == 5)  // 3.15 / 64 核
        #expect(m.memTotalMB == 515690)
        #expect(m.memUsedMB == 515690 - 417000)
        #expect(m.memAvailableMB == 417000)
        #expect(m.memUsedPercent == 19)
        #expect(m.disks.count == 2)  // tmpfs 与 overlay 被过滤
        #expect(m.worstDisk?.mount == "/data")
        #expect(m.worstDisk?.usedPercent == 85)
        #expect(m.gpus.count == 2)
        #expect(m.gpus[0].utilization == 96)
        #expect(m.gpus[1].name == "NVIDIA A100-SXM4-80GB")
        #expect(m.averageGPUUtilization == 48)
        #expect(m.users == ["alice", "bob"])  // 去重
        #expect(m.slurmJobs.count == 2)
        #expect(m.runningJobs == 1)
        #expect(m.pendingJobs == 1)
    }

    @Test func degradesWhenSectionsMissing() {
        // 无 GPU、无 SLURM 的普通机器:命令不存在时段为空
        let output = """
        @@LOAD
         01:02:03 up 1 day, 1 user, load average: 0.00, 0.01, 0.05
        @@MEM
                      total        used        free      shared  buff/cache   available
        Mem:           7982        1211        4521          89        2250        6432
        @@DISK
        Filesystem 1024-blocks    Used Available Capacity Mounted on
        /dev/vda1     41152812 9276948  30956104      24% /
        @@GPU
        @@WHO
        @@SLURM
        @@END
        """
        let m = ProbeParsers.parseMetrics(output)
        #expect(m.load1 == 0.00)
        #expect(m.gpus.isEmpty)
        #expect(m.users.isEmpty)
        #expect(m.slurmJobs.isEmpty)
        #expect(m.disks.count == 1)
    }

    @Test func macOSUptimeVariant() {
        // BSD/macOS 写法 "load averages:"
        let loads = ProbeParsers.parseUptime(
            ["10:14  up 3 days,  2:05, 2 users, load averages: 1.20 1.10 1.00"])
        #expect(loads?.0 == 1.20)
        #expect(loads?.2 == 1.00)
    }

    @Test func freeWithoutAvailableColumn() {
        // 精简版 free(如 busybox)没有 available 列时回退到 free 列
        let mem = ProbeParsers.parseFree([
            "              total        used        free      shared",
            "Mem:           7982        1211        4521          89",
        ])
        #expect(mem?.totalMB == 7982)
        #expect(mem?.availableMB == 4521)
    }

    @Test func nfsMountIncluded() {
        let disks = ProbeParsers.parseDisks([
            "Filesystem 1024-blocks    Used Available Capacity Mounted on",
            "nas:/export/home 104857600 94371840 10485760      90% /home/shared",
        ])
        #expect(disks.count == 1)
        #expect(disks[0].usedPercent == 90)
    }

    @Test func mountWithSpaces() {
        let disks = ProbeParsers.parseDisks([
            "/dev/sdb1 1000000 500000 500000 50% /mnt/my data",
        ])
        #expect(disks.first?.mount == "/mnt/my data")
    }

    @Test func malformedInputIsIgnored() {
        let m = ProbeParsers.parseMetrics("random garbage\nnot a probe output\n")
        #expect(m.load1 == nil)
        #expect(m.disks.isEmpty)
        #expect(m.gpus.isEmpty)
    }

    @Test func idleGPUDetection() {
        var metrics = HostMetrics()
        metrics.gpus = [
            GPUStat(index: 0, name: "A100", utilization: 96, memUsedMB: 60000, memTotalMB: 81920),
            GPUStat(index: 1, name: "A100", utilization: 0, memUsedMB: 3, memTotalMB: 81920),      // 真空闲
            GPUStat(index: 2, name: "A100", utilization: 5, memUsedMB: 40000, memTotalMB: 81920),  // 占着显存不算
            GPUStat(index: 3, name: "A100", utilization: 8, memUsedMB: 100, memTotalMB: 81920),    // 空闲
        ]
        let idle = metrics.idleGPUs
        #expect(idle.map(\.index) == [1, 3])
    }

    @Test func gpuParserSkipsErrorLines() {
        let gpus = ProbeParsers.parseGPUs([
            "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.",
        ])
        #expect(gpus.isEmpty)
    }
}
