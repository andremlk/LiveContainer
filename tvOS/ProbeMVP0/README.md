# LiveContainerTV

Experimental tvOS port/probe derived from the architecture of [LiveContainer](https://github.com/LiveContainer/LiveContainer).

## Current status

The prototype now has four progressively stronger validation stages. CI validates the binary transformations; Apple TV hardware is still required to validate runtime behavior.

### MVP 0 — normal tvOS dynamic payload

Build a native tvOS host, embed an ARM64 tvOS framework, load it with `dlopen()`, resolve an exported symbol with `dlsym()`, and execute it.

Expected device result:

`PASS: tvOS guest payload executed through dlopen + dlsym`

### MVP 1 — patch a real tvOS application executable

CI builds a real `TinyGuestTV.app`, then applies the minimum LiveContainer-style Mach-O transformation:

- `MH_EXECUTE` -> `MH_DYLIB`
- remove `MH_PIE`
- add `MH_NO_REEXPORTED_DYLIBS`
- patch `__PAGEZERO` to `vmaddr=0xffffc000`, `vmsize=0x4000`
- reuse `LC_LOAD_DYLINKER` as `LC_ID_DYLIB`
- preserve `LC_MAIN`

CI independently confirms that the patched image remains a valid ARM64 tvOS Mach-O and preserves its original entry point.

### MVP 2A — hardware-load the patched executable

The patched `TinyGuestTV` binary is packaged as `Frameworks/TinyGuestTV.framework/TinyGuestTV` before final signing. The host calls `dlopen()` and then resolves/calls `LCTVGuestMarker`.

Expected device result:

`PASS MVP2A: patched MH_EXECUTE loaded as MH_DYLIB (TinyGuestTV/tvOS)`

### MVP 2B — invoke the preserved `LC_MAIN`

After loading TinyGuestTV, the host uses a guest marker plus `dladdr()` to get the real in-memory image base, walks the Mach-O load commands, reads `LC_MAIN.entryoff`, and calls that entry point directly. TinyGuestTV's `main()` deliberately returns `4242`.

Current CI correlation:

- preferred image base: `0x100000000`
- `LC_MAIN.entryoff`: `0x400c`
- `_main`: `0x10000400c`

Expected device result:

`PASS MVP2B: LC_MAIN executed (return=4242, entryoff=0x400c)`

### MVP 3 — cold-start a real UIKit/tvOS guest

Calling a second `UIApplicationMain()` after the host UI is already running would not model LiveContainer correctly. Upstream LiveContainer instead selects and jumps to the guest main path before the application runtime takes over.

MVP3 follows that architecture more closely:

1. In the host UI, select **MVP3: arm cold-start UIKit guest**.
2. The host writes a persistent one-shot flag.
3. Force-close LiveContainerTV.
4. On the next process launch, `main()` consumes the flag **before host `UIApplicationMain()`**.
5. It loads `Frameworks/UIKitGuestTV.framework/UIKitGuestTV` with `dlopen()`.
6. It resolves the loaded image base with `dladdr()`.
7. It reads the guest's preserved `LC_MAIN`.
8. It jumps to the original guest `main()`.
9. The guest calls its own `UIApplicationMain()` and launches `LCTVUIKitGuestAppDelegate`.
10. `didFinishLaunching` stores a persistent PASS marker and presents a green **MVP3 PASS** screen.

This intentionally does **not** virtualize `NSBundle.mainBundle`, executable path, HOME, bundle identifier, or resources yet. The MVP3 screen displays the current main-bundle identifier so the next virtualization milestone has an explicit baseline.

If the cold-start loader fails before entering the guest, it records a readable error and falls back to the normal host probe UI. If the process crashes after the jump but before guest `didFinishLaunching`, the one-shot flag has already been consumed and the persisted status remains at `MVP3 STARTED`, giving us a simple crash-stage signal without a debugger.

## Hardware test order

1. MVP0
2. MVP2A
3. MVP2B
4. MVP3 arm -> force-close -> reopen

Do not start with MVP3; the first three probes narrow signing/dyld/Mach-O failures before UIKit lifecycle is introduced.

## Build

GitHub Actions generates the Xcode project with XcodeGen, builds for `appletvos`, builds both real guest applications as `MH_EXECUTE`, patches them into `MH_DYLIB`, verifies their Mach-O structure and exported probe symbols, embeds both patched guests before signing, and creates an unsigned IPA.

The final IPA must then be signed recursively and installed using a tvOS sideloading workflow such as atvloadly/plumesign. Patched guests are embedded before signing so the nested code can receive a valid signature.

## Roadmap

- [x] MVP 0: tvOS host + embedded dynamic payload + `dlopen`/`dlsym` probe — CI validated, hardware pending
- [x] MVP 1: real tvOS executable `MH_EXECUTE` -> `MH_DYLIB` patch — CI validated
- [ ] MVP 2A: `dlopen` + `dlsym` of patched/signed TinyGuestTV — hardware pending
- [ ] MVP 2B: invoke preserved TinyGuestTV `LC_MAIN` — hardware pending
- [ ] MVP 3: cold-start UIKitGuestTV through its original `LC_MAIN`/`UIApplicationMain` — implementation + CI pending/hardware pending
- [ ] MVP 4: guest `NSBundle.mainBundle`, `_NSGetExecutablePath`, process-name and `@executable_path` virtualization
- [ ] MVP 5: tvOS guest HOME/container model using purgeable storage + reconstructible app bundles
- [ ] MVP 6: IPA import/download from VPS and automatic patch preparation
- [ ] MVP 7: signing/provisioning integration, app library UI and compatibility layer

## Upstream baseline

Initial baseline: `LiveContainer/LiveContainer@12377cf3b91d51739a33f14a302e5f522b238593` (2026-09-06).

## License

This work lives inside an AGPLv3 LiveContainer fork. Code adapted from LiveContainer remains under the repository's AGPLv3 terms; upstream notices and source availability must be preserved.
