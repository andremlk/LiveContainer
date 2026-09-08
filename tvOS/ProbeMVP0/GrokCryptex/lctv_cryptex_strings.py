#!/usr/bin/env python3
"""Extract cryptex asset-type strings from a local Mach-O if the user has one.

This is the evidence path for image-type-index. It never talks to the Apple TV
and never installs anything. Point it at libcryptex_core or cryptexd copied
out of an AppleTV14,1 tvOS 18.6 IPSW / dyld_shared_cache dump.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

NEEDLES = (
    b"GenericVolume",
    b"GenericDmg",
    b"Cryptex1,GenericVolume",
    b"Cryptex1,GenericDmg",
    b"asset already present",
    b"image-type-index",
    b"gtgv",
    b"gdmg",
    b"ginf",
    b"gtcd",
    b"cx1p",
    b"cryptex_asset_types",
)


def extract(path: Path) -> int:
    data = path.read_bytes()
    print(f"LCTV GROK STRINGS: {path} ({len(data)} bytes)", flush=True)
    found = 0
    for needle in NEEDLES:
        hits = [m.start() for m in re.finditer(re.escape(needle), data)]
        if hits:
            found += 1
            preview = ", ".join(hex(h) for h in hits[:8])
            extra = "" if len(hits) <= 8 else f" … +{len(hits) - 8}"
            print(f"  HIT {needle.decode('ascii', 'replace')} @ {preview}{extra}", flush=True)
        else:
            print(f"  MISS {needle.decode('ascii', 'replace')}", flush=True)

    for label in (b"GenericVolume", b"GenericDmg", b"gdmg", b"gtgv"):
        idx = data.find(label)
        if idx < 0:
            continue
        start = max(0, idx - 64)
        stop = min(len(data), idx + 96)
        chunk = data[start:stop]
        printable = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  CTX {label.decode()} = {printable}", flush=True)
    print(f"LCTV GROK STRINGS: {'PASS' if found else 'FAIL'} matches={found}", flush=True)
    return 0 if found else 1


def main() -> int:
    if len(sys.argv) != 2:
        print("uso: lctv_cryptex_strings.py /ruta/libcryptex_core-o-cryptexd", file=sys.stderr)
        return 2
    path = Path(sys.argv[1]).expanduser()
    if not path.is_file():
        print(f"ERROR: no existe {path}", file=sys.stderr)
        return 1
    return extract(path)


if __name__ == "__main__":
    raise SystemExit(main())
