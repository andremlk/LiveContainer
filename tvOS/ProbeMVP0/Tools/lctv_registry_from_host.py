#!/usr/bin/env python3
import argparse
import json
import plistlib
import shutil
from pathlib import Path


def load_json(path: Path):
    return json.loads(path.read_text())


def bundle_info(path: Path):
    info_path = path / "Info.plist"
    if not info_path.is_file():
        return {}
    return plistlib.loads(info_path.read_bytes())


def validate_host_pair(host: Path, guest: dict):
    slot_name = Path(guest["codeSlot"]).name
    seed_name = Path(guest["resourceSeed"]).name
    slot = host / "Frameworks" / slot_name
    seed = host / "GuestSeeds" / seed_name
    if not slot.is_dir() or not seed.is_dir():
        raise SystemExit(f"host is missing slot/seed for {guest['bundleID']}: {slot_name}, {seed_name}")

    slot_info = bundle_info(slot)
    seed_info = bundle_info(seed)
    if not slot_info.get("LCTVCodeSlot"):
        raise SystemExit(f"host code slot marker missing: {slot}")
    if not seed_info.get("LCTVResourceSeed"):
        raise SystemExit(f"host resource seed marker missing: {seed}")

    fingerprint = guest.get("fingerprint") or ""
    if fingerprint:
        if slot_info.get("LCTVImportFingerprint") != fingerprint:
            raise SystemExit(f"host slot fingerprint mismatch for {guest['bundleID']}")
        if seed_info.get("LCTVImportFingerprint") != fingerprint:
            raise SystemExit(f"host seed fingerprint mismatch for {guest['bundleID']}")

    executable = guest.get("executable")
    if not executable or not (slot / executable).is_file():
        raise SystemExit(f"host slot executable missing for {guest['bundleID']}")
    if (seed / executable).exists() or (seed / "Frameworks").exists() or list(seed.glob("*.dylib")):
        raise SystemExit(f"host resource seed contains executable code for {guest['bundleID']}")
    return slot, seed


def main():
    parser = argparse.ArgumentParser(
        description="Recreate an lctv_import_guest.py registry from an existing LiveContainerTV.app."
    )
    parser.add_argument("host_app", help="existing LiveContainerTV.app extracted from the current base IPA")
    parser.add_argument("registry", help="destination registry directory")
    args = parser.parse_args()

    host = Path(args.host_app).resolve()
    registry = Path(args.registry).resolve()
    if not host.is_dir():
        raise SystemExit(f"host app not found: {host}")

    catalog_path = host / "LCTVImportCatalog.json"
    if not catalog_path.is_file():
        # A host without an import catalog is a valid empty starting point.
        catalog = {"format": 1, "guests": []}
    else:
        catalog = load_json(catalog_path)
        if catalog.get("format") != 1:
            raise SystemExit(f"unsupported host catalog format: {catalog.get('format')}")

    if registry.exists():
        shutil.rmtree(registry)
    (registry / "CodeSlots").mkdir(parents=True)
    (registry / "ResourceSeeds").mkdir(parents=True)
    (registry / "Manifests").mkdir(parents=True)
    (registry / "Analysis").mkdir(parents=True)

    copied = []
    normalized_guests = []
    for guest in catalog.get("guests", []):
        slot, seed = validate_host_pair(host, guest)
        dst_slot = registry / "CodeSlots" / slot.name
        dst_seed = registry / "ResourceSeeds" / seed.name
        shutil.copytree(slot, dst_slot, symlinks=True)
        shutil.copytree(seed, dst_seed, symlinks=True)

        record = dict(guest)
        record["codeSlot"] = str(Path("CodeSlots") / slot.name)
        record["resourceSeed"] = str(Path("ResourceSeeds") / seed.name)
        normalized_guests.append(record)
        copied.append(guest["bundleID"])

    normalized = {"format": 1, "guests": sorted(normalized_guests, key=lambda x: (x.get("displayName") or "").casefold())}
    (registry / "LCTVImportCatalog.json").write_text(json.dumps(normalized, indent=2, sort_keys=True) + "\n")

    host_info = bundle_info(host)
    source = {
        "format": 1,
        "hostBundleIdentifier": host_info.get("CFBundleIdentifier"),
        "hostVersion": host_info.get("CFBundleShortVersionString"),
        "hostBuild": host_info.get("CFBundleVersion"),
        "guestCount": len(copied),
        "bundleIDs": copied,
    }
    (registry / "LCTVRegistrySource.json").write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")

    print(f"MVP7I REGISTRY BOOTSTRAP PASS: {len(copied)} existing guest(s) preserved")
    for bundle_id in copied:
        print(f"  preserve {bundle_id}")


if __name__ == "__main__":
    main()
