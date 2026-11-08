#if os(Linux)
import Foundation
import Testing
import CoworkKit
import GitCoworkCore

/// Linux only: git commands that leave a daemon running must still return
/// right away (Foundation's Process would wait for the daemon; see Subprocess).
@Suite struct LinuxProcessTests {
    @Test func gitReturnsWhileCacheDaemonKeepsRunning() async throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gc-daemon-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("sock").path
        let git = ProcessGit()
        let start = Date()
        let r = await git.git(["credential-cache", "--socket", socket, "--timeout", "30", "store"], in: dir,
                              input: Data("protocol=https\nhost=example.com\nusername=a\npassword=b\n\n".utf8))
        #expect(r.ok)
        #expect(Date().timeIntervalSince(start) < 10)
        let filled = await git.git(["-c", "credential.helper=", "-c", "credential.helper=cache --socket '\(socket)'",
                                    "credential", "fill"], in: dir, input: Data("protocol=https\nhost=example.com\n\n".utf8))
        #expect(filled.text.contains("password=b"))
        _ = await git.git(["credential-cache", "--socket", socket, "exit"], in: dir)
    }

    @Test func subprocessPassesInputAndExitCode() throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        let r = try Subprocess.run("/bin/sh", ["-c", "cat; echo err >&2; exit 3"], input: big)
        #expect(r.stdout == big)
        #expect(String(decoding: r.stderr, as: UTF8.self) == "err\n")
        #expect(r.status == 3)
        #expect(try Subprocess.run("/bin/pwd", [], currentDirectory: "/tmp").stdout == Data("/tmp\n".utf8))
        #expect(throws: (any Error).self) { try Subprocess.run("/nonexistent/tool", []) }
    }
}
#endif
