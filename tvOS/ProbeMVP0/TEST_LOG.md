# LiveContainerTV — Test & Progress Log

This file is the running source of truth for hardware tests, CI milestones, architectural conclusions, regressions, and next experiments for the tvOS port.

## Hardware baseline

- Device: Apple TV `AppleTV14,1`
- tvOS: 18.6
- Wireless install path: Termux -> proot `atvloadly` -> `plumesign sign-rsd`
- RSD/AFC pairing: validated on hardware
- Stable outer bundle ID used for in-place updates: `dev.andre.livecontainertv.mvp3`

## MVP0–MVP3

- MVP0: native tvOS host + embedded dynamic payload -> `dlopen`/`dlsym` PASS on hardware.
- MVP1: real arm64 tvOS app executable transformed `MH_EXECUTE -> MH_DYLIB`; PAGEZERO, flags, `LC_ID_DYLIB`, `LC_MAIN` preserved.
- MVP2A: patched `TinyGuestTV` loads as dylib on hardware — PASS.
- MVP2B: preserved `LC_MAIN` invoked; guest returns `4242` — PASS.
- MVP3: cold-start guest path before host `UIApplicationMain`; `UIKitGuestTV` reaches its own UIKit lifecycle — PASS.

## MVP4 — identity virtualization

Validated on hardware:

- `NSBundle.mainBundle` virtualization — PASS.
- `CFBundleGetMainBundle` virtualization — PASS.
- Guest-scoped `_NSGetExecutablePath` rebinding — PASS.
- Guest HOME + `NSHomeDirectory` virtualization — PASS.
- process name + `_CFGetProgname` virtualization — PASS.

Important negative result:

- Global dyld `_NSGetExecutablePath` mutation crashed. Do not retry that approach.
- Final rebinder is guest-scoped and avoids global dyld mutation.

## MVP5 — analyzer / preparer

Portable analyzer and preparer validate:

- arm64
- `MH_EXECUTE`
- `LC_MAIN`
- tvOS platform
- FairPlay `cryptid == 0`
- PAGEZERO
- frameworks / dylibs / extensions / entitlements

Sample Guide (`abdulkarimkhaan/tvOS-sample-guide`) prepared and launched successfully on hardware.

## MVP6 — multi-guest launcher

Validated with:

- Nuvio TV
- Sample Guide

Hardware results:

- guest selection / staging — PASS
- Nuvio launch — PASS
- Nuvio navigation / network / playback — PASS
- Sample Guide launch — PASS
- guest data isolation / persistence — PASS

## MVP7A — dynamic library discovery

Hardcoded guest catalog removed. Host enumerates prepared guest bundles dynamically.

Hardware: Nuvio + Sample Guide discovered — PASS.

## MVP7B — writable guest store

Writable storage moved to:

`Library/Caches/LiveContainerTV/GuestStore`

Results:

- writable copies can be created/discovered — PASS
- executing a physically copied executable from Caches — FAIL (`code signature invalid`)

Conclusion: writable code bytes cannot simply be copied and executed on tvOS.

## MVP7C — sign/location matrix

Hardware matrix:

- A: signed app-bundle executable — PASS
- B: writable symlink -> signed executable — FAIL; sandbox denied symlink creation
- C: byte-identical physical writable copy — FAIL (`code signature invalid`)
- D: writable bundle/resources/identity + signed executable at installed location — PASS

Architectural conclusion: code must remain in the installed signed bundle; writable resources/identity/data may live in Caches.

## MVP7D — Nuvio split store

Nuvio split architecture:

- writable mirror for identity/resources
- original signed executable + frameworks remain in installed app bundle

Hardware — PASS, including preserved Nuvio configuration.

## MVP7E — generic multi-app split library

Validated with Nuvio + Sample Guide.

Both use writable identity/resources and signed code slots. Hardware — PASS.

## MVP7F — minimal signed slot

Resource seed contains no:

- main executable
- `Frameworks`
- top-level dylibs

