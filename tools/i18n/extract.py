#!/usr/bin/env python3
"""Collect MDMI18n keys from Swift sources into i18n/en.tsv.

MDM keeps every user-visible string in a TSV catalog. Siphon's MDM-aligned
views use MDMI18n.t("key"); this script regenerates the English catalog so a
translator never has to read Swift. Keys used by older views (literal Chinese)
are intentionally not invented here — they migrate as those views are ported.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources"
OUTPUT = ROOT / "i18n" / "en.tsv"
PATTERN = re.compile(r'MDMI18n\.t\(\s*"([^"\\]+)"')


def english_catalog() -> dict[str, str]:
    path = SOURCE / "Siphon" / "MDM" / "I18n.swift"
    text = path.read_text(encoding="utf-8")
    marker = "private let English: [String: String] = ["
    start = text.find(marker)
    if start < 0:
        return {}
    end = text.find("\n]", start)
    block = text[start:end if end > 0 else len(text)]
    pairs = re.findall(r'"([^"\\]+)"\s*:\s*"([^"\\]*)"', block)
    return dict(pairs)


def main() -> int:
    keys: set[str] = set()
    for path in SOURCE.rglob("*.swift"):
        keys.update(PATTERN.findall(path.read_text(encoding="utf-8")))
    values = english_catalog()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# key\tenglish", ""]
    lines.extend(f"{key}\t{values.get(key, key)}" for key in sorted(keys))
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(keys)} keys to {OUTPUT.relative_to(ROOT)} "
          f"({sum(1 for k in keys if k in values)} translated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
