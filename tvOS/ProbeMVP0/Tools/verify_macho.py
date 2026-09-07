#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 0x6
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_MAIN = 0x80000028


def u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def u64(data: bytes, off: int) -> int:
    return struct.unpack_from("<Q", data, off)[0]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <patched-macho>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = path.read_bytes()
    if len(data) < 32:
        raise SystemExit("Mach-O too small")

    magic, _, _, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"unexpected magic 0x{magic:08x}")
    if filetype != MH_DYLIB:
        raise SystemExit(f"expected MH_DYLIB (6), got {filetype}")
    if 32 + sizeofcmds > len(data):
        raise SystemExit("load commands exceed file size")

    pagezero = None
    has_id_dylib = False
    main_entryoff = None
    off = 32
    for _ in range(ncmds):
        cmd = u32(data, off)
        cmdsize = u32(data, off + 4)
        if cmdsize < 8 or off + cmdsize > len(data):
            raise SystemExit("invalid load command size")

        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            segname = data[off + 8 : off + 24].split(b"\0", 1)[0]
            if segname == b"__PAGEZERO":
                pagezero = (u64(data, off + 24), u64(data, off + 32))
        elif cmd == LC_ID_DYLIB:
            has_id_dylib = True
        elif cmd == LC_MAIN:
            if cmdsize < 24:
                raise SystemExit("LC_MAIN smaller than entry_point_command")
            main_entryoff = u64(data, off + 8)
        off += cmdsize

    expected_pagezero = (0x100000000 - 0x4000, 0x4000)
    if pagezero != expected_pagezero:
        raise SystemExit(f"unexpected __PAGEZERO {pagezero!r}, expected {expected_pagezero!r}")
    if not has_id_dylib:
        raise SystemExit("LC_ID_DYLIB missing")
    if main_entryoff is None:
        raise SystemExit("LC_MAIN missing")
    if main_entryoff == 0 or main_entryoff >= len(data):
        raise SystemExit(f"LC_MAIN entryoff looks invalid: 0x{main_entryoff:x}")

    print(
        "PASS: patched Mach-O is MH_DYLIB, has adjusted __PAGEZERO, LC_ID_DYLIB, and preserved LC_MAIN"
    )
    print(
        f"flags=0x{flags:08x}, ncmds={ncmds}, sizeofcmds={sizeofcmds}, "
        f"LC_MAIN.entryoff=0x{main_entryoff:x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
