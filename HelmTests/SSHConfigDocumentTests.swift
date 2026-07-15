import Testing

@Suite("SSHConfigDocument")
struct SSHConfigDocumentTests {
    /// 含注释、空行、tab 缩进、多别名块、通配块、Match 块、引号值的复杂样例
    static let sample = """
    # 科研集群配置
    # 最后更新:2026-07

    Host gpu1
    \tHostName gpu1.lab.university.edu
    \tUser zhuzy
    \tPort 2222
    \tProxyJump gateway

    Host gateway
        HostName gate.university.edu
        User zhuzy
        # 内网跳板,勿删
        IdentityFile "~/.ssh/keys/lab key"

    Host data backup
        HostName data.lab.internal
        User admin

    Host *.internal
        User nobody

    Match host gpu1 user zhuzy
        ForwardAgent yes

    Host *
        ServerAliveInterval 60
        AddKeysToAgent yes
    """

    @Test func roundTripIsByteIdentical() {
        let doc = SSHConfigDocument.parse(Self.sample)
        #expect(doc.serialize() == Self.sample + "\n")
    }

    @Test func editabilityFlags() {
        let doc = SSHConfigDocument.parse(Self.sample)
        #expect(doc.isEditable(alias: "gpu1"))
        #expect(doc.isEditable(alias: "gateway"))
        #expect(!doc.isEditable(alias: "data"))    // 多别名共享块
        #expect(!doc.isEditable(alias: "backup"))
        #expect(!doc.isEditable(alias: "*.internal"))
    }

    @Test func updateDirectivePreservesEverythingElse() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.setDirective(alias: "gpu1", keyword: "port", value: "22022")
        let output = doc.serialize()
        #expect(output.contains("\tPort 22022"))            // 保留 tab 缩进
        #expect(!output.contains("Port 2222"))
        #expect(output.contains("# 内网跳板,勿删"))          // 注释原样
        #expect(output.contains("Match host gpu1 user zhuzy"))
        #expect(output.contains("ServerAliveInterval 60"))
        // 除了这一行,其他内容不变
        let expected = Self.sample.replacingOccurrences(of: "\tPort 2222", with: "\tPort 22022")
        #expect(output == expected + "\n")
    }

    @Test func addMissingDirective() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.setDirective(alias: "gateway", keyword: "port", value: "8022")
        let output = doc.serialize()
        #expect(output.contains("    Port 8022"))           // 跟随块内空格缩进
    }

    @Test func removeDirective() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.setDirective(alias: "gpu1", keyword: "proxyjump", value: nil)
        let output = doc.serialize()
        #expect(!output.contains("ProxyJump gateway"))
        #expect(output.contains("Host gateway"))            // gateway 块不受影响
    }

    @Test func quotedValueWithSpaces() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.setDirective(alias: "gpu1", keyword: "identityfile", value: "~/.ssh/my key")
        #expect(doc.serialize().contains("IdentityFile \"~/.ssh/my key\""))
    }

    @Test func refusesToEditSharedBlock() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.setDirective(alias: "data", keyword: "port", value: "9999")
        #expect(doc.serialize() == Self.sample + "\n")      // 拒绝改动,原样
    }

    @Test func addHostBlockAppendsWithSeparator() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.addHostBlock(alias: "newbox", directives: [
            ("hostname", "10.0.0.99"), ("user", "zhu"), ("port", "2200"),
        ])
        let output = doc.serialize()
        #expect(output.hasSuffix("""
        Host newbox
            HostName 10.0.0.99
            User zhu
            Port 2200
        """ + "\n"))
        #expect(output.contains("AddKeysToAgent yes\n\nHost newbox"))  // 空行分隔
        #expect(SSHConfigDocument.parse(output).isEditable(alias: "newbox"))
    }

    @Test func removeHostBlock() {
        var doc = SSHConfigDocument.parse(Self.sample)
        doc.removeHostBlock(alias: "gpu1")
        let output = doc.serialize()
        #expect(!output.contains("Host gpu1"))
        #expect(!output.contains("gpu1.lab.university.edu"))
        #expect(output.contains("Host gateway"))
        #expect(output.contains("Match host gpu1 user zhuzy"))  // Match 块不动
    }

    @Test func emptyFileAddFirstBlock() {
        var doc = SSHConfigDocument.parse("")
        doc.addHostBlock(alias: "first", directives: [("hostname", "1.2.3.4")])
        let output = doc.serialize()
        #expect(output == "Host first\n    HostName 1.2.3.4\n")
    }
}
