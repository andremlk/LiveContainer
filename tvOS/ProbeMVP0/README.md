# LiveContainerTV

Experimental tvOS port/probe derived from the architecture of [LiveContainer](https://github.com/LiveContainer/LiveContainer).

## Current status

The project now has three progressively stronger validation stages:

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

This is deliberately separate from jumping to `LC_MAIN`: it isolates whether tvOS accepts a correctly signed, patched application executable as a loadable image. If this succeeds on hardware, MVP 2B can safely focus on calculating and invoking the preserved `LC_MAIN` entry point.

Expected device result:

`PASS MVP2A: patched MH_EXECUTE loaded as MH_DYLIB (TinyGuestTV/tvOS)`

## Build

GitHub Actions generates the Xcode project with XcodeGen, builds for `appletvos`, performs Mach-O checks, and creates an unsigned IPA. The IPA must then be signed recursively and installed using a tvOS sideloading workflow such as atvloadly/plumesign. The patched guest is placed under `Frameworks/TinyGuestTV.framework` before that final signing step so the nested code can receive a valid signature.

## Roadmap

- [x] MVP 0: tvOS host + embedded dynamic payload + `dlopen`/`dlsym` probe — CI validated, hardware pending
- [x] MVP 1: real tvOS executable `MH_EXECUTE` -> `MH_DYLIB` patch — CI validated
- [ ] MVP 2A: `dlopen` + `dlsym` of the patched/signed tvOS executable — hardware pending
- [ ] MVP 2B: locate and invoke preserved `LC_MAIN` entry point
- [ ] MVP 3: adapt executable-path and main-bundle replacement from LiveContainer
- [ ] MVP 4: guest HOME/container redirection designed for tvOS purgeable storage
- [ ] MVP 5: IPA import/download from remote source/VPS
- [ ] MVP 6: signing/provisioning integration and app compatibility layer

## Upstream baseline

Initial baseline: `LiveContainer/LiveContainer@12377cf3b91d51739a33f14a302e5f522b238593` (2026-09-06).

## License

This work lives inside an AGPLv3 LiveContainer fork. Code adapted from LiveContainer remains under the repository's AGPLv3 terms; upstream notices and source availability must be preserved.
