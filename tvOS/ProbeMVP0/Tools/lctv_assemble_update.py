#!/usr/bin/env python3
import argparse
import json
import plistlib
import shutil
from pathlib import Path

FORMAT_VERSION = 1


def load_json(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")


def bundle_info(path: Path):
    info_path = path / "Info.plist"
    if not info_path.is_file():
        return {}
    return plistlib.loads(info_path.read_bytes())


def remove_old_imported(host: Path):
    frameworks = host / "Frameworks"
    seeds = host / "GuestSeeds"
    if frameworks.is_dir():
        for item in frameworks.glob("*.framework"):
            info = bundle_info(item)
            if info.get("LCTVCodeSlot"):
                shutil.rmtree(item)
    if seeds.is_dir():
        for item in seeds.iterdir():
            if not item.is_dir():
                continue
            info = bundle_info(item)
            if info.get("LCTVResourceSeed"):
                shutil.rmtree(item)


def guest_map(catalog):
    return {g["bundleID"]: g for g in catalog.get("guests", [])}


def diff_catalogs(baseline, current):
    before = guest_map(baseline)
    after = guest_map(current)
    added = []
    preserved = []
    updated = []
    removed = []

    for bundle_id, guest in sorted(after.items()):
        old = before.get(bundle_id)
        if old is None:
            added.append(bundle_id)
        elif old.get("fingerprint") == guest.get("fingerprint"):
            preserved.append(bundle_id)
        else:
            updated.append(bundle_id)
    for bundle_id in sorted(set(before) - set(after)):
        removed.append(bundle_id)
    return added, preserved, updated, removed


def validate_pair(registry: Path, guest: dict):
    slot = registry / guest["codeSlot"]
    seed = registry / guest["resourceSeed"]
    if not slot.is_dir() or not seed.is_dir():
        raise SystemExit(f"missing slot/seed for {guest['bundleID']}")
    slot_info = bundle_info(slot)
    seed_info = bundle_info(seed)
    if not slot_info.get("LCTVCodeSlot"):
        raise SystemExit(f"slot marker missing: {slot}")
    if not seed_info.get("LCTVResourceSeed"):
        raise SystemExit(f"seed marker missing: {seed}")
    fp = guest.get("fingerprint") or ""
    if fp and (slot_info.get("LCTVImportFingerprint") != fp or seed_info.get("LCTVImportFingerprint") != fp):
        raise SystemExit(f"fingerprint mismatch for {guest['bundleID']}")
    executable = guest.get("executable")
    if not executable or not (slot / executable).is_file():
        raise SystemExit(f"code-slot executable missing for {guest['bundleID']}")
    if (seed / executable).exists() or (seed / "Frameworks").exists() or list(seed.glob("*.dylib")):
        raise SystemExit(f"resource seed contains executable code for {guest['bundleID']}")
    return slot, seed


def main():
    parser = argparse.ArgumentParser(
        description="Assemble a LiveContainerTV host update from a persistent generic import registry."
    )
    parser.add_argument("host_app", help="built LiveContainerTV.app to populate")
    parser.add_argument("registry", help="persistent lctv_import_guest.py output root")
    parser.add_argument("--baseline-catalog", help="previous installed/import catalog used to compute update delta")
    args = parser.parse_args()

    host = Path(args.host_app).resolve()
    registry = Path(args.registry).resolve()
    if not host.is_dir():
        raise SystemExit(f"host app not found: {host}")
    catalog_path = registry / "LCTVImportCatalog.json"
    if not catalog_path.is_file():
        raise SystemExit(f"registry catalog missing: {catalog_path}")

    current = load_json(catalog_path)
    if current.get("format") != 1:
        raise SystemExit(f"unsupported registry format: {current.get('format')}")
    baseline = load_json(Path(args.baseline_catalog)) if args.baseline_catalog else {"format": 1, "guests": []}

    remove_old_imported(host)
    frameworks = host / "Frameworks"
    seeds = host / "GuestSeeds"
    frameworks.mkdir(parents=True, exist_ok=True)
    seeds.mkdir(parents=True, exist_ok=True)

    staged = []
    for guest in current.get("guests", []):
        slot, seed = validate_pair(registry, guest)
        dst_slot = frameworks / slot.name
        dst_seed = seeds / seed.name
        if dst_slot.exists():
            shutil.rmtree(dst_slot)
        if dst_seed.exists():
            shutil.rmtree(dst_seed)
        shutil.copytree(slot, dst_slot, symlinks=True)
        shutil.copytree(seed, dst_seed, symlinks=True)
        staged.append(guest["bundleID"])

    shutil.copy2(catalog_path, host / "LCTVImportCatalog.json")
    added, preserved, updated, removed = diff_catalogs(baseline, current)
    manifest = {
        "format": FORMAT_VERSION,
        "mode": "incremental-container-update",
        "guestCount": len(current.get("guests", [])),
        "added": added,
        "preserved": preserved,
        "updated": updated,
        "removed": removed,
        "counts": {
            "added": len(added),
            "preserved": len(preserved),
            "updated": len(updated),
            "removed": len(removed),
        },
        "guestDataPolicy": "stable-by-bundle-id",
        "guestDataRoot": "Library/Caches/LiveContainerTV/Guests/<bundle-id>/Data",
        "writableResourceRoot": "Library/Caches/LiveContainerTV/ImportLibrary",
        "stagedBundleIDs": staged,
    }
    write_json(host / "LCTVUpdateManifest.json", manifest)

    print("MVP7H UPDATE ASSEMBLY PASS")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
