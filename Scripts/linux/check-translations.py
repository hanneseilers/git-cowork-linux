#!/usr/bin/env python3
"""Lists UI text of the Linux app (Sources/GitCoworkLinux) that has no German
translation in Resources/<lang>.lproj or Resources/linux/<lang>.lproj.

Keys follow the same rules as on macOS: an interpolated String is %@, an
integer %lld. The script can't know a value's type, so it accepts either.

Usage: Scripts/linux/check-translations.py [lang]   (default: de)
Exit code 1 when something is missing.
"""
import glob, itertools, os, re, sys

LANG = sys.argv[1] if len(sys.argv) > 1 else "de"
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

SAME = re.compile(r"^[\s%@\d.,:;·<>()\[\]+\-−—→…/|@]*$")
KEEP = {"git-cowork", "OK", "Git", "SHA", "Commit", "Cowork", "Board", "Reviews", "Pull", "Push", "Branch",
        "Worktree", "Stash", "Pop", "Backlog", "Labels", "Status", "Task", "Diff", "Hunks", "Split", "Remote",
        "Worktrees", "Tags", "Team", "Merge", "Rebase", "Labels, separated by commas", "Tasks", "Inbox"}


def parse_strings(path):
    table = {}
    if not os.path.exists(path):
        return table
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text):
        table[unescape(m.group(1))] = unescape(m.group(2))
    return table


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def interpolations(literal):
    """Splits a Swift literal at \\( … ) (balanced parentheses)."""
    parts, buf, i = [], "", 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[j], 0)
                j += 1
            parts.append(buf); buf = ""; i = j
        else:
            buf += literal[i]; i += 1
    parts.append(buf)
    return parts


def keys():
    found = {}
    for path in glob.glob("Sources/GitCoworkLinux/**/*.swift", recursive=True):
        src = open(path, encoding="utf-8").read()
        for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"\)', src):
            found.setdefault(unescape(m.group(1)), (path, []))
        for m in re.finditer(r'String\(localized: "((?:[^"\\]|\\.)*)"\)', src):
            parts = [unescape(p).replace("%", "%%") for p in interpolations(m.group(1))]
            variants = ["".join(itertools.chain.from_iterable(zip(parts, combo + ("",))))
                        for combo in itertools.product(["%@", "%lld"], repeat=len(parts) - 1)]
            found.setdefault(variants[0], (path, variants))
    return found


def main():
    table = parse_strings(f"Resources/{LANG}.lproj/Localizable.strings")
    table.update(parse_strings(f"Resources/linux/{LANG}.lproj/Localizable.strings"))
    missing = []
    for key, (path, variants) in sorted(keys().items()):
        if SAME.match(key) or key in KEEP:
            continue
        if key in table or any(v in table for v in variants):
            continue
        missing.append((key, os.path.basename(path)))
    for key, where in missing:
        print(f'{where}: "{key}"'.replace("\n", "\\n"))
    if missing:
        print(f"\n{len(missing)} strings without a {LANG} translation.")
        sys.exit(1)
    print(f"All Linux UI text has a {LANG} translation.")


main()
