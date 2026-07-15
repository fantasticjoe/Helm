import Foundation
import Observation

/// 批量命令执行器:并发在多台主机上跑同一条命令,逐主机汇报结果。
@MainActor
@Observable
final class BatchRunner {
    enum RunState: Equatable {
        case pending
        case running
        case done(success: Bool)
    }

    struct Entry: Identifiable {
        let host: Host
        var state: RunState = .pending
        var stdout = ""
        var stderr = ""
        var exitCode: Int32?
        var timedOut = false
        var duration: TimeInterval?

        var id: String { host.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false

    private static let historyKey = "batchCommandHistory"

    var history: [String] {
        UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    func run(command: String, hosts: [Host]) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !isRunning, !trimmed.isEmpty, !hosts.isEmpty else { return }

        recordHistory(trimmed)
        entries = hosts.map { Entry(host: $0) }
        isRunning = true

        Task {
            await withTaskGroup(of: Void.self) { group in
                for host in hosts {
                    group.addTask { await self.runOne(command: trimmed, host: host) }
                }
            }
            isRunning = false
        }
    }

    private func runOne(command: String, host: Host) async {
        update(host.id) { $0.state = .running }
        let start = Date()
        let result = await SSHService.runCommand(command, on: host)
        update(host.id) { entry in
            entry.stdout = result.stdout
            entry.stderr = result.stderr
            entry.exitCode = result.status
            entry.timedOut = result.timedOut
            entry.duration = Date().timeIntervalSince(start)
            entry.state = .done(success: result.succeeded)
        }
    }

    private func update(_ alias: String, _ body: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == alias }) else { return }
        body(&entries[index])
    }

    private func recordHistory(_ command: String) {
        var items = history
        items.removeAll { $0 == command }
        items.insert(command, at: 0)
        UserDefaults.standard.set(Array(items.prefix(10)), forKey: Self.historyKey)
    }
}
