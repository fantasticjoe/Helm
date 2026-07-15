import Foundation
import Testing

@Suite("RemoteFileService")
struct RemoteFileServiceTests {
    @Test func parsesFindOutput() {
        let output = """
        d\t4096\t1752540000.123\tdata
        f\t1048576\t1752530000.000\tmodel checkpoint.pt
        l\t23\t1752520000.500\tlatest
        f\t0\t1752510000.000\t.bashrc
        """
        let files = RemoteFileService.parseFindOutput(output)
        #expect(files.count == 4)
        #expect(files[0].isDirectory)
        #expect(files[0].name == "data")
        #expect(files[1].name == "model checkpoint.pt")  // 含空格文件名
        #expect(files[1].size == 1_048_576)
        #expect(files[2].kind == .symlink)
        #expect(files[3].name == ".bashrc")
        #expect(files[1].modified != nil)
    }

    @Test func parsesSimpleLSFallback() {
        let output = """
        data/
        run.sh
        .config/
        notes.txt
        """
        let files = RemoteFileService.parseSimpleLS(output)
        #expect(files.count == 4)
        #expect(files[0].isDirectory)
        #expect(files[0].name == "data")
        #expect(!files[1].isDirectory)
        #expect(files[2].isDirectory)
    }

    @Test func joinPathHandlesTrailingSlash() {
        #expect(RemoteFileService.joinPath("/home/user", "data") == "/home/user/data")
        #expect(RemoteFileService.joinPath("/", "etc") == "/etc")
    }

    @Test func malformedFindLinesSkipped() {
        let files = RemoteFileService.parseFindOutput("garbage\nd\t100\n")
        #expect(files.isEmpty)
    }
}
