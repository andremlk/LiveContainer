#!/usr/bin/env python3
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def run(*args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def find_single_app(root: Path) -> Path:
    apps = sorted((root / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise SystemExit(f'expected exactly one Payload/*.app in {root}, found {len(apps)}')
    return apps[0]


def read_plist(app: Path):
    p = app / 'Info.plist'
    if not p.is_file():
        raise SystemExit(f'Info.plist missing: {p}')
    return plistlib.loads(p.read_bytes())


def write_plist(app: Path, info):
    (app / 'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))


def validate_bundle_id(bundle_id: str):
    if not bundle_id or '.' not in bundle_id or '/' in bundle_id or ':' in bundle_id:
        raise SystemExit(f'invalid outer bundle identifier: {bundle_id!r}')


def main():
    parser = argparse.ArgumentParser(
        description='Replace the LiveContainerTV host binary/template while preserving the installed outer bundle ID and imported guest catalog.'
    )
    parser.add_argument('current_ipa', help='current LiveContainerTV IPA that represents the installed chain/catalog')
    parser.add_argument('new_host_ipa', help='new unsigned LiveContainerTV host template IPA')
    parser.add_argument('output_ipa', help='output unsigned IPA to sign/install')
    parser.add_argument('--expected-bundle-id', help='refuse to build unless the current outer bundle ID matches this exact value')
    parser.add_argument('--tools-dir', default=str(Path(__file__).resolve().parent), help='directory containing lctv_registry_from_host.py and lctv_assemble_update.py')
    args = parser.parse_args()

    current_ipa = Path(args.current_ipa).resolve()
    new_host_ipa = Path(args.new_host_ipa).resolve()
    output_ipa = Path(args.output_ipa).resolve()
    tools = Path(args.tools_dir).resolve()

    for p in (current_ipa, new_host_ipa):
        if not p.is_file():
            raise SystemExit(f'IPA not found: {p}')

    registry_tool = tools / 'lctv_registry_from_host.py'
    assemble_tool = tools / 'lctv_assemble_update.py'
    if not registry_tool.is_file() or not assemble_tool.is_file():
        raise SystemExit(f'required tools missing in {tools}')

    with tempfile.TemporaryDirectory(prefix='lctv-rehost-') as td:
        td = Path(td)
        current_root = td / 'current'
        new_root = td / 'new'
        registry = td / 'registry'
        current_root.mkdir()
        new_root.mkdir()

        run('unzip', '-q', str(current_ipa), '-d', str(current_root))
        run('unzip', '-q', str(new_host_ipa), '-d', str(new_root))

        current_app = find_single_app(current_root)
        new_app = find_single_app(new_root)
        current_info = read_plist(current_app)
        new_info = read_plist(new_app)

        current_bundle_id = current_info.get('CFBundleIdentifier')
        validate_bundle_id(current_bundle_id)
        if args.expected_bundle_id and current_bundle_id != args.expected_bundle_id:
            raise SystemExit(
                f'outer bundle ID mismatch: current={current_bundle_id} expected={args.expected_bundle_id}'
            )

        old_host_id = new_info.get('CFBundleIdentifier')
        new_info['CFBundleIdentifier'] = current_bundle_id
        # Keep the installed app identity/name stable; take the executable/version from the new host template.
        for key in ('CFBundleName', 'CFBundleDisplayName'):
            if current_info.get(key):
                new_info[key] = current_info[key]
        write_plist(new_app, new_info)

        # Rewriting Info.plist invalidates any outer signature/provision embedded in a template.
        sig = new_app / '_CodeSignature'
        if sig.exists():
            shutil.rmtree(sig)
        provision = new_app / 'embedded.mobileprovision'
        if provision.exists():
            provision.unlink()

        current_catalog = current_app / 'LCTVImportCatalog.json'
        baseline = None
        if current_catalog.is_file():
            baseline = td / 'baseline-catalog.json'
            shutil.copy2(current_catalog, baseline)

        run('python3', str(registry_tool), str(current_app), str(registry))
        cmd = ['python3', str(assemble_tool), str(new_app), str(registry)]
        if baseline:
            cmd += ['--baseline-catalog', str(baseline)]
        run(*cmd)

        result_info = read_plist(new_app)
        if result_info.get('CFBundleIdentifier') != current_bundle_id:
            raise SystemExit('rehost invariant failed: outer bundle identifier changed')

        catalog = json.loads((new_app / 'LCTVImportCatalog.json').read_text()) if (new_app / 'LCTVImportCatalog.json').is_file() else {'format': 1, 'guests': []}
        update = json.loads((new_app / 'LCTVUpdateManifest.json').read_text()) if (new_app / 'LCTVUpdateManifest.json').is_file() else {}

        rehost_manifest = {
            'format': 1,
            'mode': 'host-replacement-preserve-catalog',
            'outerBundleIdentifier': current_bundle_id,
            'templateOriginalBundleIdentifier': old_host_id,
            'currentIPA_SHA256': sha256(current_ipa),
            'newHostTemplateIPA_SHA256': sha256(new_host_ipa),
            'guestCount': len(catalog.get('guests', [])),
            'guestBundleIDs': [g.get('bundleID') for g in catalog.get('guests', [])],
            'updateCounts': update.get('counts', {}),
            'signingRequired': True,
        }
        (new_app / 'LCTVRehostManifest.json').write_text(json.dumps(rehost_manifest, indent=2, sort_keys=True) + '\n')

        output_ipa.parent.mkdir(parents=True, exist_ok=True)
        if output_ipa.exists():
            output_ipa.unlink()
        run('zip', '-qry', str(output_ipa), 'Payload', cwd=new_root)

    print('LCTV REHOST UPDATE PASS')
    print(f'outerBundleIdentifier={current_bundle_id}')
    print(f'guestCount={rehost_manifest["guestCount"]}')
    print(f'output={output_ipa}')
    print(f'outputSHA256={sha256(output_ipa)}')
    print('signingRequired=YES')


if __name__ == '__main__':
    main()
