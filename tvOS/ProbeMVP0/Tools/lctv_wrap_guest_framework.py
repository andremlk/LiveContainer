#!/usr/bin/env python3
import argparse
import json
import plistlib
import shutil
import stat
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Wrap an MVP5-prepared tvOS .app as an embedded framework-style guest bundle")
    parser.add_argument("prepared_dir", help="output directory from lctv_prepare_ipa.sh")
    parser.add_argument("output_framework", help="destination ending in .framework")
    parser.add_argument("--keep-extensions", action="store_true", help="keep PlugIns/*.appex instead of stripping them for the MVP5C path")
    args = parser.parse_args()

    prepared = Path(args.prepared_dir)
    out = Path(args.output_framework)
    manifest_path = prepared / "LCTVGuestManifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"missing {manifest_path}")

    manifest = json.loads(manifest_path.read_text())
    app_name = manifest.get("originalBundleName")
    executable = manifest.get("executable")
    if not app_name or not executable:
        raise SystemExit("manifest is missing originalBundleName/executable")

    app = prepared / app_name
    if not app.is_dir():
        raise SystemExit(f"prepared app not found: {app}")

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(app, out, symlinks=True)

    info_path = out / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    original_package_type = info.get("CFBundlePackageType")
    info["LCTVOriginalCFBundlePackageType"] = original_package_type or ""
    info["LCTVOriginalBundleName"] = app_name
    info["LCTVPreparedGuest"] = True
    info["CFBundlePackageType"] = "FMWK"
    info["CFBundleExecutable"] = executable
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))

    if not args.keep_extensions:
        shutil.rmtree(out / "PlugIns", ignore_errors=True)

    exe_path = out / executable
    if not exe_path.is_file():
        raise SystemExit(f"framework executable missing: {exe_path}")
    mode = exe_path.stat().st_mode
    exe_path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    wrapped_manifest = dict(manifest)
    wrapped_manifest.update({
        "frameworkBundleName": out.name,
        "frameworkExecutableRelativePath": f"{out.name}/{executable}",
        "extensionsStripped": not args.keep_extensions,
        "originalPackageType": original_package_type,
    })
    (out / "LCTVGuestManifest.json").write_text(json.dumps(wrapped_manifest, indent=2, sort_keys=True) + "\n")

    print(f"MVP5B WRAP PASS: {app.name} -> {out.name}")
    print(f"bundleID={info.get('CFBundleIdentifier')}")
    print(f"executable={executable}")
    print(f"packageType={info.get('CFBundlePackageType')}")
    print(f"extensionsStripped={not args.keep_extensions}")


if __name__ == "__main__":
    main()
