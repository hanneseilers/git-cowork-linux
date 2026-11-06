import Foundation
import Observation

/// Every command the app ran that changed something, newest last.
@MainActor @Observable
final class CommandLog {
    static let shared = CommandLog()

    struct Entry: Identifiable {
        let id = UUID()
        let args: [String]
        let directory: URL
        let start: Date
        let duration: TimeInterval
        let result: GitResult

        var commandLine: String {
            "git " + args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        }
        var succeeded: Bool { result.exitCode == 0 }
        var output: String {
            [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private(set) var entries: [Entry] = []

    func add(_ e: Entry) {
        entries.append(e)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    func clear() { entries.removeAll() }
}