Signed slot contains only code-bearing content.

Hardware Nuvio — PASS with 36 frameworks and persistent configuration.

Conclusion: writable side can be resource-only.

## MVP7G — generic IPA importer

Generic pipeline converts compatible IPAs into:

- `CodeSlots/`
- `ResourceSeeds/`
- analysis metadata
- import manifest/catalog

Hardware with Nuvio + Sample Guide — PASS.

## MVP7H — incremental import update

Baseline guests:

- Nuvio
- Sample Guide

New guest:

- UIKitGuestTV (`dev.livecontainertv.uikitguest`)

Hardware update result:

- preserved: 2
- added: 1
- removed: 0
- replaced: 0

UIKitGuestTV launch — PASS.
Nuvio configuration preserved after update — PASS.

## MVP7I — Termux import & install pipeline

Goal: perform import / rebuild / sign / install from Android Termux without requiring a Mac for the operational path.

Implemented commands:

- `lctv doctor`
- `lctv init <base.ipa>`
- `lctv add <guest.ipa> [output.ipa]`
- `lctv install [ipa]`
- `lctv add-install <guest.ipa> [output.ipa]`

Portable Python Mach-O patcher matches the C patcher behavior and is suitable for Termux/Linux.

### Termux hardware validation

`lctv doctor` — PASS.

`lctv init LiveContainerTV-MVP7H-IncrementalUpdate.ipa`:

- host bundle in unsigned base: `dev.livecontainertv.probe`
- imported guests: 3
- PASS

RSD/AFC:

- Apple TV reachable at `192.168.10.163`
- discovered RSD port: `49152`
- `plumesign check afc` with pairing file — PASS

Important install identity result:

- Installing with `dev.livecontainertv.probe` created a separate LiveContainerTV installation.
- Historical PlumeSign commands showed original stable outer bundle ID is `dev.andre.livecontainertv.mvp3`.
- Configuration corrected to `LCTV_CUSTOM_IDENTIFIER='dev.andre.livecontainertv.mvp3'`.
- Reinstall then updated the original app in place — PASS.
- Existing guest catalog survived — PASS.
- Nuvio configuration survived — PASS.

### Infuse 8.5.1 import test

Input: `Infuse-8.5.1.ipa`

Analyzer:

- bundle ID: `com.firecore.infuse`
- version: 8.5.1 (`8.5.5726`)
- `MH_EXECUTE` arm64
- tvOS 18.5 minimum
- `LC_MAIN` present
- `cryptid=0` / unencrypted
- 55 embedded frameworks
- 1 app extension (`tv_shelf.appex`), currently ignored
- compatibility — PASS

Termux import:

- 3 existing guests preserved
- Infuse added
- code slot generated with signed main + 55 frameworks
- resource seed generated without executable/frameworks
- output package built — PASS

Hardware after installation:

- 4 guests visible
- Infuse shown as ADDED
- existing 3 guests PRESERVED

#### Infuse failure 1 — resource store

Observed:

`store=FAIL`

Error pointed to permission while copying `SC_Info`.

Fix:

- strip `SC_Info` from writable resource seed in `lctv_split_guest.py`

Rebuild:

- resource seed size decreased
- package rebuilt successfully

Hardware after reinstall:

- Infuse `store=PASS`

#### Infuse failure 2 — duplicate LC_RPATH

Infuse then reached `dlopen` but dyld rejected the guest with:

`duplicate LC_RPATH '@loader_path/Frameworks'`

Cause:

- original Infuse already contains `@loader_path/Frameworks`
- portable patcher also rewrote `@executable_path/Frameworks` -> `@loader_path/Frameworks`
- this produced a duplicate load command path

Fix implemented:

- if the target `@loader_path` RPATH already exists, do not rewrite the redundant `@executable_path` entry
- Python syntax validation — PASS
- regression coverage added in CI

Hardware retest of the RPATH fix is pending.

### Transform-version fingerprinting

