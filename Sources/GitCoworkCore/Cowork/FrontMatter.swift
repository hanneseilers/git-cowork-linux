import Foundation

/// A Markdown file with a small header:
///
///     ---
///     title: Cache sessions
///     labels: [backend, "needs design"]
///     ---
///     Body text.
///
/// Values are strings or flat lists of strings. Anything that could confuse
/// the parser is written as a JSON string, so round-trips are exact.
public struct FrontMatterDoc: Hashable, Sendable {
    public var fields: [String: FrontMatterValue]
    public var body: String

    public init(fields: [String: FrontMatterValue] = [:], body: String = "") {
        self.fields = fields
        self.body = body
    }

    public subscript(_ key: String) -> String? {
        get { if case .string(let s) = fields[key] { return s } else { return nil } }
        set { fields[key] = newValue.map(FrontMatterValue.string) }
    }

    public func list(_ key: String) -> [String] {
        switch fields[key] {
        case .list(let l): l
        case .string(let s): s.isEmpty ? [] : [s]
        case nil: []
        }
    }

    public mutating func setList(_ key: String, _ value: [String]) {
        fields[key] = .list(value)
    }
}

public enum FrontMatterValue: Hashable, Sendable {
    case string(String)
    case list([String])
}

public enum FrontMatter {
    /// Fields written first, in this order; the rest follow alphabetically.
    static let order = ["id", "title", "status", "state", "assignee", "branch", "base", "requester",
                        "reviewers", "labels", "author", "name", "created", "updated"]

    public static func parse(_ text: String) -> FrontMatterDoc {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return FrontMatterDoc(body: text)
        }
        var doc = FrontMatterDoc()
        var i = 1
        while i < lines.count {
            let line = lines[i]
            i += 1
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if raw.hasPrefix("[") && raw.hasSuffix("]") {
                doc.fields[key] = .list(parseList(String(raw.dropFirst().dropLast())))
            } else {
                doc.fields[key] = .string(decodeScalar(raw))
            }
        }
        // serialize() writes one blank line before and a newline after the body.
        doc.body = lines[min(i, lines.count)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return doc
    }

    public static func serialize(_ doc: FrontMatterDoc) -> String {
        var out = "---\n"
        let keys = doc.fields.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
        for key in keys {
            switch doc.fields[key]! {
            case .string(let s): out += "\(key): \(encodeScalar(s))\n"
            case .list(let l): out += "\(key): [\(l.map(encodeListItem).joined(separator: ", "))]\n"
            }
        }
        out += "---\n"
        let body = doc.body.trimmingCharacters(in: .newlines)
        if !body.isEmpty { out += "\n" + body + "\n" }
        return out
    }

    // MARK: Scalars

    static func needsQuotes(_ s: String, inList: Bool) -> Bool {
        if s.isEmpty { return true }
        if s.first!.isWhitespace || s.last!.isWhitespace { return true }
        if s.contains(where: \.isNewline) { return true }
        if s.first == "\"" || s.first == "[" || s.first == "'" { return true }
        if inList && (s.contains(",") || s.contains("]")) { return true }
        return false
    }

    static func encodeScalar(_ s: String) -> String {
        needsQuotes(s, inList: false) ? jsonString(s) : s
    }

    static func encodeListItem(_ s: String) -> String {
        needsQuotes(s, inList: true) ? jsonString(s) : s
    }

    static func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)   // ["..."]
        return String(array.dropFirst().dropLast())
    }

    static func decodeScalar(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2,
              let data = "[\(raw)]".data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              let s = arr.first else { return raw }
        return s
    }

    static func parseList(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in inner {
            if inQuotes {
                current.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inQuotes = false }
            } else if ch == "\"" {
                inQuotes = true
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(decodeScalar)
    }
}
