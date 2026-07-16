import Testing

@Suite("ProcessGate")
struct ProcessGateTests {
    /// 并发峰值追踪器
    private actor PeakTracker {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    @Test func neverExceedsLimit() async {
        let limit = 4
        let gate = ProcessGate(limit: limit)
        let tracker = PeakTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    // 让出执行,制造真实并发
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(1))
                    await tracker.leave()
                    await gate.release()
                }
            }
        }

        let peak = await tracker.peak
        #expect(peak <= limit)
        #expect(peak >= 1)
        // 全部完成后名额应归零:再取满 limit 个不阻塞
        for _ in 0..<limit { await gate.acquire() }
        #expect(Bool(true))  // 未死锁即通过
    }

    @Test func allTasksComplete() async {
        let gate = ProcessGate(limit: 2)
        let counter = PeakTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        // 队列完全排空,current 归零
        let current = await counter.current
        #expect(current == 0)
    }
}
