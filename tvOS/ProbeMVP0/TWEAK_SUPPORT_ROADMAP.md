# LiveContainerTV tweak / Debian package roadmap

This branch is intentionally isolated from the current MVP7J/MVP7K/MVP8 runtime work.
Nothing here changes the host that is currently being tested on Apple TV.

## Goal

Support app-scoped tweaks for LiveContainerTV guests with these input formats:

- `.dylib`
- `.framework`
- `.deb`
- resource `.bundle` directories contained by a tweak package

The `.deb` format is treated as a **package/container**, not as a request to install
Debian software into tvOS. LiveContainerTV should inspect the package, copy only the
relevant tweak payload into its own container, patch/sign compatible Mach-O files,
and load them through the guest tweak loader.

## Why this fits LiveContainer

Upstream LiveContainer already contains a `TweakLoader` that loads tweak dylibs and
frameworks and uses CydiaSubstrate. The SwiftUI tweak manager also contains a
commented `.deb` file type and an unfinished `// handle deb file` path. The tvOS port
therefore needs to finish and adapt an existing architectural direction rather than
invent a separate package system.

## Non-negotiable safety / compatibility rules

1. Never run package maintainer scripts (`preinst`, `postinst`, `prerm`, `postrm`).
2. Never extract absolute paths or `..` traversal paths from an untrusted package.
3. Never write outside the LiveContainerTV app/container-controlled tweak directory.
4. Reject unsupported CPU architectures before launch.
5. Distinguish iOS-only Mach-O from tvOS Mach-O before attempting `dlopen`.
6. Preserve per-app tweak selection; no global injection unless explicitly selected.
7. Sign/prepare every executable object before guest launch.
8. Keep the tweak pipeline isolated from the currently stable guest-import pipeline.

## Staged implementation

### PREP-0 — package analyzer (now)

`Tools/lctv_deb_analyze.py`

Read-only analyzer for:

- Debian `ar` container structure
- `control.tar.*` metadata
- `data.tar.*` payload inventory
- MobileSubstrate filter plist (`Bundles`, `Executables`, `Classes`)
- dylib/framework/bundle discovery
- arm64 / arm64e detection
- `LC_BUILD_VERSION` / iOS vs tvOS classification
- linked dylib inventory
- unsafe payload path detection

No runtime change.

### TWEAK-1 — native tvOS dylib probe

Build a trivial tvOS arm64 dylib under our control. Inject/load it into a known-good
TinyGuest/UIKitGuest and verify a persistent marker such as:

`TWEAK_CONSTRUCTOR -> DLOPEN_OK -> GUEST_MAIN`

This proves the loader path independently from third-party tweak assumptions.

### TWEAK-2 — synthetic Debian package

Package the TWEAK-1 dylib with:

- `Library/MobileSubstrate/DynamicLibraries/LCTVTest.dylib`
- `Library/MobileSubstrate/DynamicLibraries/LCTVTest.plist`
- a small resource bundle

Then validate the complete path:

`DEB_IMPORT -> CONTROL_PARSE -> FILTER_MATCH -> PAYLOAD_STAGE -> SIGN -> LOAD`

### TWEAK-3 — app-scoped manager

Add guest configuration fields:

- tweak folder / selected packages
- enable/disable state
- compatibility report
- last load result / error

The host resolves filters against the selected guest bundle ID/executable and only
loads matching tweaks.

### TWEAK-4 — dependency preparation

Handle common tweak dependencies and Mach-O path repair:

- CydiaSubstrate / substrate compatibility layer
- `@rpath`
- `@loader_path`
- embedded frameworks
- resource bundles

Do not blindly rewrite arbitrary system framework dependencies.

### TWEAK-5 — real third-party compatibility

Only after TWEAK-1..4 are stable, test real third-party tweaks. A useful candidate is
InfusePlus because its official build workflow already injects a `.deb` into a
decrypted Infuse IPA with `cyan`/pyzule.

InfusePlus must still be classified separately because its current release artifacts
are iPhoneOS packages. arm64 alone does not guarantee tvOS compatibility.

## Proposed UI later

Per guest:

- Tweaks
  - Import `.dylib`
  - Import `.framework`
  - Import `.deb`
- Compatibility
  - Architecture
  - Platform
  - Filter target
  - Dependencies
  - Resources
- Enable / Disable
- Last load result

Example compatibility result:

```
InfusePlus
Package: com.dvntm.infuseplus
Architecture: arm64                 OK
MobileSubstrate filter: detected    OK
Target: com.firecore.infuse         OK
Resource bundles: detected          OK
Mach-O platform: iOS                WARNING
LiveContainerTV status: EXPERIMENTAL
```

## Relationship to MVP7J / MVP7K / MVP8

Do **not** merge this feature into the test host before the current executable-memory
and guest-entry probes are resolved.

Recommended gate:

1. MVP7J/7K proves the required execution policy.
2. MVP8 proves a stable guest entry path.
3. Freeze that host as a known-good runtime baseline.
4. Start TWEAK-1 on a separate branch from that baseline.
5. Merge tweak support only after the trivial controlled dylib works.

This keeps a tweak failure from being mistaken for a guest-runtime failure.
