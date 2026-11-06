import Foundation

/// Three-way merge for cowork files, used when two people changed the
/// cowork ref at the same time (offline, or between syncs).
///
/// - Files only one side touched: take that side.
/// - The same file changed on both sides: merge field by field against the
///   common base. A field changed on one side only takes that change; a field
///   changed on both sides takes the side with the newer `updated` time.
/// - Keyed lists like `reviewers: [a@x=approved, b@y=requested]` merge per key,
///   so two reviewers approving at once both count.
/// - Deleting a file loses against editing it.
public enum CoworkMerge {
    public static func mergeFile(path: String, base: String?, ours: String?, theirs: String?) -> String? {
        if ours == theirs { return ours }
        if base == ours { return theirs }
        if base == theirs { return ours }
        guard let ours else { return theirs }      // deleted here, edited there: keep the edit
        guard let theirs else { return ours }
        if path == CoworkPaths.team { return mergeTeam(base: base, ours: ours, theirs: theirs) }
        let merged = mergeDocs(base: base.map(FrontMatter.parse) ?? FrontMatterDoc(),
                               ours: FrontMatter.parse(ours),
                               theirs: FrontMatter.parse(theirs))
        return FrontMatter.serialize(merged)
    }

    static let bodyKey = "\u{0}body"

    public static func mergeDocs(base: FrontMatterDoc, ours: FrontMatterDoc, theirs: FrontMatterDoc) -> FrontMatterDoc {
        let oursNewer = (ours["updated"] ?? "") >= (theirs["updated"] ?? "")   // ISO-8601 sorts as text

        func all(_ d: FrontMatterDoc) -> [String: FrontMatterValue] {
            var f = d.fields
            f[bodyKey] = .string(d.body)
            return f
        }
        let b = all(base), o = all(ours), t = all(theirs)
        var result: [String: FrontMatterValue] = [:]

        for key in Set(b.keys).union(o.keys).union(t.keys) {
            let bv = b[key], ov = o[key], tv = t[key]
            let value: FrontMatterValue?
            if ov == tv { value = ov }
            else if ov == bv { value = tv }
            else if tv == bv { value = ov }
            else if case .list(let ol)? = ov, case .list(let tl)? = tv, isKeyed(ol + tl) {
                value = .list(mergeKeyed(base: bv.flatMap(listValue) ?? [], ours: ol, theirs: tl, oursNewer: oursNewer))
            } else {
                value = oursNewer ? ov : tv
            }
            if let value { result[key] = value }
        }

        // Updated time is the later of the two.
        let updated = max(ours["updated"] ?? "", theirs["updated"] ?? "")
        if !updated.isEmpty { result["updated"] = .string(updated) }

        var body = ""
        if case .string(let s)? = result.removeValue(forKey: bodyKey) { body = s }
        return FrontMatterDoc(fields: result, body: body)
    }

    static func listValue(_ v: FrontMatterValue) -> [String]? {
        if case .list(let l) = v { return l }
        return nil
    }

    static func isKeyed(_ items: [String]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.contains("=") }
    }

    static func mergeKeyed(base: [String], ours: [String], theirs: [String], oursNewer: Bool) -> [String] {
        func dict(_ l: [String]) -> [String: String] {
            var d: [String: String] = [:]
            for item in l {
                let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
                d[kv[0]] = kv.count == 2 ? kv[1] : ""
            }
            return d
        }
        let b = dict(base), o = dict(ours), t = dict(theirs)
        var out: [String: String] = [:]
        for k in Set(b.keys).union(o.keys).union(t.keys) {
            let bv = b[k], ov = o[k], tv = t[k]
            let v: String?
            if ov == tv { v = ov }
            else if ov == bv { v = tv }
            else if tv == bv { v = ov }
            else { v = oursNewer ? (ov ?? tv) : (tv ?? ov) }
            if let v { out[k] = v }
        }
        return out.keys.sorted().map { "\($0)=\(out[$0]!)" }
    }

    /// Three-way merge per member (keyed by email): an add, edit or removal
    /// made on one side only is kept; when both sides changed the same
    /// member, ours wins (and an edit wins over a removal).
    static func mergeTeam(base: String?, ours: String, theirs: String) -> String {
        func dict(_ text: String?) -> [String: TeamMember] {
            var d: [String: TeamMember] = [:]
            for m in CoworkCodec.decodeTeam(text ?? "") { d[m.id] = m }
            return d
        }
        let b = dict(base), o = dict(ours), t = dict(theirs)
        var out: [TeamMember] = []
        for id in Set(b.keys).union(o.keys).union(t.keys) {
            let bm = b[id], om = o[id], tm = t[id]
            let m: TeamMember?
            if om == tm { m = om }
            else if om == bm { m = tm }
            else if tm == bm { m = om }
            else { m = om ?? tm }
            if let m { out.append(m) }
        }
        return CoworkCodec.encodeTeam(out)
    }
}
