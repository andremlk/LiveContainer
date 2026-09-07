#!/usr/bin/env python3
import argparse
import json
import plistlib
import shutil
import stat
from pathlib import Path


def copy_optional(src: Path, dst: Path):
    if not src.exists():
        return
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)


def dir_size(path: Path) -> int:
    total = 0
    for item in path.rglob('*'):
        try:
            if item.is_file() and not item.is_symlink():
                total += item.stat().st_size
        except FileNotFoundError:
            pass
    return total


def main():
    parser = argparse.ArgumentParser(
        description='Split an LCTV-prepared tvOS app into a minimal signed code slot and a resource-only seed.'
    )
    parser.add_argument('prepared_dir')
    parser.add_argument('code_slot', help='destination .framework for signed executable code')
    parser.add_argument('resource_seed', help='destination directory used only as a writable resource seed')
    args = parser.parse_args()

    prepared = Path(args.prepared_dir)
    manifest_path = prepared / 'LCTVGuestManifest.json'
    if not manifest_path.is_file():
        raise SystemExit(f'missing {manifest_path}')

    manifest = json.loads(manifest_path.read_text())
    app_name = manifest.get('originalBundleName')
    executable = manifest.get('executable')
    if not app_name or not executable:
        raise SystemExit('manifest missing originalBundleName/executable')

    app = prepared / app_name
    if not app.is_dir():
        raise SystemExit(f'prepared app not found: {app}')

    original_info_path = app / 'Info.plist'
    info = plistlib.loads(original_info_path.read_bytes())
    bundle_id = info.get('CFBundleIdentifier') or 'unknown.guest'
    display_name = info.get('CFBundleDisplayName') or info.get('CFBundleName') or executable
    version = info.get('CFBundleShortVersionString') or ''
    build = info.get('CFBundleVersion') or ''

    code_slot = Path(args.code_slot)
    resource_seed = Path(args.resource_seed)
    for out in (code_slot, resource_seed):
        if out.exists():
            shutil.rmtree(out)

    # Resource seed: preserve the original app identity/resources, but intentionally remove executable code.
    shutil.copytree(app, resource_seed, symlinks=True)
    shutil.rmtree(resource_seed / '_CodeSignature', ignore_errors=True)
    shutil.rmtree(resource_seed / 'Frameworks', ignore_errors=True)
    shutil.rmtree(resource_seed / 'PlugIns', ignore_errors=True)
    for profile in ('embedded.mobileprovision', 'embedded.provisionprofile'):
        try:
            (resource_seed / profile).unlink()
        except FileNotFoundError:
            pass
    try:
        (resource_seed / executable).unlink()
    except FileNotFoundError:
        pass
    for dylib in resource_seed.glob('*.dylib'):
        dylib.unlink()

    resource_info_path = resource_seed / 'Info.plist'
    resource_info = plistlib.loads(resource_info_path.read_bytes())
    resource_info['LCTVResourceSeed'] = True
    resource_info['LCTVOriginalExecutable'] = executable
    resource_info['LCTVGuestBundleIdentifier'] = bundle_id
    resource_info_path.write_bytes(plistlib.dumps(resource_info, fmt=plistlib.FMT_XML, sort_keys=True))

    # Code slot: only what must remain executable/signed on tvOS.
    code_slot.mkdir(parents=True)
    shutil.copy2(app / executable, code_slot / executable, follow_symlinks=False)
    mode = (code_slot / executable).stat().st_mode
    (code_slot / executable).chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    copy_optional(app / 'Frameworks', code_slot / 'Frameworks')
    for dylib in app.glob('*.dylib'):
        shutil.copy2(dylib, code_slot / dylib.name, follow_symlinks=False)

    slot_info = {
        'CFBundleDevelopmentRegion': info.get('CFBundleDevelopmentRegion', 'en'),
        'CFBundleExecutable': executable,
        'CFBundleIdentifier': bundle_id,
        'CFBundleInfoDictionaryVersion': info.get('CFBundleInfoDictionaryVersion', '6.0'),
        'CFBundleName': f'{display_name} Code Slot',
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': version or '1.0',
        'CFBundleVersion': build or '1',
        'LCTVCodeSlot': True,
        'LCTVGuestBundleIdentifier': bundle_id,
        'LCTVGuestDisplayName': display_name,
        'LCTVGuestExecutable': executable,
        'LCTVGuestVersion': version,
        'LCTVGuestBuild': build,
        'LCTVResourceSeedName': resource_seed.name,
        'LCTVOriginalBundleName': app_name,
    }
    (code_slot / 'Info.plist').write_bytes(plistlib.dumps(slot_info, fmt=plistlib.FMT_XML, sort_keys=True))

    nested = list((code_slot / 'Frameworks').glob('*.framework')) if (code_slot / 'Frameworks').is_dir() else []
    seed_has_executable = (resource_seed / executable).exists()
    seed_has_frameworks = (resource_seed / 'Frameworks').exists()
    report = {
        'bundleID': bundle_id,
        'displayName': display_name,
        'executable': executable,
        'version': version,
        'build': build,
        'codeSlot': str(code_slot),
        'resourceSeed': str(resource_seed),
        'nestedFrameworks': len(nested),
        'resourceSeedHasExecutable': seed_has_executable,
        'resourceSeedHasFrameworks': seed_has_frameworks,
        'originalBytes': dir_size(app),
        'codeSlotBytes': dir_size(code_slot),
        'resourceSeedBytes': dir_size(resource_seed),
    }
    (code_slot / 'LCTVCodeSlotManifest.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')

    if seed_has_executable or seed_has_frameworks:
        raise SystemExit(f'resource-only invariant failed: {report}')
    if not (code_slot / executable).is_file():
        raise SystemExit('code-slot executable missing')

    print('MVP7F SPLIT PASS')
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
