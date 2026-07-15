import Testing

@Suite("SSHConfigParser")
struct SSHConfigParserTests {
    let sample = """
    # 科研集群
    Host gpu1
        HostName gpu1.lab.university.edu
        User zhuzy
        Port 2222
        ProxyJump gateway

    Host gateway
      HostName gate.university.edu
      User zhuzy

    Host data backup
        HostName data.lab.internal
        User admin

    Host *.internal old-?
        User nobody

    Host *
        ServerAliveInterval 60

    Match host gpu1
        User override

    Host quoted
        HostName "space host.example.com"
    """

    @Test func parsesConcreteHosts() {
        let entries = SSHConfigParser.parse(sample)
        let aliases = entries.map(\.alias)
        #expect(aliases == ["gpu1", "gateway", "data", "backup", "quoted"])
    }

    @Test func parsesFields() {
        let entries = SSHConfigParser.parse(sample)
        let gpu1 = entries.first { $0.alias == "gpu1" }
        #expect(gpu1?.hostName == "gpu1.lab.university.edu")
        #expect(gpu1?.user == "zhuzy")
        #expect(gpu1?.port == 2222)
        #expect(gpu1?.proxyJump == "gateway")
    }

    @Test func multiAliasBlockSharesValues() {
        let entries = SSHConfigParser.parse(sample)
        let data = entries.first { $0.alias == "data" }
        let backup = entries.first { $0.alias == "backup" }
        #expect(data?.hostName == "data.lab.internal")
        #expect(backup?.hostName == "data.lab.internal")
        #expect(backup?.user == "admin")
    }

    @Test func skipsWildcardsAndMatchBlocks() {
        let entries = SSHConfigParser.parse(sample)
        #expect(!entries.contains { $0.alias.contains("*") || $0.alias.contains("?") })
        // Match 块中的 User override 不应污染任何主机
        #expect(!entries.contains { $0.user == "override" })
        #expect(!entries.contains { $0.user == "nobody" })
    }

    @Test func stripsQuotes() {
        let entries = SSHConfigParser.parse(sample)
        #expect(entries.first { $0.alias == "quoted" }?.hostName == "space host.example.com")
    }

    @Test func firstValueWins() {
        let text = """
        Host dup
            HostName first.example.com
            HostName second.example.com
        """
        let entries = SSHConfigParser.parse(text)
        #expect(entries.first?.hostName == "first.example.com")
    }

    @Test func emptyInput() {
        #expect(SSHConfigParser.parse("").isEmpty)
        #expect(SSHConfigParser.parse("# only comments\n\n").isEmpty)
    }
}
