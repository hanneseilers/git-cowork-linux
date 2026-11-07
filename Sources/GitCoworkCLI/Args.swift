import Foundation

/// Minimal argument parsing: positional words plus `--flag`, `--key value`
/// and repeatable `--key value`. No dependencies.
struct Args {
    private(set) var positional: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    /// Options that take a value; everything else starting with "--" is a flag.
    static let valued: Set<String> = ["status", "assign", "assignee", "label", "body", "title", "branch",
                                      "to", "base", "task", "remote", "C", "worktree-path"]

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1
            if a == "--" { positional += argv[i...]; break }
            if a == "-C" || a.hasPrefix("--") {
                let name = a == "-C" ? "C" : String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    values[String(name[..<eq]), default: []].append(String(name[name.index(after: eq)...]))
                } else if Self.valued.contains(name) {
                    guard i < argv.count else { throw CLIError.usage("--\(name) needs a value") }
                    values[name, default: []].append(argv[i])
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }

    /// Positional argument `i`, or a usage error naming what's missing.
    func arg(_ i: Int, _ what: String) throws -> String {
        guard positional.indices.contains(i) else { throw CLIError.usage("missing \(what)") }
        return positional[i]
    }
}

enum CLIError: Error {
    case usage(String)
    case failed(String)
}
