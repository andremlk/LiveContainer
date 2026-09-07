#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_PIE = 0x00200000

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_RPATH = 0x8000001C
LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO_64 = 0x2C
LC_VERSION_MIN_TVOS = 0x2F
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028
PLATFORM_TVOS = 3

LOAD_DYLIB_COMMANDS = {
    LC_LOAD_DYLIB: "LC_LOAD_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
}


def version_string(value):
    return f"{(value >> 16) & 0xFFFF}.{(value >> 8) & 0xFF}.{value & 0xFF}"


def cstr(blob, offset):
    if offset < 0 or offset >= len(blob):
        return "<invalid>"
    end = blob.find(b"\0", offset)
    if end < 0:
        end = len(blob)
    return blob[offset:end].decode("utf-8", errors="replace")


def parse_macho(path):
    data = Path(path).read_bytes()
    if len(data) < 4:
        return {"supported": False, "reason": "file too small"}

    magic_le = struct.unpack_from("<I", data, 0)[0]
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        return {
            "supported": False,
            "fat": True,
            "reason": "fat/universal Mach-O is not supported by the current MVP patcher",
        }
    if magic_le != MH_MAGIC_64:
        return {"supported": False, "reason": f"unsupported Mach-O magic 0x{magic_le:08x}"}
    if len(data) < 32:
        return {"supported": False, "reason": "truncated mach_header_64"}

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    result = {
        "supported": True,
        "thin": True,
        "arm64": cputype == CPU_TYPE_ARM64,
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "filetype_name": {MH_EXECUTE: "MH_EXECUTE", MH_DYLIB: "MH_DYLIB"}.get(filetype, hex(filetype)),
        "flags": flags,
        "pie": bool(flags & MH_PIE),
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "lc_main": None,
        "platform": None,
        "minimum_os": None,
        "sdk": None,
        "dylibs": [],
        "rpaths": [],
        "segments": [],
        "pagezero": None,
        "has_code_signature": False,
        "encrypted": False,
        "cryptid": 0,
    }

    cursor = 32
    commands_end = cursor + sizeofcmds
    if commands_end > len(data):
        result["supported"] = False
        result["reason"] = "load commands extend beyond file"
        return result

    for _ in range(ncmds):
        if cursor + 8 > len(data):
            result["supported"] = False
            result["reason"] = "truncated load command"
            return result
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > len(data):
            result["supported"] = False
            result["reason"] = "invalid load command size"
            return result
        blob = data[cursor:cursor + cmdsize]

        if cmd == LC_SEGMENT_64 and cmdsize >= 72:
            segname = blob[8:24].split(b"\0", 1)[0].decode("ascii", errors="replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", blob, 24)
            maxprot, initprot, nsects, segflags = struct.unpack_from("<iiII", blob, 56)
            seg = {
                "name": segname,
                "vmaddr": vmaddr,
                "vmsize": vmsize,
                "fileoff": fileoff,
                "filesize": filesize,
                "maxprot": maxprot,
                "initprot": initprot,
                "nsects": nsects,
            }
            result["segments"].append(seg)
            if segname == "__PAGEZERO":
                result["pagezero"] = seg
        elif cmd == LC_MAIN and cmdsize >= 24:
            entryoff, stacksize = struct.unpack_from("<QQ", blob, 8)
            result["lc_main"] = {"entryoff": entryoff, "stacksize": stacksize}
        elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform, minos, sdk, ntools = struct.unpack_from("<IIII", blob, 8)
            result["platform"] = platform
            result["platform_name"] = "tvOS" if platform == PLATFORM_TVOS else f"platform-{platform}"
            result["minimum_os"] = version_string(minos)
            result["sdk"] = version_string(sdk)
        elif cmd == LC_VERSION_MIN_TVOS and cmdsize >= 16:
            version, sdk = struct.unpack_from("<II", blob, 8)
            result["platform"] = PLATFORM_TVOS
            result["platform_name"] = "tvOS"
            result["minimum_os"] = version_string(version)
            result["sdk"] = version_string(sdk)
        elif cmd in LOAD_DYLIB_COMMANDS and cmdsize >= 24:
            nameoff = struct.unpack_from("<I", blob, 8)[0]
            result["dylibs"].append({
                "command": LOAD_DYLIB_COMMANDS[cmd],
                "name": cstr(blob, nameoff),
            })
        elif cmd == LC_ID_DYLIB and cmdsize >= 24:
            nameoff = struct.unpack_from("<I", blob, 8)[0]
            result["id_dylib"] = cstr(blob, nameoff)
        elif cmd == LC_RPATH and cmdsize >= 12:
            pathoff = struct.unpack_from("<I", blob, 8)[0]
            result["rpaths"].append(cstr(blob, pathoff))
        elif cmd == LC_CODE_SIGNATURE:
            result["has_code_signature"] = True
        elif cmd == LC_ENCRYPTION_INFO_64 and cmdsize >= 24:
            cryptoff, cryptsize, cryptid, pad = struct.unpack_from("<IIII", blob, 8)
            result["cryptid"] = cryptid
            result["encrypted"] = cryptid != 0

        cursor += cmdsize

    return result


