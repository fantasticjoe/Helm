import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

/// 异步并发闸门:限制同时运行的子进程数。每个 ProcessRunner.run 会阻塞一个
/// GCD 线程直到进程退出;批量命令 + 轮询叠加时若不限流,可能逼近 GCD 线程池
/// 上限(~64)导致停滞。闸门把并发封顶在 limit,超出的调用异步排队等待。
actor ProcessGate {
    static let shared = ProcessGate(limit: 12)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        // 满员:排队等待一个名额被移交(active 计数不变,直接过户)
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum ProcessRunner {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20
    ) async -> ProcessResult {
        await ProcessGate.shared.acquire()
        let result = await withProcess(executable, arguments, environment, timeout)
        await ProcessGate.shared.release()
        return result
    }

    private static func withProcess(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let outBox = Box(Data())
                let errBox = Box(Data())
                let outDone = DispatchSemaphore(value: 0)
                let errDone = DispatchSemaphore(value: 0)

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        outDone.signal()
                    } else {
                        outBox.mutate { $0.append(data) }
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        errDone.signal()
                    } else {
                        errBox.mutate { $0.append(data) }
                    }
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: ProcessResult(
                        status: 127, stdout: "",
                        stderr: error.localizedDescription, timedOut: false))
                    return
                }

                // 用 Process 自身的 isRunning/terminate,而非裸 kill(pid):
                // waitUntilExit 回收子进程后 pid 可能被系统复用,裸 kill 有误杀风险。
                let timedOutFlag = Box(false)
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        timedOutFlag.set(true)
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

                process.waitUntilExit()
                _ = outDone.wait(timeout: .now() + 3)
                _ = errDone.wait(timeout: .now() + 3)
                killer.cancel()

                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outBox.get(), as: UTF8.self),
                    stderr: String(decoding: errBox.get(), as: UTF8.self),
                    timedOut: timedOutFlag.get()))
            }
        }
    }
}
