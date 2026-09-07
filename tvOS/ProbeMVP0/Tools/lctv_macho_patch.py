#!/usr/bin/env python3
"""Portable thin-arm64 Mach-O executable -> dylib patcher for LiveContainerTV.

This mirrors Tools/lctv_macho_patch.c without depending on Apple's Mach-O
headers, so it can run under Python 3 on Termux/Linux as well as macOS.
"""

import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_NO_REEXPORTED_DYLIBS = 0x00100000
MH_PIE = 0x00200000

LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_LOAD_DYLINKER = 0xE
LC_RPATH = 0x8000001C
LC_MAIN = 0x80000028

HEADER_SIZE = 32
SEGMENT64_SIZE = 72
DYLIB_COMMAND_SIZE = 24


class PatchError(RuntimeError):
    pass


def u32(data: bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def put_u32(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def put_u64(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<Q", data, offset, value)


def patch_rpath(data: bytearray, command_offset: int, cmdsize: int) -> bool:
    if cmdsize < 12:
        raise PatchError("invalid LC_RPATH command")
    path_offset = u32(data, command_offset + 8)
    if path_offset >= cmdsize:
        raise PatchError("invalid LC_RPATH string offset")
    start = command_offset + path_offset
    end_limit = command_offset + cmdsize
    nul = data.find(0, start, end_limit)
    if nul < 0:
        raise PatchError("unterminated LC_RPATH string")
    raw = bytes(data[start:nul])
    old = b"@executable_path"
    new = b"@loader_path"
    if not raw.startswith(old):
        return False
    replacement = new + raw[len(old):]
    capacity = end_limit - start
    if len(replacement) + 1 > capacity:
        raise PatchError("retargeted LC_RPATH does not fit existing command")
    data[start:end_limit] = replacement + b"\0" + b"\0" * (capacity - len(replacement) - 1)
    return True


def patch_bytes(data: bytearray) -> dict:
    if len(data) < HEADER_SIZE:
        raise PatchError("file is too small for mach_header_64")

    magic, cputype, _cpusubtype, filetype, ncmds, sizeofcmds, flags, _reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise PatchError("supports thin little-endian 64-bit Mach-O only")
    if cputype != CPU_TYPE_ARM64:
        raise PatchError("supports arm64 only")
    if filetype != MH_EXECUTE:
        raise PatchError("input is not MH_EXECUTE")
    if HEADER_SIZE + sizeofcmds > len(data):
        raise PatchError("load commands extend beyond file size")

    pagezero_offset = None
    dylinker_offset = None
    dylinker_size = None
    has_main = False
    rpaths_patched = 0

    cursor = HEADER_SIZE
    commands_end = HEADER_SIZE + sizeofcmds
    for _ in range(ncmds):
        if cursor + 8 > commands_end:
            raise PatchError("truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > commands_end:
            raise PatchError("invalid load command size")

        if cmd == LC_SEGMENT_64 and cmdsize >= SEGMENT64_SIZE:
            segname = bytes(data[cursor + 8:cursor + 24]).split(b"\0", 1)[0]
            if segname == b"__PAGEZERO":
                pagezero_offset = cursor
        elif cmd == LC_LOAD_DYLINKER:
            dylinker_offset = cursor
            dylinker_size = cmdsize
        elif cmd == LC_MAIN:
            has_main = True
        elif cmd == LC_RPATH:
            if patch_rpath(data, cursor, cmdsize):
                rpaths_patched += 1
        cursor += cmdsize

    if pagezero_offset is None:
        raise PatchError("__PAGEZERO segment not found")
    if dylinker_offset is None or dylinker_size is None:
        raise PatchError("LC_LOAD_DYLINKER not found")
    if not has_main:
        raise PatchError("LC_MAIN not found")
    if dylinker_size < DYLIB_COMMAND_SIZE + 2:
        raise PatchError("LC_LOAD_DYLINKER command is too small to reuse as LC_ID_DYLIB")

    # mach_header_64.filetype and flags.
    put_u32(data, 12, MH_DYLIB)
    put_u32(data, 24, (flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE)

    # segment_command_64: vmaddr @ +24, vmsize @ +32.
    put_u64(data, pagezero_offset + 24, 0x100000000 - 0x4000)
    put_u64(data, pagezero_offset + 32, 0x4000)

    # Reuse the existing LC_LOAD_DYLINKER bytes as LC_ID_DYLIB without changing
    # sizeofcmds/ncmds, exactly like the C prototype.
    start = dylinker_offset
    size = dylinker_size
    data[start:start + size] = b"\0" * size
    put_u32(data, start + 0, LC_ID_DYLIB)
    put_u32(data, start + 4, size)
    put_u32(data, start + 8, DYLIB_COMMAND_SIZE)  # dylib.name.offset
    put_u32(data, start + 12, 2)                  # timestamp
    put_u32(data, start + 16, 0x10000)            # current_version
    put_u32(data, start + 20, 0x10000)            # compatibility_version
    install_name = b"guest\0"
    if DYLIB_COMMAND_SIZE + len(install_name) > size:
        raise PatchError("reused command has insufficient room for install name")
    data[start + DYLIB_COMMAND_SIZE:start + DYLIB_COMMAND_SIZE + len(install_name)] = install_name

    return {
        "rpathsPatched": rpaths_patched,
        "pagezeroVmaddr": hex(0x100000000 - 0x4000),
        "pagezeroVmsize": hex(0x4000),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Portable LiveContainerTV Mach-O patcher")
    parser.add_argument("macho", help="thin arm64 MH_EXECUTE Mach-O to patch in place")
    args = parser.parse_args()

    path = Path(args.macho)
    try:
        data = bytearray(path.read_bytes())
        report = patch_bytes(data)
        path.write_bytes(data)
    except (OSError, PatchError, struct.error) as exc:
        print(f"lctv_macho_patch.py: {exc}", file=__import__("sys").stderr)
        return 1

    print(
        f"patched {path}: MH_EXECUTE -> MH_DYLIB, __PAGEZERO adjusted, "
        f"LC_ID_DYLIB installed, executable rpaths retargeted "
        f"(rpaths={report['rpathsPatched']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
