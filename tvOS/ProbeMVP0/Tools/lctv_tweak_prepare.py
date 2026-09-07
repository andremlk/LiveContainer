#!/usr/bin/env python3
"""Classify a staged tweak payload and produce a LiveContainerTV preparation plan.

PREP-2 deliberately stops before code signing or runtime injection. It establishes
which executable objects are safe candidates for tvOS and emits the exact queue a
future signer/patcher must process. iOS-only objects are rejected by default.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import struct
from pathlib import Path
from typing import Any, Dict, List, Optional

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_BUILD_VERSION = 0x32
DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}
PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "Mac Catalyst", 7: "iOS Simulator", 8: "tvOS Simulator", 11: "visionOS"}


def cstr(blob: bytes, start: int, end: int) -> str:
    raw = blob[start:end].split(b"\0", 1)[0]
    return raw.decode("utf-8", "replace")


def parse_macho(path: Path) -> Optional[Dict[str, Any]]:
    blob = path.read_bytes()
    if len(blob) < 32:
        return None
    magic = struct.unpack_from("<I", blob, 0)[0]
    if magic != MH_MAGIC_64:
        return None
    _, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", blob, 0)
    if cputype != CPU_TYPE_ARM64:
        arch = f"cpu:{cputype:#x}"
    else:
        arch = "arm64e" if (cpusubtype & 0xFF) == CPU_SUBTYPE_ARM64E else "arm64"

    platform = None
    minos = None
    linked: List[str] = []
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(blob):
            break
        cmd, cmdsize = struct.unpack_from("<II", blob, off)
        if cmdsize < 8 or off + cmdsize > len(blob):
            break
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform_id, minos_raw = struct.unpack_from("<II", blob, off + 8)
            platform = PLATFORMS.get(platform_id, f"platform:{platform_id}")
            minos = decode_version(minos_raw)
        elif cmd == LC_VERSION_MIN_TVOS and cmdsize >= 16:
            minos_raw = struct.unpack_from("<I", blob, off + 8)[0]
            platform = "tvOS"
            minos = decode_version(minos_raw)
        elif cmd == LC_VERSION_MIN_IPHONEOS and cmdsize >= 16:
            minos_raw = struct.unpack_from("<I", blob, off + 8)[0]
            platform = "iOS"
            minos = decode_version(minos_raw)
        elif cmd in DYLIB_CMDS and cmdsize >= 24:
            nameoff = struct.unpack_from("<I", blob, off + 8)[0]
            if 0 < nameoff < cmdsize:
                linked.append(cstr(blob, off + nameoff, off + cmdsize))
        off += cmdsize

    return {
        "arch": arch,
        "platform": platform or "unknown",
        "minimum_os": minos,
        "filetype": filetype,
        "linked_dylibs": linked,
        "size": len(blob),
    }


def decode_version(v: int) -> str:
    return f"{(v >> 16) & 0xFFFF}.{(v >> 8) & 0xFF}.{v & 0xFF}"


def infer_kind(path: Path) -> str:
    s = str(path)
    if path.suffix == ".dylib":
        return "dylib"
    if ".framework/" in s:
        return "framework-binary"
    return "macho"


def read_filters(root: Path) -> List[Dict[str, Any]]:
    out = []
    for path in root.rglob("*.plist"):
        try:
            obj = plistlib.loads(path.read_bytes())
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        filt = obj.get("Filter") or obj.get("filter")
        if isinstance(filt, dict):
            out.append({
                "path": str(path.relative_to(root)),
                "bundles": filt.get("Bundles", []),
                "executables": filt.get("Executables", []),
                "classes": filt.get("Classes", []),
            })
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("staged", type=Path)
    ap.add_argument("--output", type=Path)
    ap.add_argument("--allow-ios", action="store_true", help="classify iOS binaries as experimental instead of reject")
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()

    root = args.staged.resolve()
    if not root.is_dir():
        raise SystemExit(f"staging directory not found: {root}")

    objects = []
    sign_queue = []
    rejected = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        try:
            info = parse_macho(path)
        except (OSError, struct.error):
            info = None
        if info is None:
            continue
        rel = str(path.relative_to(root))
        status = "ready"
        reasons = []
        if info["arch"] not in ("arm64", "arm64e"):
            status = "reject"
            reasons.append("unsupported CPU architecture")
        if info["platform"] == "tvOS":
            pass
        elif info["platform"] == "iOS" and args.allow_ios:
            status = "experimental" if status != "reject" else status
            reasons.append("iOS binary; tvOS compatibility not guaranteed")
        else:
            status = "reject"
            reasons.append(f"platform is {info['platform']}, expected tvOS")

        item = {"path": rel, "kind": infer_kind(path), "status": status, "reasons": reasons, **info}
        objects.append(item)
        if status in ("ready", "experimental"):
            sign_queue.append(rel)
        else:
            rejected.append(rel)

    report = {
        "format": "lctv-tweak-prepare-v1",
        "root": str(root),
        "filters": read_filters(root),
        "objects": objects,
        "sign_queue": sign_queue,
        "rejected": rejected,
        "summary": {
            "mach_o_objects": len(objects),
            "ready_or_experimental": len(sign_queue),
            "rejected": len(rejected),
        },
    }

    if args.output:
        out = args.output.resolve()
        if out.exists():
            shutil.rmtree(out)
        shutil.copytree(root, out)
        report["prepared_root"] = str(out)

    report_path = args.report or ((args.output or root) / "LCTVPrepareReport.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))

    # Rejection is represented in the report, not as a process failure: callers may
    # inspect third-party packages without breaking UI/import flows.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
