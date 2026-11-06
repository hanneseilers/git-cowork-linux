import Foundation

/// Finds @mentions in task bodies and comments and resolves them to people.
public enum Mentions {
    /// Handles written as @name (letters, digits, . _ -), not part of an email address.
    public static func handles(in text: String) -> [String] {
        var result: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "@", i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "." || chars[i - 1] == "_") {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "-" {
                    j += 1
                }
                var handle = String(chars[(i + 1)..<j])
                while handle.hasSuffix(".") || handle.hasSuffix("-") { handle.removeLast() }   // "@anna." at sentence end
                if !handle.isEmpty, !result.contains(handle) { result.append(handle) }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    /// Emails of the people mentioned. A handle matches a team member's handle,
    /// or the part of a known email before the "@".
    public static func emails(in text: String, team: [TeamMember], knownEmails: [String]) -> Set<String> {
        var out = Set<String>()
        for h in handles(in: text).map({ $0.lowercased() }) {
            if let m = team.first(where: { $0.handle.lowercased() == h }) {
                out.insert(m.email.lowercased())
            } else if let e = knownEmails.first(where: { $0.lowercased().split(separator: "@").first.map(String.init) == h }) {
                out.insert(e.lowercased())
            }
        }
        return out
    }
}