def extract_entitlements(app_path):
    codesign = shutil.which("codesign")
    if not codesign:
        return None
    try:
        proc = subprocess.run(
            [codesign, "-d", "--entitlements", ":-", str(app_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        payload = proc.stdout.strip()
        if not payload:
            payload = proc.stderr
            start = payload.find(b"<?xml")
            if start >= 0:
                payload = payload[start:]
        if not payload:
            return None
        start = payload.find(b"<?xml")
        if start >= 0:
            payload = payload[start:]
        return plistlib.loads(payload)
    except Exception:
        return None


def analyze_ipa(ipa_path):
    ipa_path = Path(ipa_path)
    report = {
        "ipa": str(ipa_path),
        "compatible_for_mvp5": False,
        "blockers": [],
        "warnings": [],
    }

    if not ipa_path.is_file():
        report["blockers"].append("IPA file does not exist")
        return report

    try:
        zf = zipfile.ZipFile(ipa_path)
    except Exception as exc:
        report["blockers"].append(f"invalid ZIP/IPA: {exc}")
        return report

    app_roots = sorted({
        name.split("/", 2)[1]
        for name in zf.namelist()
        if name.startswith("Payload/") and len(name.split("/")) >= 3 and name.split("/", 2)[1].endswith(".app")
    })
    if not app_roots:
        report["blockers"].append("no Payload/*.app bundle found")
        return report
    if len(app_roots) != 1:
        report["blockers"].append(f"expected one top-level app, found {len(app_roots)}: {app_roots}")
        return report

    app_name = app_roots[0]
    app_prefix = f"Payload/{app_name}/"
    info_name = app_prefix + "Info.plist"
    try:
        info = plistlib.loads(zf.read(info_name))
    except Exception as exc:
        report["blockers"].append(f"unable to read {info_name}: {exc}")
        return report

    executable = info.get("CFBundleExecutable")
    bundle_id = info.get("CFBundleIdentifier")
    report["app"] = {
        "bundle_name": app_name,
        "display_name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or app_name[:-4],
        "bundle_id": bundle_id,
        "executable": executable,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "minimum_os_plist": info.get("MinimumOSVersion"),
        "package_type": info.get("CFBundlePackageType"),
        "supported_platforms": info.get("CFBundleSupportedPlatforms"),
        "device_family": info.get("UIDeviceFamily"),
        "requires_iphone_os": info.get("LSRequiresIPhoneOS"),
        "required_capabilities": info.get("UIRequiredDeviceCapabilities"),
        "background_modes": info.get("UIBackgroundModes"),
        "has_scene_manifest": "UIApplicationSceneManifest" in info,
    }

    if not executable:
        report["blockers"].append("CFBundleExecutable is missing")
        return report

    exec_member = app_prefix + executable
    if exec_member not in zf.namelist():
        report["blockers"].append(f"main executable is missing from IPA: {exec_member}")
        return report

    with tempfile.TemporaryDirectory(prefix="lctv-ipa-") as td:
        exec_path = Path(td) / executable
        exec_path.write_bytes(zf.read(exec_member))
        macho = parse_macho(exec_path)
        report["macho"] = macho

        app_extract = Path(td) / app_name
        app_extract.mkdir()
        try:
            (app_extract / "Info.plist").write_bytes(zf.read(info_name))
            ent = extract_entitlements(app_extract)
            if ent:
                report["entitlements"] = ent
        except Exception:
            pass

    names = zf.namelist()
    frameworks = sorted({
        part
        for name in names
        if name.startswith(app_prefix + "Frameworks/")
        for part in [name[len(app_prefix + "Frameworks/"):].split("/", 1)[0]]
        if part.endswith(".framework")
    })
    dylib_files = sorted({
        name[len(app_prefix + "Frameworks/"):].split("/", 1)[0]
        for name in names
        if name.startswith(app_prefix + "Frameworks/") and name.endswith(".dylib")
    })
    appex = sorted({
        part
        for name in names
        if name.startswith(app_prefix + "PlugIns/")
        for part in [name[len(app_prefix + "PlugIns/"):].split("/", 1)[0]]
        if part.endswith(".appex")
    })
    report["embedded"] = {
        "frameworks": frameworks,
        "dylibs": dylib_files,
        "extensions": appex,
    }

    macho = report.get("macho", {})
    if not macho.get("supported"):
        report["blockers"].append(macho.get("reason", "unsupported Mach-O"))
    else:
        if not macho.get("arm64"):
            report["blockers"].append("main executable is not arm64")
        if macho.get("filetype") != MH_EXECUTE:
            report["blockers"].append(f"main executable is {macho.get('filetype_name')}, expected MH_EXECUTE")
        if not macho.get("lc_main"):
            report["blockers"].append("LC_MAIN is missing")
        if macho.get("platform") not in (None, PLATFORM_TVOS):
            report["blockers"].append(f"Mach-O platform is {macho.get('platform_name')}, not tvOS")
        if macho.get("encrypted"):
            report["blockers"].append("Mach-O is FairPlay-encrypted (cryptid != 0); decrypted IPA required")
        pagezero = macho.get("pagezero")
        if not pagezero:
            report["blockers"].append("__PAGEZERO segment is missing")

    if appex:
        report["warnings"].append(f"contains {len(appex)} app extension(s); MVP5C will initially ignore extensions")
    if frameworks:
        report["warnings"].append(f"contains {len(frameworks)} embedded framework(s); signing/rpath compatibility must be verified")
    if dylib_files:
        report["warnings"].append(f"contains {len(dylib_files)} embedded dylib(s)")
    if info.get("UIBackgroundModes"):
        report["warnings"].append("declares UIBackgroundModes")
    if info.get("UIRequiredDeviceCapabilities"):
        report["warnings"].append("declares UIRequiredDeviceCapabilities; hardware/service dependencies may apply")

    report["compatible_for_mvp5"] = not report["blockers"]
    return report


def print_human(report):
    print("=== LiveContainerTV MVP5 IPA analysis ===")
    print(f"IPA: {report.get('ipa')}")
    app = report.get("app") or {}
    if app:
        print(f"App: {app.get('display_name')} ({app.get('bundle_id')})")
        print(f"Executable: {app.get('executable')}")
        print(f"Version: {app.get('version')} ({app.get('build')})")
    macho = report.get("macho") or {}
    if macho:
        print(f"Mach-O: {macho.get('filetype_name')} arm64={macho.get('arm64')} PIE={macho.get('pie')}")
        if macho.get("lc_main"):
            print(f"LC_MAIN.entryoff: 0x{macho['lc_main']['entryoff']:x}")
        print(f"Platform/minOS/SDK: {macho.get('platform_name')} / {macho.get('minimum_os')} / {macho.get('sdk')}")
        print(f"Encrypted: {macho.get('encrypted')} (cryptid={macho.get('cryptid')})")
        print(f"RPATHs: {macho.get('rpaths')}")
        print(f"Dylib deps: {len(macho.get('dylibs', []))}")
    embedded = report.get("embedded") or {}
    if embedded:
        print(f"Embedded frameworks: {embedded.get('frameworks')}")
        print(f"Embedded dylibs: {embedded.get('dylibs')}")
        print(f"Extensions: {embedded.get('extensions')}")

    print("\nCompatibility:", "PASS" if report.get("compatible_for_mvp5") else "BLOCKED")
    for item in report.get("blockers", []):
        print("  BLOCKER:", item)
    for item in report.get("warnings", []):
        print("  WARN:", item)


def main():
    parser = argparse.ArgumentParser(description="Analyze a tvOS IPA for LiveContainerTV MVP5 compatibility")
    parser.add_argument("ipa")
    parser.add_argument("--json", action="store_true", help="emit JSON only")
    parser.add_argument("--json-out", help="write JSON report to this file")
    args = parser.parse_args()

    report = analyze_ipa(args.ipa)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(report, indent=2, sort_keys=True, default=str) + "\n")
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True, default=str))
    else:
        print_human(report)
    return 0 if report.get("compatible_for_mvp5") else 2


if __name__ == "__main__":
    sys.exit(main())
