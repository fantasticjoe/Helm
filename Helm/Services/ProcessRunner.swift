import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
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
