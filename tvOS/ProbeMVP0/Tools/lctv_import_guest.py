#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

FORMAT_VERSION = 1
TRANSFORM_VERSION = 2


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def safe_slug(value: str) -> str:
    value = re.sub(r'[^A-Za-z0-9._-]+', '-', value.strip())
    value = value.strip('.-_')
    return value or 'guest'


def run(cmd, *, cwd=None, env=None):
    print('+', ' '.join(map(str, cmd)), flush=True)
    subprocess.run([str(x) for x in cmd], cwd=cwd, env=env, check=True)


def load_json(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + '\n')


def update_catalog(catalog_path: Path, record: dict):
    if catalog_path.is_file():
        catalog = load_json(catalog_path)
    else:
        catalog = {'format': FORMAT_VERSION, 'guests': []}
    guests = [g for g in catalog.get('guests', []) if g.get('bundleID') != record['bundleID']]
    guests.append(record)
    guests.sort(key=lambda x: (x.get('displayName') or '').casefold())
    catalog['format'] = FORMAT_VERSION
    catalog['guests'] = guests
    write_json(catalog_path, catalog)


def main():
    parser = argparse.ArgumentParser(
        description='Import a compatible tvOS IPA into LiveContainerTV minimal signed-code + writable-resource format.'
    )
    parser.add_argument('ipa', help='input tvOS .ipa')
    parser.add_argument('output_root', help='import workspace root')
    parser.add_argument('--slot-name', help='override generated code-slot framework basename')
    parser.add_argument('--seed-name', help='override generated resource-seed basename')
    parser.add_argument('--patcher', help='path to lctv_macho_patch (defaults to LCTV_PATCHER or build-tools/lctv_macho_patch)')
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    root = here.parent
    ipa = Path(args.ipa).resolve()
    out = Path(args.output_root).resolve()
    if not ipa.is_file():
        raise SystemExit(f'input IPA not found: {ipa}')

    analyzer = here / 'lctv_ipa_analyze.py'
    prepare = here / 'lctv_prepare_ipa.sh'
    splitter = here / 'lctv_split_guest.py'
    patcher = Path(args.patcher or os.environ.get('LCTV_PATCHER') or (root / 'build-tools/lctv_macho_patch')).resolve()
    if not patcher.is_file():
        raise SystemExit(f'Mach-O patcher not found: {patcher}')

    out.mkdir(parents=True, exist_ok=True)
    analysis_dir = out / 'Analysis'
    analysis_dir.mkdir(parents=True, exist_ok=True)
    pre_analysis = analysis_dir / '_incoming.json'
    run([sys.executable, analyzer, ipa, '--json-out', pre_analysis])
    report = load_json(pre_analysis)
    if not report.get('compatible_for_mvp5'):
        raise SystemExit(f'IPA is not compatible: blockers={report.get("blockers", [])}')

    app = report['app']
    macho = report['macho']
    bundle_id = app.get('bundle_id') or 'unknown.guest'
    display_name = app.get('display_name') or app.get('bundle_name') or bundle_id
    executable = app.get('executable')
    version = app.get('version') or ''
    build = app.get('build') or ''
    if not executable:
        raise SystemExit('analyzer did not report an executable')

    slug = safe_slug(bundle_id)
    slot_base = safe_slug(args.slot_name or f'{slug}.code')
    seed_base = safe_slug(args.seed_name or f'{slug}.resources')
    slot_name = slot_base if slot_base.endswith('.framework') else f'{slot_base}.framework'
    seed_name = seed_base if seed_base.endswith('.lctvseed') else f'{seed_base}.lctvseed'

    prepared = out / 'Prepared' / slug
    code_slot = out / 'CodeSlots' / slot_name
    resource_seed = out / 'ResourceSeeds' / seed_name
    analysis_json = analysis_dir / f'{slug}.json'
    if pre_analysis != analysis_json:
        shutil.move(pre_analysis, analysis_json)

    env = dict(os.environ)
    env['LCTV_PATCHER'] = str(patcher)
    run(['bash', prepare, ipa, prepared], env=env)
    code_slot.parent.mkdir(parents=True, exist_ok=True)
    resource_seed.parent.mkdir(parents=True, exist_ok=True)
    run([sys.executable, splitter, prepared, code_slot, resource_seed])

    source_sha256 = sha256_file(ipa)
    fingerprint_input = json.dumps({
        'transformVersion': TRANSFORM_VERSION,
        'sourceSHA256': source_sha256,
        'bundleID': bundle_id,
        'version': version,
        'build': build,
        'executable': executable,
    }, sort_keys=True).encode()
    fingerprint = hashlib.sha256(fingerprint_input).hexdigest()

    slot_info_path = code_slot / 'Info.plist'
    seed_info_path = resource_seed / 'Info.plist'
    slot_info = plistlib.loads(slot_info_path.read_bytes())
    seed_info = plistlib.loads(seed_info_path.read_bytes())
    for info in (slot_info, seed_info):
        info['LCTVImporterFormat'] = FORMAT_VERSION
        info['LCTVImportTransformVersion'] = TRANSFORM_VERSION
        info['LCTVImportFingerprint'] = fingerprint
        info['LCTVImportSourceSHA256'] = source_sha256
    slot_info['LCTVResourceSeedName'] = seed_name
    seed_info['LCTVCodeSlotName'] = slot_name
    slot_info_path.write_bytes(plistlib.dumps(slot_info, fmt=plistlib.FMT_XML, sort_keys=True))
    seed_info_path.write_bytes(plistlib.dumps(seed_info, fmt=plistlib.FMT_XML, sort_keys=True))

    frameworks_dir = code_slot / 'Frameworks'
    nested_frameworks = len(list(frameworks_dir.glob('*.framework'))) if frameworks_dir.is_dir() else 0
    top_level_dylibs = len(list(code_slot.glob('*.dylib')))
    if (resource_seed / executable).exists() or (resource_seed / 'Frameworks').exists():
        raise SystemExit('resource-only invariant failed after import')
    if not (code_slot / executable).is_file():
        raise SystemExit('signed code slot executable missing after import')

    record = {
        'format': FORMAT_VERSION,
        'transformVersion': TRANSFORM_VERSION,
        'bundleID': bundle_id,
        'displayName': display_name,
        'executable': executable,
        'version': version,
        'build': build,
        'sourceIPA': ipa.name,
        'sourceSHA256': source_sha256,
        'fingerprint': fingerprint,
        'platform': macho.get('platform_name'),
        'minimumOS': macho.get('minimum_os'),
        'encrypted': bool(macho.get('encrypted')),
        'codeSlot': str(code_slot.relative_to(out)),
        'resourceSeed': str(resource_seed.relative_to(out)),
        'nestedFrameworks': nested_frameworks,
        'topLevelDylibs': top_level_dylibs,
    }
    manifest_path = out / 'Manifests' / f'{slug}.json'
    write_json(manifest_path, record)
    update_catalog(out / 'LCTVImportCatalog.json', record)

    print('MVP7G IMPORT PASS')
    print(json.dumps(record, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
