#!/usr/bin/env python3
"""Safely stage the payload of a tweak .deb into an app-controlled directory.

This is intentionally NOT a Debian package installer:
- maintainer scripts are never executed
- control scripts are never extracted into the runtime payload
- absolute paths, parent traversal, symlinks and hardlinks are rejected
- files are written only below the requested staging directory

The staged tree preserves the package's relative data.tar layout so a later
LiveContainerTV preparation step can classify dylibs/frameworks/bundles and
rewrite/sign only the objects that are actually needed by a selected guest.
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import io
import json
import lzma
import os
import shutil
import tarfile
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Tuple

AR_MAGIC = b"!<arch>\n"


class DebStageError(RuntimeError):
    pass


def read_ar(path: Path) -> Dict[str, bytes]:
    data = path.read_bytes()
    if not data.startswith(AR_MAGIC):
        raise DebStageError("not a Debian ar archive")
    out: Dict[str, bytes] = {}
    pos = len(AR_MAGIC)
    while pos < len(data):
        if pos + 60 > len(data):
            raise DebStageError("truncated ar header")
        hdr = data[pos:pos + 60]
        pos += 60
        if hdr[58:60] != b"`\n":
            raise DebStageError("invalid ar member header")
        raw_name = hdr[0:16].decode("utf-8", "replace").strip()
        try:
            size = int(hdr[48:58].decode("ascii").strip())
        except ValueError as exc:
            raise DebStageError("invalid ar member size") from exc
        payload = data[pos:pos + size]
        if len(payload) != size:
            raise DebStageError("truncated ar member")
        pos += size + (size & 1)

        # BSD/GNU extended filename form used by some ar implementations.
        name = raw_name.rstrip("/")
        if raw_name.startswith("#1/"):
            nlen = int(raw_name[3:])
            name = payload[:nlen].decode("utf-8", "replace")
            payload = payload[nlen:]
        out[name] = payload
    return out


def decompress_tar(name: str, payload: bytes) -> bytes:
    if name.endswith(".tar"):
        return payload
    if name.endswith(".tar.gz"):
        return gzip.decompress(payload)
    if name.endswith(".tar.xz"):
        return lzma.decompress(payload)
    if name.endswith(".tar.bz2"):
        return bz2.decompress(payload)
    if name.endswith(".tar.zst") or name.endswith(".tar.zstd"):
        try:
            import zstandard  # type: ignore
        except ImportError as exc:
            raise DebStageError(
                "zstd-compressed deb requires Python package 'zstandard'"
            ) from exc
        return zstandard.ZstdDecompressor().decompress(payload)
    raise DebStageError(f"unsupported tar compression: {name}")


def find_member(members: Dict[str, bytes], prefix: str) -> Tuple[str, bytes]:
    for name, payload in members.items():
        if name == prefix or name.startswith(prefix + "."):
            return name, payload
    raise DebStageError(f"missing {prefix} member")


def parse_control(control_tar: bytes) -> Dict[str, str]:
    with tarfile.open(fileobj=io.BytesIO(control_tar), mode="r:") as tf:
        candidate = None
        for member in tf.getmembers():
            cleaned = member.name.lstrip("./")
            if cleaned == "control" and member.isfile():
                candidate = member
                break
        if candidate is None:
            return {}
        fp = tf.extractfile(candidate)
        if fp is None:
            return {}
        text = fp.read().decode("utf-8", "replace")

    result: Dict[str, str] = {}
    key = None
    for raw in text.splitlines():
        if raw.startswith((" ", "\t")) and key:
            result[key] += "\n" + raw.strip()
            continue
        if ":" not in raw:
            continue
        key, value = raw.split(":", 1)
        key = key.strip()
        result[key] = value.strip()
    return result


def safe_relative(name: str) -> PurePosixPath:
    # Debian payloads commonly use ./ prefixes; strip only those.
    while name.startswith("./"):
        name = name[2:]
    p = PurePosixPath(name)
    if not name or name == ".":
        return PurePosixPath(".")
    if p.is_absolute() or any(part in ("", "..") for part in p.parts):
        raise DebStageError(f"unsafe payload path: {name}")
    return p


def ensure_below(root: Path, rel: PurePosixPath) -> Path:
    target = root.joinpath(*rel.parts)
    root_real = root.resolve()
    parent_real = target.parent.resolve()
    if os.path.commonpath([str(root_real), str(parent_real)]) != str(root_real):
        raise DebStageError(f"path escapes staging root: {rel}")
    return target


def stage_data(data_tar: bytes, dest: Path) -> Dict[str, object]:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)

    files = []
    skipped_special = []
    with tarfile.open(fileobj=io.BytesIO(data_tar), mode="r:") as tf:
        for member in tf.getmembers():
            rel = safe_relative(member.name)
            if rel == PurePosixPath("."):
                continue
            target = ensure_below(dest, rel)

            if member.issym() or member.islnk():
                raise DebStageError(f"links are not allowed in tweak packages: {member.name}")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                skipped_special.append(member.name)
                continue

            target.parent.mkdir(parents=True, exist_ok=True)
            fp = tf.extractfile(member)
            if fp is None:
                raise DebStageError(f"unable to read payload member: {member.name}")
            with target.open("wb") as out:
                shutil.copyfileobj(fp, out)
            # Preserve only normal rw/r bits; never setuid/setgid/sticky from package.
            os.chmod(target, member.mode & 0o777)
            files.append(str(rel))

    return {
        "file_count": len(files),
        "files": files,
        "skipped_special": skipped_special,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("deb", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("--manifest", type=Path)
    args = ap.parse_args()

    members = read_ar(args.deb)
    control_name, control_payload = find_member(members, "control.tar")
    data_name, data_payload = find_member(members, "data.tar")
    control = parse_control(decompress_tar(control_name, control_payload))
    staged = stage_data(decompress_tar(data_name, data_payload), args.dest)

    manifest = {
        "format": "lctv-tweak-stage-v1",
        "source": args.deb.name,
        "package": control.get("Package"),
        "version": control.get("Version"),
        "architecture": control.get("Architecture"),
        "depends": control.get("Depends"),
        "destination": str(args.dest),
        **staged,
    }
    manifest_path = args.manifest or (args.dest / "LCTVStageManifest.json")
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
