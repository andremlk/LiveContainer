#!/usr/bin/env python3
"""Analyze iOS/tvOS tweak .deb packages without installing them.

The analyzer is deliberately read-only. It parses the Debian ar container,
control metadata, payload layout, MobileSubstrate filter plists, and Mach-O
binaries embedded in the package. It is intended as the first stage of the
LiveContainerTV tweak pipeline: inspect -> classify -> prepare -> sign -> load.

No files are extracted to the host filesystem during normal analysis.
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import io
import json
import lzma
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

AR_MAGIC = b"!<arch>\n"
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_BUILD_VERSION = 0x32

PLATFORM_NAMES = {
    1: "macOS",
    2: "iOS",
    3: "tvOS",
    4: "watchOS",
    5: "bridgeOS",
    6: "Mac Catalyst",
    7: "iOS Simulator",
    8: "tvOS Simulator",
    9: "watchOS Simulator",
    10: "DriverKit",
    11: "visionOS",
    12: "visionOS Simulator",
}

DYLIB_COMMANDS = {
    LC_LOAD_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
}


class DebFormatError(RuntimeError):
    pass


@dataclass
class ArMember:
    name: str
    data: bytes


def _decode_ascii(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace").rstrip()


def parse_ar(blob: bytes) -> list[ArMember]:
    if not blob.startswith(AR_MAGIC):
        raise DebFormatError("not an ar archive / invalid Debian package header")

    members: list[ArMember] = []
    pos = len(AR_MAGIC)
    gnu_names = b""

    while pos < len(blob):
        if pos + 60 > len(blob):
            raise DebFormatError("truncated ar member header")
        hdr = blob[pos : pos + 60]
        pos += 60
        if hdr[58:60] != b"`\n":
            raise DebFormatError("invalid ar member terminator")

        raw_name = _decode_ascii(hdr[0:16])
        size_text = _decode_ascii(hdr[48:58])
        try:
            size = int(size_text)
        except ValueError as exc:
            raise DebFormatError(f"invalid ar member size: {size_text!r}") from exc

        if pos + size > len(blob):
            raise DebFormatError("truncated ar member payload")
        data = blob[pos : pos + size]
        pos += size
        if pos & 1:
            pos += 1

        name = raw_name
        if raw_name == "//":
            gnu_names = data
            continue
        if raw_name.startswith("#1/"):
            try:
                nlen = int(raw_name[3:])
            except ValueError as exc:
                raise DebFormatError("invalid BSD ar extended filename") from exc
            if nlen > len(data):
                raise DebFormatError("invalid BSD ar extended filename length")
            name = data[:nlen].decode("utf-8", errors="replace").rstrip("\x00")
            data = data[nlen:]
        elif raw_name.startswith("/") and raw_name[1:].isdigit() and gnu_names:
            off = int(raw_name[1:])
            if off >= len(gnu_names):
                raise DebFormatError("invalid GNU ar filename offset")
            end = gnu_names.find(b"/\n", off)
            if end < 0:
                end = gnu_names.find(b"\x00", off)
            if end < 0:
                end = len(gnu_names)
            name = gnu_names[off:end].decode("utf-8", errors="replace")
        else:
            name = raw_name.rstrip("/")

        members.append(ArMember(name=name, data=data))

    return members


def _decompress_zstd(data: bytes) -> bytes:
    try:
        import zstandard  # type: ignore

        return zstandard.ZstdDecompressor().decompress(data)
    except Exception:
        zstd = shutil.which("zstd")
        if not zstd:
            raise DebFormatError(
                "zstd-compressed Debian member requires python-zstandard or the zstd command"
            )
        cp = subprocess.run(
            [zstd, "-q", "-d", "-c"],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if cp.returncode != 0:
            raise DebFormatError(
                "failed to decompress zstd member: "
                + cp.stderr.decode("utf-8", errors="replace").strip()
            )
        return cp.stdout


def open_tar_member(member: ArMember) -> tarfile.TarFile:
    data = member.data
    lower = member.name.lower()
    if lower.endswith(".zst") or lower.endswith(".zstd"):
        data = _decompress_zstd(data)
    # tarfile handles tar, gzip, bzip2 and xz/lzma itself.
    try:
        return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    except tarfile.TarError as exc:
        raise DebFormatError(f"cannot open {member.name}: {exc}") from exc


def normalize_tar_path(name: str) -> str:
    name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")


def is_safe_relative_path(name: str) -> bool:
    normalized = normalize_tar_path(name)
    if not normalized:
        return True
    parts = normalized.split("/")
    return all(part not in ("..", "") for part in parts)


def parse_debian_control(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    current: str | None = None
    for raw_line in text.splitlines():
        if not raw_line:
            current = None
            continue
        if raw_line[:1].isspace() and current:
            result[current] += "\n" + raw_line[1:]
            continue
        if ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        current = key.strip()
        result[current] = value.strip()
    return result


def read_tar_file(tf: tarfile.TarFile, candidate_names: Iterable[str]) -> bytes | None:
    wanted = {normalize_tar_path(x) for x in candidate_names}
    for member in tf.getmembers():
        if normalize_tar_path(member.name) in wanted and member.isfile():
            fp = tf.extractfile(member)
            return fp.read() if fp else None
    return None


def macho_platform_name(value: int) -> str:
    return PLATFORM_NAMES.get(value, f"platform-{value}")


def _cstr(data: bytes) -> str:
    return data.split(b"\x00", 1)[0].decode("utf-8", errors="replace")


def parse_thin_macho(data: bytes, *, label: str = "") -> dict[str, Any] | None:
    if len(data) < 32:
        return None

    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le == MH_MAGIC_64:
        endian = "<"
    elif magic_le == MH_CIGAM_64:
        endian = ">"
    else:
        return None

    try:
        _, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
            endian + "IiiIIIII", data, 0
        )
    except struct.error:
        return None

    arch = "unknown"
    if cputype == CPU_TYPE_ARM64:
        subtype = cpusubtype & 0x00FFFFFF
        arch = "arm64e" if subtype == CPU_SUBTYPE_ARM64E else "arm64"

    platforms: list[str] = []
    dependencies: list[str] = []
    min_os: list[str] = []
    offset = 32
    command_region_end = min(len(data), 32 + sizeofcmds)

    for _ in range(ncmds):
        if offset + 8 > command_region_end:
            break
        cmd, cmdsize = struct.unpack_from(endian + "II", data, offset)
        if cmdsize < 8 or offset + cmdsize > command_region_end:
            break
        cmdblob = data[offset : offset + cmdsize]

        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform, minos, sdk, ntools = struct.unpack_from(endian + "IIII", cmdblob, 8)
            pname = macho_platform_name(platform)
            if pname not in platforms:
                platforms.append(pname)
            min_os.append(f"{pname}:{decode_packed_version(minos)}")
        elif cmd == LC_VERSION_MIN_IPHONEOS and cmdsize >= 16:
            if "iOS" not in platforms:
                platforms.append("iOS")
            version, sdk = struct.unpack_from(endian + "II", cmdblob, 8)
            min_os.append(f"iOS:{decode_packed_version(version)}")
        elif cmd == LC_VERSION_MIN_TVOS and cmdsize >= 16:
            if "tvOS" not in platforms:
                platforms.append("tvOS")
            version, sdk = struct.unpack_from(endian + "II", cmdblob, 8)
            min_os.append(f"tvOS:{decode_packed_version(version)}")
        elif cmd in DYLIB_COMMANDS and cmdsize >= 24:
            nameoff = struct.unpack_from(endian + "I", cmdblob, 8)[0]
            if 0 <= nameoff < len(cmdblob):
                dependencies.append(_cstr(cmdblob[nameoff:]))

        offset += cmdsize

    return {
        "label": label,
        "kind": "mach-o",
        "arch": arch,
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "platforms": platforms,
        "minimum_os": min_os,
        "dependencies": dependencies,
        "flags": flags,
    }


def decode_packed_version(value: int) -> str:
    major = (value >> 16) & 0xFFFF
    minor = (value >> 8) & 0xFF
    patch = value & 0xFF
    return f"{major}.{minor}.{patch}"


def parse_fat_macho(data: bytes, *, label: str = "") -> list[dict[str, Any]] | None:
    if len(data) < 8:
        return None

    magic = data[:4]
    if magic == b"\xca\xfe\xba\xbe":
        endian, is64 = ">", False
    elif magic == b"\xbe\xba\xfe\xca":
        endian, is64 = "<", False
    elif magic == b"\xca\xfe\xba\xbf":
        endian, is64 = ">", True
    elif magic == b"\xbf\xba\xfe\xca":
        endian, is64 = "<", True
    else:
        return None

    nfat = struct.unpack_from(endian + "I", data, 4)[0]
    offset = 8
    slices: list[dict[str, Any]] = []
    for index in range(nfat):
        try:
            if is64:
                cputype, cpusubtype, fileoff, size, align, reserved = struct.unpack_from(
                    endian + "iiQQII", data, offset
                )
                offset += 32
            else:
                cputype, cpusubtype, fileoff, size, align = struct.unpack_from(
                    endian + "iiIII", data, offset
                )
                offset += 20
        except struct.error:
            break
        if fileoff + size > len(data):
            continue
        parsed = parse_thin_macho(data[fileoff : fileoff + size], label=f"{label}#{index}")
        if parsed:
            parsed["fat_cputype"] = cputype
            parsed["fat_cpusubtype"] = cpusubtype
            slices.append(parsed)
    return slices


def parse_macho(data: bytes, *, label: str = "") -> list[dict[str, Any]]:
    fat = parse_fat_macho(data, label=label)
    if fat is not None:
        return fat
    thin = parse_thin_macho(data, label=label)
    return [thin] if thin else []


def classify_path(path: str) -> str:
    lower = path.lower()
    if lower.endswith(".dylib"):
        return "dylib"
    if ".framework/" in lower or lower.endswith(".framework"):
        return "framework"
    if ".bundle/" in lower or lower.endswith(".bundle"):
        return "bundle"
    if lower.endswith(".plist"):
        return "plist"
    if lower.endswith(".appex") or ".appex/" in lower:
        return "appex"
    return "other"


def analyze_filter_plist(path: str, data: bytes) -> dict[str, Any]:
    result: dict[str, Any] = {"path": path, "parsed": False}
    try:
        obj = plistlib.loads(data)
    except Exception as exc:
        result["error"] = str(exc)
        return result
    if not isinstance(obj, dict):
        result["error"] = "plist root is not a dictionary"
        return result

    result["parsed"] = True
    filt = obj.get("Filter")
    if isinstance(filt, dict):
        for key in ("Bundles", "Executables", "Classes"):
            value = filt.get(key)
            if isinstance(value, list):
                result[key.lower()] = [str(x) for x in value]
    result["raw_keys"] = sorted(str(k) for k in obj.keys())
    return result


def inspect_package(path: Path) -> dict[str, Any]:
    blob = path.read_bytes()
    members = parse_ar(blob)
    member_map = {m.name: m for m in members}

    debian_binary = member_map.get("debian-binary")
    if debian_binary is None:
        raise DebFormatError("missing debian-binary member")
    version = debian_binary.data.decode("ascii", errors="replace").strip()

    control_member = next((m for m in members if m.name.startswith("control.tar")), None)
    data_member = next((m for m in members if m.name.startswith("data.tar")), None)
    if control_member is None or data_member is None:
        raise DebFormatError("missing control.tar.* or data.tar.* member")

    control_tf = open_tar_member(control_member)
    control_bytes = read_tar_file(control_tf, ["control", "./control"])
    control_tf.close()
    control = parse_debian_control(
        (control_bytes or b"").decode("utf-8", errors="replace")
    )

    data_tf = open_tar_member(data_member)
    entries: list[dict[str, Any]] = []
    suspicious_paths: list[str] = []
    filter_plists: list[dict[str, Any]] = []
    macho_binaries: list[dict[str, Any]] = []
    categories: dict[str, int] = {
        "dylib": 0,
        "framework": 0,
        "bundle": 0,
        "plist": 0,
        "appex": 0,
        "other": 0,
    }

    seen_framework_roots: set[str] = set()
    seen_bundle_roots: set[str] = set()

    for member in data_tf.getmembers():
        normalized = normalize_tar_path(member.name)
        if not is_safe_relative_path(member.name):
            suspicious_paths.append(member.name)
        kind = classify_path(normalized)
        if kind == "framework":
            root = normalized.split(".framework", 1)[0] + ".framework"
            if root in seen_framework_roots:
                count_this = False
            else:
                seen_framework_roots.add(root)
                count_this = True
        elif kind == "bundle":
            root = normalized.split(".bundle", 1)[0] + ".bundle"
            if root in seen_bundle_roots:
                count_this = False
            else:
                seen_bundle_roots.add(root)
                count_this = True
        else:
            count_this = True
        if count_this:
            categories[kind] += 1

        entries.append(
            {
                "path": normalized,
                "type": "dir" if member.isdir() else "file" if member.isfile() else "other",
                "size": member.size,
                "kind": kind,
            }
        )

        if not member.isfile():
            continue
        fp = data_tf.extractfile(member)
        if fp is None:
            continue
        payload = fp.read()

        lower = normalized.lower()
        if (
            lower.startswith("library/mobilesubstrate/dynamiclibraries/")
            and lower.endswith(".plist")
        ):
            filter_plists.append(analyze_filter_plist(normalized, payload))

        parsed = parse_macho(payload, label=normalized)
        if parsed:
            macho_binaries.extend(parsed)

    data_tf.close()

    target_bundles: set[str] = set()
    target_execs: set[str] = set()
    for filt in filter_plists:
        target_bundles.update(filt.get("bundles", []))
        target_execs.update(filt.get("executables", []))

    arches = sorted({m.get("arch", "unknown") for m in macho_binaries})
    platforms = sorted({p for m in macho_binaries for p in m.get("platforms", [])})
    dependencies = sorted({d for m in macho_binaries for d in m.get("dependencies", [])})

    has_arm64 = any(m.get("arch") in ("arm64", "arm64e") for m in macho_binaries)
    has_arm64e = any(m.get("arch") == "arm64e" for m in macho_binaries)
    has_tvos = "tvOS" in platforms
    ios_only = bool(platforms) and set(platforms).issubset({"iOS"})

    notes: list[str] = []
    if suspicious_paths:
        notes.append("Package contains unsafe traversal/absolute payload paths; reject installation.")
    if not macho_binaries:
        notes.append("No Mach-O binary was detected in the package payload.")
    elif not has_arm64:
        notes.append("No arm64/arm64e Mach-O slice detected.")
    if has_arm64e:
        notes.append("arm64e content detected; host/signing/runtime compatibility must be verified.")
    if has_tvos:
        notes.append("At least one binary explicitly targets tvOS.")
    elif ios_only:
        notes.append("Mach-O binaries identify as iOS-only; tvOS execution is experimental and may fail.")
    elif not platforms and macho_binaries:
        notes.append("Mach-O platform could not be determined from load commands.")

    if suspicious_paths or not has_arm64:
        status = "reject"
    elif has_tvos:
        status = "promising"
    elif ios_only:
        status = "experimental"
    else:
        status = "unknown"

    return {
        "file": str(path),
        "size": path.stat().st_size,
        "debian_format_version": version,
        "ar_members": [m.name for m in members],
        "control": control,
        "payload": {
            "entry_count": len(entries),
            "categories": categories,
            "entries": entries,
            "unsafe_paths": suspicious_paths,
        },
        "filters": filter_plists,
        "targets": {
            "bundles": sorted(target_bundles),
            "executables": sorted(target_execs),
        },
        "macho": {
            "count": len(macho_binaries),
            "architectures": arches,
            "platforms": platforms,
            "dependencies": dependencies,
            "binaries": macho_binaries,
        },
        "compatibility": {
            "status": status,
            "has_arm64": has_arm64,
            "has_arm64e": has_arm64e,
            "has_tvos": has_tvos,
            "ios_only": ios_only,
            "notes": notes,
        },
    }


def print_human(report: dict[str, Any]) -> None:
    control = report["control"]
    compat = report["compatibility"]
    payload = report["payload"]
    macho = report["macho"]
    targets = report["targets"]

    print("LiveContainerTV Debian tweak analysis")
    print("=" * 40)
    print(f"File: {report['file']}")
    print(f"Package: {control.get('Package', '?')}")
    print(f"Name: {control.get('Name', control.get('Package', '?'))}")
    print(f"Version: {control.get('Version', '?')}")
    print(f"Architecture: {control.get('Architecture', '?')}")
    print(f"Depends: {control.get('Depends', '-')}")
    print(f"Debian format: {report['debian_format_version']}")
    print()
    print("Detected payload")
    for key in ("dylib", "framework", "bundle", "plist", "appex", "other"):
        print(f"  {key:10s}: {payload['categories'].get(key, 0)}")
    print()
    print(f"Mach-O binaries: {macho['count']}")
    print(f"Architectures: {', '.join(macho['architectures']) or '-'}")
    print(f"Platforms: {', '.join(macho['platforms']) or '-'}")
    print(f"Target bundles: {', '.join(targets['bundles']) or '-'}")
    print(f"Target executables: {', '.join(targets['executables']) or '-'}")
    print(f"Compatibility: {compat['status'].upper()}")
    for note in compat["notes"]:
        print(f"  - {note}")


def _make_ar_member(name: str, data: bytes) -> bytes:
    safe_name = (name + "/")[:16].ljust(16)
    header = (
        safe_name.encode("ascii")
        + b"0".ljust(12)
        + b"0".ljust(6)
        + b"0".ljust(6)
        + b"100644".ljust(8)
        + str(len(data)).encode("ascii").ljust(10)
        + b"`\n"
    )
    result = header + data
    if len(data) & 1:
        result += b"\n"
    return result


def _make_tar_gz(files: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, data in files.items():
            ti = tarfile.TarInfo(name=name)
            ti.size = len(data)
            ti.mode = 0o644
            tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def _synthetic_tvos_macho() -> bytes:
    # Minimal arm64 MH_DYLIB with one LC_BUILD_VERSION(tvOS) command.
    cmdsize = 24
    header = struct.pack(
        "<IiiIIIII",
        MH_MAGIC_64,
        CPU_TYPE_ARM64,
        0,
        6,  # MH_DYLIB
        1,
        cmdsize,
        0,
        0,
    )
    cmd = struct.pack("<IIIIII", LC_BUILD_VERSION, cmdsize, 3, 0x000F0000, 0x001A0000, 0)
    return header + cmd


def run_self_test() -> None:
    control = (
        "Package: dev.livecontainertv.synthetic\n"
        "Name: LCTV Synthetic Tweak\n"
        "Version: 1.0\n"
        "Architecture: iphoneos-arm64\n"
        "Depends: mobilesubstrate\n"
    ).encode()
    filter_plist = plistlib.dumps(
        {"Filter": {"Bundles": ["com.example.test"], "Executables": ["TestApp"]}}
    )
    control_tar = _make_tar_gz({"./control": control})
    data_tar = _make_tar_gz(
        {
            "./Library/MobileSubstrate/DynamicLibraries/Synthetic.dylib": _synthetic_tvos_macho(),
            "./Library/MobileSubstrate/DynamicLibraries/Synthetic.plist": filter_plist,
            "./Library/Application Support/Synthetic.bundle/Info.plist": plistlib.dumps(
                {"CFBundleIdentifier": "dev.livecontainertv.synthetic.resources"}
            ),
        }
    )
    deb = (
        AR_MAGIC
        + _make_ar_member("debian-binary", b"2.0\n")
        + _make_ar_member("control.tar.gz", control_tar)
        + _make_ar_member("data.tar.gz", data_tar)
    )

    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "synthetic.deb"
        p.write_bytes(deb)
        report = inspect_package(p)
        assert report["control"]["Package"] == "dev.livecontainertv.synthetic"
        assert report["compatibility"]["has_arm64"] is True
        assert report["compatibility"]["has_tvos"] is True
        assert report["compatibility"]["status"] == "promising"
        assert report["targets"]["bundles"] == ["com.example.test"]
        assert report["payload"]["categories"]["dylib"] == 1
        assert report["payload"]["categories"]["bundle"] == 1
    print("SELF-TEST PASS: Debian parser, filter parser, and tvOS Mach-O classifier")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze a tweak .deb for LiveContainerTV compatibility without installing it."
    )
    parser.add_argument("deb", nargs="?", type=Path, help="path to .deb package")
    parser.add_argument("--json-out", type=Path, help="write full JSON report")
    parser.add_argument("--json", action="store_true", help="print JSON instead of summary")
    parser.add_argument("--self-test", action="store_true", help="run built-in synthetic package test")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0
    if args.deb is None:
        parser.error("a .deb path is required unless --self-test is used")
    if not args.deb.is_file():
        parser.error(f"file not found: {args.deb}")

    try:
        report = inspect_package(args.deb)
    except (OSError, DebFormatError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.json_out:
        args.json_out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_human(report)

    return 1 if report["compatibility"]["status"] == "reject" else 0


if __name__ == "__main__":
    raise SystemExit(main())
