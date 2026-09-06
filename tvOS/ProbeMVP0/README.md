# LiveContainerTV

Experimental tvOS port/probe inspired by the architecture of [LiveContainer](https://github.com/LiveContainer/LiveContainer).

## Current milestone: MVP 0

This first milestone intentionally does **not** try to boot an arbitrary tvOS `.app` yet. It validates the lowest-risk part of the runtime chain on real Apple TV hardware:

1. Build a tvOS host application.
2. Embed a signed ARM64 tvOS framework payload.
3. Resolve the nested binary path at runtime.
4. Load it with `dlopen()`.
5. Resolve an exported symbol with `dlsym()`.
6. Execute guest code and report PASS/FAIL on screen.

A successful result proves that our host/container, packaging, runtime search paths and dynamic-code loading assumptions work on the target Apple TV. The next milestone replaces the framework payload with a patched tvOS app executable (`MH_EXECUTE` -> `MH_DYLIB`) and begins adapting LiveContainer's bootstrap logic.

## Build

The GitHub Actions workflow generates the Xcode project with XcodeGen, builds an unsigned `appletvos` device app and packages it as an IPA. The resulting IPA is intended to be signed/installed by a tvOS sideloading workflow such as atvloadly/plumesign.

## Expected result

Press **Run loader probe**. Success displays:

`PASS: tvOS guest payload executed through dlopen + dlsym`

## Roadmap

- [x] MVP 0: tvOS host + embedded dynamic payload + `dlopen`/`dlsym` probe
- [ ] MVP 1: minimal Mach-O parser and `MH_EXECUTE` -> `MH_DYLIB` patch
- [ ] MVP 2: package a tiny guest tvOS app and jump to its `LC_MAIN` entry point
- [ ] MVP 3: adapt executable-path and main-bundle replacement from LiveContainer
- [ ] MVP 4: guest HOME/container redirection designed for tvOS purgeable storage
- [ ] MVP 5: IPA import/download from remote source/VPS
- [ ] MVP 6: signing/provisioning integration and app compatibility layer

## License

This probe contains original scaffolding only. As soon as LiveContainer AGPLv3 source is incorporated, the derived project must remain compatible with the upstream AGPLv3 license and preserve required notices/source availability.
