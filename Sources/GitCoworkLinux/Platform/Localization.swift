import Foundation
import GitCoworkCore

// UI text is written in English and looked up in the same translation files
// as the macOS app (Resources/<lang>.lproj/Localizable.strings), plus a few
// Linux-only strings (Resources/linux/<lang>.lproj/Localizable.strings).
// Keys follow Apple's rules: an interpolated String becomes %@, an integer
// %lld, and translations may reorder with %1$@, %2$@.

/// Translated String for a fixed UI label.
func L(_ key: String) -> String {
    Localization.shared.translate(key)
}

extension TaskStatus {
    /// Translated column name for the screen. `title` stays English: it's
    /// also used in the task sync's commit messages.
    var label: String { L(title) }
}

/// What `String(localized: "…\(x)…")` builds: the key with placeholders and the values.
struct LocalizedKey: ExpressibleByStringInterpolation, Sendable {
    var key: String
    var args: [String]

    init(stringLiteral value: String) {
        key = value
        args = []
    }

    init(stringInterpolation i: Interpolation) {
        key = i.key
        args = i.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ s: String) { key += s.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation(_ s: String) { key += "%@"; args.append(s) }
        mutating func appendInterpolation(_ s: Substring) { key += "%@"; args.append(String(s)) }
        mutating func appendInterpolation<I: BinaryInteger>(_ n: I) { key += "%lld"; args.append(String(n)) }
        mutating func appendInterpolation(_ d: Double) { key += "%@"; args.append(String(format: "%.1f", d)) }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; args.append(String(describing: value)) }
    }
}

extension String {
    /// Linux counterpart of Foundation's `String(localized:)` on Apple platforms,
    /// reading the app's .strings files. Shadows Foundation's version inside this module.
    init(localized k: LocalizedKey) {
        self = Localization.shared.format(k)
    }
}

final class Localization: @unchecked Sendable {
    static let shared = Localization()

    /// Language in use, e.g. "de"; "en" means the text in the code.
    let language: String
    private var table: [String: String] = [:]

    init(language: String? = nil, resources: URL? = AppResources.directory) {
        let lang = language ?? Self.preferredLanguage()
        self.language = lang
        guard lang != "en", let resources else { return }
        for file in [resources.appendingPathComponent("\(lang).lproj/Localizable.strings"),
                     resources.appendingPathComponent("linux/\(lang).lproj/Localizable.strings")] {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                table.merge(StringsFile.parse(text)) { _, new in new }
            }
        }
    }

    /// GIT_COWORK_LANG, then the usual locale variables (LANGUAGE may list several).
    static func preferredLanguage(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                  available: Set<String> = ["en", "de"]) -> String {
        var candidates: [String] = []
        if let v = env["GIT_COWORK_LANG"], !v.isEmpty { candidates.append(v) }
        if let v = env["LANGUAGE"], !v.isEmpty { candidates += v.split(separator: ":").map(String.init) }
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let v = env[name], !v.isEmpty { candidates.append(v); break }
        }
        for c in candidates {
            if c == "C" || c == "POSIX" || c.hasPrefix("C.") { return "en" }
            let code = String(c.prefix { $0.isLetter }).lowercased()
            if available.contains(code) { return code }
        }
        return "en"
    }

    func translate(_ key: String) -> String {
        table[key] ?? key
    }

    func format(_ k: LocalizedKey) -> String {
        let template = table[k.key] ?? k.key
        return Self.substitute(template, k.args)
    }

    /// Fills %@ / %lld / %d (optionally numbered: %2$@) with `args`; %% is a percent sign.
    static func substitute(_ template: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%", i + 1 < chars.count else { out.append(c); i += 1; continue }
            if chars[i + 1] == "%" { out.append("%"); i += 2; continue }
            var j = i + 1
            var position: Int?
            var digits = ""
            while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if !digits.isEmpty, j < chars.count, chars[j] == "$" {
                position = Int(digits).map { $0 - 1 }
                j += 1
            } else {
                j = i + 1
            }
            // Length modifiers, then the conversion.
            while j < chars.count, "lhqz".contains(chars[j]) { j += 1 }
            guard j < chars.count, "@dDiuxXf".contains(chars[j]) else { out.append(c); i += 1; continue }
            let index = position ?? next
            if position == nil { next += 1 }
            out += index >= 0 && index < args.count ? args[index] : ""
            i = j + 1
        }
        return out
    }
}

/// Parser for Apple's old-style .strings files: `"key" = "value";`, comments, escapes.
enum StringsFile {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let s = Array(text.unicodeScalars)
        var i = 0

        func skipSpaceAndComments() {
            while i < s.count {
                if s[i] == " " || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i += 1; continue }
                if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i += 2
                    continue
                }
                if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        func quoted() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count, s[i] != "\"" {
                if s[i] == "\\", i + 1 < s.count {
                    i += 1
                    switch s[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "U", "u":
                        let hex = String(String.UnicodeScalarView(s[(i + 1)..<min(i + 5, s.count)]))
                        if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                            out.append(scalar); i += 4
                        }
                    default: out.append(s[i])
                    }
                } else {
                    out.append(s[i])
                }
                i += 1
            }
            i += 1
            return String(out)
        }

        while i < s.count {
            skipSpaceAndComments()
            guard let key = quoted() else { if i < s.count { i += 1 }; continue }
            skipSpaceAndComments()
            guard i < s.count, s[i] == "=" else { continue }
            i += 1
            skipSpaceAndComments()
            guard let value = quoted() else { continue }
            skipSpaceAndComments()
            if i < s.count, s[i] == ";" { i += 1 }
            result[key] = value
        }
        return result
    }
}

/// Where translations, the icon and install.sh are: next to an installed
/// binary (<prefix>/share/git-cowork), or the repository's Resources folder
/// for a build run from the source tree.
enum AppResources {
    static let directory: URL? = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["GIT_COWORK_RESOURCES"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let exe = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let bin = exe.deletingLastPathComponent()
        let installed = bin.deletingLastPathComponent().appendingPathComponent("share/git-cowork")
        if fm.fileExists(atPath: installed.appendingPathComponent("de.lproj").path) { return installed }
        // .build/<config>/git-cowork-gtk -> walk up to the checkout.
        var dir = bin
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources")
            if fm.fileExists(atPath: candidate.appendingPathComponent("de.lproj").path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    /// This program's own path (for the askpass helper and the updater).
    static var executablePath: String {
        var path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
        // After an update replaced the file, the kernel reports "<path> (deleted)";
        // the new binary is at the same path.
        if path.hasSuffix(" (deleted)") { path = String(path.dropLast(" (deleted)".count)) }
        return path
    }
}
