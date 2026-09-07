#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <input.ipa> <output-dir>" >&2
  exit 2
fi

IPA="$1"
OUT="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHER="${LCTV_PATCHER:-$ROOT/build-tools/lctv_macho_patch}"
ANALYZER="$SCRIPT_DIR/lctv_ipa_analyze.py"
VERIFY="$SCRIPT_DIR/verify_macho.py"

if [ ! -f "$IPA" ]; then
  echo "input IPA not found: $IPA" >&2
  exit 1
fi
if [ ! -x "$PATCHER" ]; then
  echo "Mach-O patcher not executable: $PATCHER" >&2
  echo "build it first or set LCTV_PATCHER=/path/to/lctv_macho_patch" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lctv-mvp5.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

python3 "$ANALYZER" "$IPA" --json-out "$OUT/analysis.json"
python3 "$ANALYZER" "$IPA" > "$OUT/analysis.txt"

python3 - "$IPA" "$TMP" "$OUT" <<'PY'
import json
import os
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
tmp = Path(sys.argv[2])
out = Path(sys.argv[3])
report = json.loads((out / "analysis.json").read_text())
if not report.get("compatible_for_mvp5"):
    raise SystemExit("IPA is blocked by MVP5 analyzer; see analysis.txt")

with zipfile.ZipFile(ipa) as zf:
    zf.extractall(tmp)

payload = tmp / "Payload"
apps = sorted(payload.glob("*.app"))
if len(apps) != 1:
    raise SystemExit(f"expected exactly one Payload/*.app, found {len(apps)}")
source = apps[0]
dest = out / source.name
shutil.copytree(source, dest, symlinks=True)

info_path = dest / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
exe_name = info.get("CFBundleExecutable")
if not exe_name:
    raise SystemExit("CFBundleExecutable missing after extraction")

# Existing signatures/profiles are invalid after the executable transformation and
# will be recreated by the outer signing flow later.
shutil.rmtree(dest / "_CodeSignature", ignore_errors=True)
for profile in (dest / "embedded.mobileprovision", dest / "embedded.provisionprofile"):
    try:
        profile.unlink()
    except FileNotFoundError:
        pass

manifest = {
    "format": 1,
    "originalBundleName": source.name,
    "bundleIdentifier": info.get("CFBundleIdentifier"),
    "displayName": info.get("CFBundleDisplayName") or info.get("CFBundleName") or source.stem,
    "executable": exe_name,
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "minimumOSVersion": info.get("MinimumOSVersion"),
    "preparedExecutableRelativePath": f"{source.name}/{exe_name}",
}
(out / "LCTVGuestManifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print(dest / exe_name)
PY

EXEC_PATH="$(python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
m = json.loads((out / "LCTVGuestManifest.json").read_text())
print(out / m["preparedExecutableRelativePath"])
PY
)"

cp "$EXEC_PATH" "$OUT/original-executable"
chmod +x "$EXEC_PATH"
"$PATCHER" "$EXEC_PATH" | tee "$OUT/patch.log"
python3 "$VERIFY" "$EXEC_PATH" | tee "$OUT/verify.log"

echo "--- prepared guest ---" | tee "$OUT/summary.txt"
echo "IPA=$IPA" | tee -a "$OUT/summary.txt"
echo "APP=$(dirname "$EXEC_PATH")" | tee -a "$OUT/summary.txt"
echo "EXEC=$EXEC_PATH" | tee -a "$OUT/summary.txt"
shasum -a 256 "$EXEC_PATH" | tee -a "$OUT/summary.txt"

echo "MVP5B PASS: IPA analyzed, extracted, de-profiled, patched MH_EXECUTE -> MH_DYLIB, and verified"
