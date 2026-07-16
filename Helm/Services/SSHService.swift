import Foundation

/// 所有 ssh 调用的唯一出口。两条铁律:
/// 1. 建立连接(可能认证)只由用户显式发起;
/// 2. 监控探测永远 BatchMode + 复用,绝不触发新认证。
enum SSHService {
    static let sshPath = "/usr/bin/ssh"

    static var socketDirectory: String {
        NSHomeDirectory() + "/.helm/sockets"
    }

    static func prepareSocketDirectory() {
        try? FileManager.default.createDirectory(
            atPath: socketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static var controlArgs: [String] {
        ["-o", "ControlPath=\(socketDirectory)/%C"]
    }

    private static var commonArgs: [String] {
        controlArgs + ["-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]
    }

    /// Apple ssh 的钥匙串集成:passphrase 首次验证通过后由 ssh 自己存入系统钥匙串,
    /// 之后自动取用——Helm 永不存储密钥口令。
    private static var keychainArgs: [String] {
        ["-o", "AddKeysToAgent=yes", "-o", "UseKeychain=yes"]
    }

    private static var masterArgs: [String] {
        keychainArgs + [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=8h",
            "-o", "StrictHostKeyChecking=accept-new",
            "-N", "-f",
        ]
    }

    // MARK: - Master 生命周期

    static func checkMaster(_ host: Host) async -> Bool {
        let result = await ProcessRunner.run(
            sshPath,
            arguments: controlArgs + ["-O", "check"] + host.sshTargetArgs,
            timeout: 5)
        return result.succeeded
    }

    static func closeMaster(_ host: Host) async {
        _ = await ProcessRunner.run(
            sshPath,
            arguments: controlArgs + ["-O", "exit"] + host.sshTargetArgs,
            timeout: 5)
    }

    /// 密钥主机建 master:锁死 publickey 认证;带 passphrase 的密钥首次会经 askpass
    /// 弹原生口令框,验证后 ssh 存入钥匙串(UseKeychain),之后全程静默。
    static func establishMasterWithKey(_ host: Host) async -> ProcessResult {
        await ProcessRunner.run(
            sshPath,
            arguments: commonArgs + masterArgs
                + ["-o", "PreferredAuthentications=publickey"] + host.sshTargetArgs,
            environment: askpassEnvironment(for: host),
            timeout: 90)
    }

    private static func askpassEnvironment(for host: Host) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath ?? ""
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["HELM_ASKPASS"] = "1"
        environment["HELM_HOST_ALIAS"] = host.meta.alias
        return environment
    }

    /// 密码主机:askpass 指向 Helm 自身,ssh 需要密码时由 Askpass 从 Keychain 取。
    static func establishMasterWithStoredPassword(_ host: Host) async -> ProcessResult {
        await ProcessRunner.run(
            sshPath,
            arguments: commonArgs + masterArgs
                + ["-o", "NumberOfPasswordPrompts=1"] + host.sshTargetArgs,
            environment: askpassEnvironment(for: host),
            timeout: 45)
    }

    /// 2FA 主机:同样走 askpass,密码提示读 Keychain/弹密码框,验证码提示弹原生输入框。
    /// 超时放宽到 3 分钟,给用户看手机的时间。
    static func establishMasterInteractively(_ host: Host) async -> ProcessResult {
        await ProcessRunner.run(
            sshPath,
            arguments: commonArgs + masterArgs + host.sshTargetArgs,
            environment: askpassEnvironment(for: host),
            timeout: 180)
    }

    /// 内嵌终端会话的 ssh 参数:带 ControlPath 以复用 master,秒开免认证;
    /// 终端里手输的 passphrase 同样经 UseKeychain 入钥匙串。
    static func sessionArgs(for host: Host) -> [String] {
        controlArgs + keychainArgs + host.sshTargetArgs
    }

    /// 外部终端会话命令(Terminal.app / iTerm2)。
    static func sessionCommandLine(for host: Host) -> String {
        ([sshPath] + sessionArgs(for: host)).map(shellQuote).joined(separator: " ")
    }

    // MARK: - 监控探测

    static let probeScript = [
        "echo @@LOAD", "uptime",
        "echo @@CORES", "nproc 2>/dev/null",
        "echo @@MEM", "free -m 2>/dev/null",
        "echo @@DISK", "df -Pk 2>/dev/null",
        "echo @@GPU", "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null",
        "echo @@WHO", "who 2>/dev/null",
        "echo @@SLURM", "squeue -u $USER -h -o '%i|%j|%T|%M|%P' 2>/dev/null",
        "echo @@END",
    ].joined(separator: "; ")

    static func probe(_ host: Host) async -> ProcessResult {
        await runCommand(probeScript, on: host, timeout: 20)
    }

    /// 在远端执行任意命令:与探测同样的纪律 —— BatchMode + 只复用 master,绝不触发新认证。
    static func runCommand(_ command: String, on host: Host, timeout: TimeInterval = 60) async -> ProcessResult {
        await ProcessRunner.run(
            sshPath,
            arguments: commonArgs
                + ["-o", "BatchMode=yes", "-o", "ControlMaster=no"]
                + host.sshTargetArgs + [command],
            timeout: timeout)
    }

    // MARK: - 公钥迁移

    /// 本地默认公钥,按现代算法优先。
    static func localPublicKey() -> String? {
        let sshDir = NSHomeDirectory() + "/.ssh/"
        for name in ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"] {
            if let content = try? String(contentsOfFile: sshDir + name, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// ssh-copy-id 等价操作:走已建立的 master(BatchMode,不触发新认证),幂等追加。
    static func installPublicKey(_ key: String, on host: Host) async -> ProcessResult {
        let script = "k=\(shellQuote(key)); "
            + "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            + "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
            + "{ grep -qxF \"$k\" ~/.ssh/authorized_keys || printf '%s\\n' \"$k\" >> ~/.ssh/authorized_keys; } && "
            + "echo HELM_KEY_OK"
        return await ProcessRunner.run(
            sshPath,
            arguments: commonArgs
                + ["-o", "BatchMode=yes", "-o", "ControlMaster=no"]
                + host.sshTargetArgs + [script],
            timeout: 15)
    }

    // MARK: -

    static func shellQuote(_ text: String) -> String {
        if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./@=:%".contains($0) }) {
            return text
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
