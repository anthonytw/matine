#!/usr/bin/env python3
"""Every interface string in the app has an English translation.

    scripts/check-strings.py

Finds the Spanish literals the app shows (Text, Button, Label, Picker, Section,
TextField, SecureField, RetryMessage, section, confirmationDialog,
FormField/PinPad labels, `done:`, `prompt: Text`, and
LocalizedStringKey values such as `failure = "…"` or a `title(for:)` case) in
Apps/Matine/Matine/*.swift and Apps/MatineMobile/MatineMobile/*.swift (each with its own
Localizable.xcstrings), turns `\\(…)` interpolations into format
specifiers, and checks each against Localizable.xcstrings. Exit 1 lists the
missing ones. Text(verbatim:) and String(localized:) keys are covered by the
same rules; data from the server is never a literal, so it is never flagged.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPS = [ROOT / "Apps/Matine/Matine", ROOT / "Apps/MatineMobile/MatineMobile"]

CALLS = r"(?:Text|Button|Label|Picker|Section|TabSection|Tab|ContentUnavailableView|navigationTitle|alert|TextField|SecureField|Toggle|RetryMessage|section|confirmationDialog|String\(localized:)"
PATTERNS = [
    re.compile(CALLS + r'\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'(?:label|title|prompt|done):\s*(?:Text\()?"((?:[^"\\]|\\.)*)"'),
    re.compile(r'(?:failure|message|problem)\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'case [^:]+:\s*"((?:[^"\\]|\\.)*)"'),
    # A view's own helper taking a title as its last argument.
    re.compile(r'roleButton\([^"\n]*"((?:[^"\\]|\\.)*)"'),
]
VERBATIM = re.compile(r'Text\(verbatim:\s*"(?:[^"\\]|\\.)*"\)')
# Either side of a ternary inside one of the calls: Label(on ? "Quitar…" : "Fijar…").
# A ternary of two literals returned or assigned as a LocalizedStringKey.
TERNARY_VALUE = re.compile(r'(?:return|problem\s*=|failure\s*=)[^"\n]*\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"')
TERNARY = re.compile(CALLS + r'\([^"\n]*\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"')


def specifier_variants(literal: str) -> set[str]:
    """`Quedan \\(left) intentos` -> {"Quedan %@ intentos", "Quedan %lld intentos"}."""
    parts = re.split(r"\\\((?:[^()]|\([^()]*\))*\)", literal)
    if len(parts) == 1:
        return {literal}
    holes = len(parts) - 1
    variants = set()
    for mask in range(2 ** holes):
        out = parts[0]
        for i in range(holes):
            out += ("%lld" if mask >> i & 1 else "%@") + parts[i + 1]
        variants.add(out)
    return variants


def check(app: Path) -> tuple[list[str], int]:
    catalog = json.loads((app / "Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]

    def translated(key: str) -> bool:
        en = catalog.get(key, {}).get("localizations", {}).get("en", {})
        return "stringUnit" in en or "variations" in en

    missing = []
    for path in sorted(app.glob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            line = VERBATIM.sub("", line)
            literals = [l for pattern in PATTERNS for l in pattern.findall(line)]
            literals += [l for pair in TERNARY.findall(line) + TERNARY_VALUE.findall(line) for l in pair]
            for literal in literals:
                # Pure data ("\\(name)") needs no entry: judge the words, not the holes.
                words = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "", literal)
                if not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ¿¡]", words):
                    continue
                if not any(translated(v) for v in specifier_variants(literal)):
                    missing.append(f"{path.relative_to(ROOT)}:{number}: {literal}")
    return missing, len(catalog)


def main() -> int:
    missing: list[str] = []
    counts = []
    for app in APPS:
        found, count = check(app)
        missing += found
        counts.append(str(count))
    if missing:
        print("No English translation in Localizable.xcstrings for:")
        print("\n".join(f"  {m}" for m in missing))
        return 1
    print(f"ok: every interface string has an English translation ({' + '.join(counts)} in the catalogs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