A transform version was added to guest fingerprints so a guest rebuilt with changed preparation logic is detected as UPDATED instead of incorrectly reported as PRESERVED.

## Current architecture

Current non-JIT model:

1. guest IPA is analyzed and transformed
2. writable resource seed is stored separately
3. executable + all code-bearing frameworks/dylibs stay in a signed installed slot
4. outer LiveContainerTV update is signed and installed over the same bundle ID
5. guest HOME remains stable by bundle ID

Stable guest data root:

`Library/Caches/LiveContainerTV/Guests/<bundle-id>/Data`

Known tvOS limitation: Caches may be purgeable, so backup/recovery remains a future requirement.

## MVP7J — JIT experiment (planned)

Objective: investigate whether JIT can remove or reduce the signed-code-slot requirement.

Upstream LiveContainer detects JIT through process debug state (`CS_DEBUGGED`) and uses JIT to enable its dyld/library-validation bypass before loading guests.

Planned sequence:

1. Enable JIT for the LiveContainerTV process over the existing remote pairing/RSD path.
2. Verify `CS_DEBUGGED` / JIT state inside LiveContainerTV.
3. Run a small executable-memory JIT probe.
4. Port/test upstream dyld library-validation bypass on tvOS 18.6.
5. Place a tiny transformed guest executable in writable Caches instead of the signed slot.
6. Attempt `dlopen` from writable storage with JIT enabled.

If step 6 passes, future architecture may become:

`IPA -> Termux import -> writable guest store -> JIT -> dlopen`

instead of rebuilding/re-signing/reinstalling the outer LiveContainerTV for every new guest.

This is not yet proven on tvOS hardware.

## Next hardware test

When back at the Apple TV:

1. rebuild Infuse 8.5.1 with the duplicate-RPATH fix
2. install over `dev.andre.livecontainertv.mvp3`
3. verify `store=PASS`
4. launch Infuse
5. record the next runtime result

## Logging rule

Every hardware result, regression, architectural conclusion, and workaround discovered from this point forward should be appended to this file in the same change set as the relevant code whenever practical.

## 2026-09-09 — Non-JIT continuation branch

Decision: pause all JIT work temporarily and continue from the last pre-JIT baseline.

Exact pre-JIT baseline commit:

`a14717869b336f65f1c1f85a325ab6dca66b3f29` — `docs(tvOS): add hardware and pipeline test log through MVP7I`

New isolated branch:

`tvos-mvp7i-nonjit`

Rules for this branch:

- no `CS_DEBUGGED` gate
- no debugger attach requirement
- no `lctv jit launch` requirement
- no MVP7J/MVP8 runtime probe or stack-sampler code in the host
- keep the signed CodeSlot architecture validated in MVP7C–MVP7I

Post-MVP7I importer fix intentionally ported forward because it is independent of JIT:

- direct guest dylib dependencies beginning with `@executable_path` are rebased to `@loader_path`
- this preserves the verified InfuseBypass fix:
  `@loader_path/Frameworks/InfuseBypass.framework/InfuseBypass`
- duplicate `LC_RPATH` avoidance and `SC_Info` stripping remain part of the MVP7I baseline

New host target:

`LiveContainerTV-MVP7I-NonJIT-HostTemplate.ipa`

The target compiles only the proven MVP7H loader plus `GuestRuntime`; it deliberately excludes `MVP7JProbe.m` and all MVP8 diagnostics.

### Next non-JIT hardware test

1. build the clean MVP7I non-JIT host template in CI
2. import raw `Infuse-8.5.1.ipa` into that template using the current importer with the direct dylib rebase fix
3. verify the concrete InfuseBypass dependency is still `@loader_path/...`
4. sign/install over `dev.andre.livecontainertv.mvp3`
5. open LiveContainerTV normally — no debugger/JIT step
6. arm/launch Infuse using the ordinary MVP7H flow
7. record the first runtime result after `dlopen`

This test answers one specific question: with every known path/resource transformation fix retained, how far can Infuse progress under the fully signed non-JIT architecture?
