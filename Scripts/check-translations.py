#!/usr/bin/env python3
"""Lists UI text that has no translation yet.

Builds with the Swift compiler's string extraction (SwiftUI literals,
String(localized:)), adds labels passed to components as plain strings
(title: "…", L("…")), and compares with Resources/<lang>.lproj.

Usage: Scripts/check-translations.py [lang]     (default: de)
Exit code 1 when something is missing or a placeholder doesn't match.
"""
import glob, json, os, re, subprocess, sys, tempfile

LANG = sys.argv[1] if len(sys.argv) > 1 else "de"
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# Text that reads the same in every language (symbols, numbers, names).
SAME = re.compile(r"^[\s%@\d.,:;·<>()\[\]⌘⌥⇧⌃↩+\-−—→…lld/]*$")
KEEP = {"git-cowork", "OK", "Git", "SHA", "Commit", "Cowork", "repo", "detached", "detached HEAD",
        "Filter (⌥⌘F)", "Commit (⌘↩)", "Review: %@", "99+",
        "Terminal, iTerm, Ghostty, Warp…", "Visual Studio Code, Cursor, Zed…"}
# Commit messages on refs/cowork/main stay English for everyone.
COMMIT_MESSAGES = {"Update team", "Merge cowork changes"}
# Files whose literals are cowork commit messages.
SKIP_FILES = ("/Debug/", "CoworkStore.swift")


def code_keys():
    keys = {}
    with tempfile.TemporaryDirectory() as out:
        r = subprocess.run(["swift", "build", "-Xswiftc", "-emit-localized-strings",
                            "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(r.stdout[-2000:] + r.stderr[-2000:])
        for f in glob.glob(out + "/*.stringsdata"):
            d = json.load(open(f))
            if any(s in d["source"] for s in SKIP_FILES):
                continue
            for entries in d.get("tables", {}).values():
                for e in entries:
                    keys.setdefault(e["key"], os.path.basename(d["source"]))
    unescape = lambda s: s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
    for path in glob.glob("Sources/GitCowork/**/*.swift", recursive=True):
        if any(s in path for s in SKIP_FILES):
            continue
        src = open(path).read()
        found = [m.group(1) for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"\)', src)]
        found += [m.group(1) for m in re.finditer(r'\bSectionHeader\("((?:[^"\\]|\\.)*)"', src)]
        found += [m.group(2) for m in re.finditer(
            r'\b(title|label|caption|text|help|message|subtitle|confirmTitle|placeholder|discard|stage)(?::|\s*=)\s*"((?:[^"\\]|\\.)*)"', src)]
        for k in found:
            if "\\(" not in k:
                keys.setdefault(unescape(k), os.path.basename(path))
    return keys


def translations(lang):
    path = f"Resources/{lang}.lproj/Localizable.strings"
    r = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{path}: {r.stderr}")
    return json.loads(r.stdout)


def placeholders(s):
    out, n = [], 0
    for m in re.finditer(r"%(?:(\d+)\$)?(@|lld|ld|d|f)", s):
        n += 1
        out.append((int(m.group(1)) if m.group(1) else n, m.group(2)))
    return sorted(out)


keys = code_keys()
tr = translations(LANG)
# Task status names and undo titles come from GitCoworkCore and are looked up with L(title).
extra = {"Backlog", "To Do", "In Progress", "In Review", "Done",
         "Undo Commit", "Undo Amend", "Undo Reset", "Undo Checkout", "Undo Delete Branch"}
missing = sorted(k for k in set(keys) | extra
                 if k not in tr and k not in KEEP and k not in COMMIT_MESSAGES and not SAME.match(k))
bad = sorted(k for k, v in tr.items() if placeholders(k) != placeholders(v))
unused = sorted(set(tr) - set(keys) - extra)

for k in missing:
    print(f"missing   {json.dumps(k, ensure_ascii=False)}   ({keys.get(k, 'GitCoworkCore')})")
for k in bad:
    print(f"mismatch  {json.dumps(k, ensure_ascii=False)} => {json.dumps(tr[k], ensure_ascii=False)}")
for k in unused:
    print(f"unused    {json.dumps(k, ensure_ascii=False)}")
print(f"{len(tr)} translated, {len(missing)} missing, {len(bad)} placeholder mismatches, {len(unused)} unused")
sys.exit(1 if missing or bad else 0)
