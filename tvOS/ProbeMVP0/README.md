# LiveContainerTV

Experimental tvOS port/probe derived from the architecture of [LiveContainer](https://github.com/LiveContainer/LiveContainer).

## Current status

The project now has four progressively stronger validation stages:

### MVP 0 — normal tvOS dynamic payload

Build a native tvOS host, embed an ARM64 tvOS framework, load it with `dlopen()`, resolve an exported symbol with `dlsym()`, and execute it. GitHub Actions builds and packages this successfully. Hardware execution is still to be validated on the target Apple TV.

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

This stage is validated by both `otool` and an independent parser. CI result:

`PASS: patched Mach-O is MH_DYLIB, has adjusted __PAGEZERO, LC_ID_DYLIB, and preserved LC_MAIN`

### MVP 2A — hardware-load the patched executable

The CI pipeline packages the patched `TinyGuestTV` binary as a nested framework-like bundle inside the host IPA **before signing**. The host exposes a second button that calls `dlopen()` on this patched former application executable and resolves `LCTVGuestMarker` with `dlsym()`.

This isolates whether tvOS accepts a correctly signed, patched application executable as a loadable image.

Expected device result:

`PASS MVP2A: patched MH_EXECUTE loaded as MH_DYLIB (TinyGuestTV/tvOS)`

### MVP 2B — execute the preserved `LC_MAIN`

The host exposes a third hardware probe. It loads the same patched guest, uses `dladdr()` to recover the runtime Mach-O base, walks the loaded image's load-command table, reads `LC_MAIN.entryoff`, calculates the preserved entry point, and invokes it directly as the guest's original `main(int, char **)`.

`TinyGuestTV` deliberately returns the sentinel value `4242` from `main()`. The host does **not** resolve `main` with `dlsym()`, so a PASS demonstrates that execution reached the address described by the preserved `LC_MAIN` command.

Expected device result:

`PASS MVP2B: LC_MAIN executed (return=4242, entryoff=0x...)`

This is still a controlled guest rather than a UIKit guest. A successful MVP2B therefore validates entry-point transfer but does not yet prove that a second `UIApplicationMain` can take over the process. That is the next milestone.

## Build

GitHub Actions generates the Xcode project with XcodeGen, builds for `appletvos`, performs Mach-O checks, and creates an unsigned IPA. The IPA must then be signed recursively and installed using a tvOS sideloading workflow such as atvloadly/plumesign. The patched guest is placed under `Frameworks/TinyGuestTV.framework` before that final signing step so the nested code can receive a valid signature.

## Hardware test order

Run the probes in order so each result narrows the failure domain:

1. `MVP0: load normal framework`
2. `MVP2A: load patched tvOS executable`
3. `MVP2B: execute preserved LC_MAIN`

A failure in MVP2B after MVP2A passes means dyld accepted the transformed image and the remaining problem is specifically entry-point discovery/invocation rather than signing or `dlopen()` acceptance.

## Roadmap

- [x] MVP 0: tvOS host + embedded dynamic payload + `dlopen`/`dlsym` probe — CI validated, hardware pending
- [x] MVP 1: real tvOS executable `MH_EXECUTE` -> `MH_DYLIB` patch — CI validated
- [ ] MVP 2A: `dlopen` + `dlsym` of the patched/signed tvOS executable — hardware pending
- [ ] MVP 2B: locate and invoke preserved `LC_MAIN` entry point — implementation/CI prepared, hardware pending
- [ ] MVP 3: run a controlled UIKit/tvOS guest through its original application entry path
- [ ] MVP 4: adapt executable-path and main-bundle replacement from LiveContainer
- [ ] MVP 5: guest HOME/container redirection designed for tvOS purgeable storage
- [ ] MVP 6: IPA import/download from remote source/VPS
- [ ] MVP 7: signing/provisioning integration and app compatibility layer

## Upstream baseline

Initial baseline: `LiveContainer/LiveContainer@12377cf3b91d51739a33f14a302e5f522b238593` (2026-09-06).

## License

This work lives inside an AGPLv3 LiveContainer fork. Code adapted from LiveContainer remains under the repository's AGPLv3 terms; upstream notices and source availability must be preserved.
