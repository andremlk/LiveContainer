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

## MVP7J — JIT experiment

Objective: investigate whether JIT can remove or reduce the signed-code-slot requirement.

Upstream LiveContainer detects JIT through process debug state (`CS_DEBUGGED`) and uses JIT to enable its dyld/library-validation bypass before loading guests.

Implemented host-side probe work:

1. runtime `CS_DEBUGGED` telemetry
2. live status overlay on the MVP7H-compatible launcher
3. explicit arm64 executable-memory probe (`mov w0,#42; ret`) only after debug/JIT state is present
4. host-template build that can be rebased into the user's existing imported-guest IPA without replacing CodeSlots/GuestSeeds/catalog

Remaining hardware sequence:

1. Enable JIT for the LiveContainerTV process over the existing remote pairing/RSD path.
2. Verify `CS_DEBUGGED=YES` inside LiveContainerTV.
3. Run the executable-memory probe and require return `42`.
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
6. rebase the new MVP7J host while preserving all current guest slots
7. verify JIT overlay shows `CS_DEBUGGED=NO` before attaching a debugger/JIT enabler

## DO NOT REPEAT — known failed/invalid approaches

These results are treated as closed unless a future OS/JIT change explicitly gives a reason to revisit them:

- **Global dyld `_NSGetExecutablePath` mutation:** crashes. Use the guest-scoped identity bridge only.
- **Physical executable copy into writable Caches without JIT:** fails with `code signature invalid`, even when byte-identical.
- **Writable symlink to installed signed executable:** sandbox denies the symlink approach used in MVP7C.
- **Installing an update with unsigned-template ID `dev.livecontainertv.probe`:** creates a second app/sandbox. Use the existing outer signing ID `dev.andre.livecontainertv.mvp3` for in-place hardware updates.
- **Keeping `SC_Info` in the writable resource seed:** Infuse resource staging fails with a permission error. Strip it during split/import.
- **Blind `@executable_path/Frameworks -> @loader_path/Frameworks` rewrite when target already exists:** creates duplicate `LC_RPATH` and dyld rejects Infuse. Skip the rewrite when the destination RPATH is already present.
- **Assuming app extensions work:** they are currently ignored; Infuse `tv_shelf.appex` is not part of the runtime test path.
- **Assuming Caches is durable storage:** tvOS may purge it. Persistent recovery/backup still needs a separate design.

## Logging rule

Every hardware result, regression, architectural conclusion, and workaround discovered from this point forward should be appended to this file in the same change set as the relevant code whenever practical.

## 2026-09-07/08 — JIT + MVP8 Infuse diagnostic continuation

### RemotePairing / JIT hardware validation

- Persistent Wi-Fi RemotePairing established directly from Termux/pymobiledevice3 to Apple TV.
- Plain `developer dvt` / `--userspace` attempted `usbmuxd` first and failed on Android/PRoot. Working path bypasses that initial probe and opens `RemotePairingTunnelService` directly.
- DVT process lookup + `com.apple.internal.dt.remote.debugproxy` raw RSP attach/detach — PASS on hardware.
- After attach/detach, host reports `CS_DEBUGGED=YES`.
- MVP7J executable-memory probe (`RW -> RX`, arm64 `mov w0,#42; ret`) returned `42` — PASS on hardware.
- `lctv jit launch` relaunches the host suspended before `main`, attaches debugserver, detaches, and then lets the process continue — PASS on hardware.
- MVP8 verified `HOST_MAIN_ENTER debugged=YES` and `HOST_UI_BOOT debugged=YES` when launched through `lctv jit launch`.

Conclusion: JIT/debug state is no longer hypothetical. The pre-main debug/JIT path is hardware proven on tvOS 18.6.

### Infuse failure 3 — direct `@executable_path` dylib dependency

After duplicate-`LC_RPATH` handling, Infuse reached a new dyld error:

`@executable_path/Frameworks/InfuseBypass.framework/InfuseBypass`

The framework was present inside the guest code slot, but `@executable_path` resolved against the outer LiveContainerTV executable, so dyld searched the wrong directory.

Fix:

- extend the portable Mach-O patcher beyond `LC_RPATH` handling
- rewrite direct guest dylib dependencies from `@executable_path/...` to `@loader_path/...` where appropriate
- preserve duplicate-RPATH avoidance separately

Validation:

- packaged guest contains `InfuseBypass.framework`
- patched Infuse binary contains `@loader_path/Frameworks/InfuseBypass.framework/InfuseBypass`
- old concrete `@executable_path/.../InfuseBypass` dependency is gone

Hardware result: immediate `InfuseBypass` dlopen failure no longer occurs.

### MVP8B — dlopen watchdog hardware result

With the dependency rebase fix installed and launched through `lctv jit launch`:

- process remains alive instead of exiting immediately
- TV remains black while guest load is in progress
- `dlopen()` does not return within 20 seconds
- dyld image-add count reaches `150` and remains unchanged at 5 s, 10 s, and 20 s
- last image reported by the dyld callback is `BackgroundTasks.framework/BackgroundTasks`

Important interpretation:

- `BackgroundTasks.framework` is only the last image announced by dyld; do **not** treat it as proven root cause.
- Because `imagesAdded=150` is stable while `dlopen()` remains blocked, the current leading hypothesis is a constructor / Objective-C `+load` / Swift initializer / initialization-time wait after image mapping.
- Repeating MVP8B without extra instrumentation is low-value; use stack sampling instead.

### MVP8C — stack sampler CI lesson

First MVP8C build attempt failed because tvOS SDK rejects `<mach/mach_vm.h>` and `mach_vm_read_overwrite` is unavailable there.

Do not repeat:

- importing `<mach/mach_vm.h>` for this tvOS target
- using `mach_vm_read_overwrite` in the host diagnostic sampler

Fix:

- use supported `vm_read_overwrite` from the tvOS Mach headers instead
- rebuild succeeded after this change

MVP8C goal: while `dlopen()` is blocked, sample the main thread stack at watchdog checkpoints so the next hardware run can identify the actual blocking function/framework instead of guessing from the last dyld image.

### Additional DO NOT REPEAT items from this phase

- **Launching an armed guest by reopening the host normally:** too late for JIT. Use `lctv jit launch` so `CS_DEBUGGED=YES` exists before host `main`.
- **Treating a successful JIT attach as proof that the guest boot succeeded:** JIT is only the prerequisite; guest loading must be traced separately.
- **Treating the last dyld-added image as the culprit:** it is correlation only until the blocked thread stack identifies the wait site.
- **Re-testing the old `InfuseBypass` missing-path failure after the direct dependency rebase fix is verified:** that failure is closed unless a regression reintroduces the old path.

### MVP8C — hardware main-thread stack result

MVP8C was installed with the verified `InfuseBypass` dependency rebase intact and launched with `lctv jit launch`.

JIT launch result:

- suspended pre-main launch — PASS
- debugserver ATTACH — PASS
- DETACH — PASS
- process remained alive after detach

At 20 seconds while `dlopen()` was still blocked, the sampled main-thread stack was:

`#0 libsystem_kernel.dylib!__ulock_wait+0x8`
`#1 libdispatch.dylib!<redacted>+0x38`
`#2 libdispatch.dylib!<redacted>+0x94`
`#3 libdispatch.dylib!<redacted>+0x3c`
`#4 UIKitCore!<redacted>+0x98`

Interpretation:

- the main thread is not spinning in dyld mapping; it is sleeping in an unfair-lock / ulock wait reached through libdispatch
- the first non-dispatch caller visible is UIKitCore
- this strongly points to a synchronous dispatch/once-style initialization wait inside UIKit-related startup while `dlopen()` is running
- this does **not** prove UIKitCore itself is the root cause; another thread may hold the resource or be executing the initializer the main thread is waiting on
- the previous `BackgroundTasks.framework` last-image observation remains correlation only

Next diagnostic should sample other process threads during the hang and identify the thread that is running/holding the corresponding initialization path, rather than repeating the same main-thread-only stack capture.

DO NOT REPEAT:

- treating the MVP8C main-thread stack as proof of a simple dyld mapping hang
- treating UIKitCore frame #4 as definitive root cause without inspecting other threads
- repeating MVP8C unchanged; the next useful probe is cross-thread sampling during the blocked `dlopen()`

### MVP8E — hardware deep deadlock result and confirmed cause

MVP8E was installed with Infuse 8.5.1 and launched through `lctv jit launch` on AppleTV14,1 / tvOS 18.6.

Observed after 20 seconds:

- `DLOPEN_HANG t=20s imagesAdded=150 last=BackgroundTasks.framework/BackgroundTasks`
- main thread: `__ulock_wait -> libdispatch -> UIKitCore -> libobjc`
- highest-scored peer: `__ulock_wait2 -> libsystem_platform -> dyld -> libobjc.A.dylib!imp_implementationWithBlock -> BoardServices!_BSObjCClassCreate -> UIKitServices`
- another peer: `__ulock_wait2 -> libsystem_platform -> BoardServices -> libxpc -> libdispatch`

Confirmed deadlock pattern:

1. the main thread calls guest `dlopen()` and dyld holds its outer recursive API lock while running image initializers / Objective-C load work;
2. UIKit startup synchronously waits for BoardServices/UIKitServices work;
3. the BoardServices worker creates or installs Objective-C classes and re-enters dyld;
4. that worker blocks on the dyld API lock held by the main thread;
5. the main thread cannot finish its UIKit wait until the worker proceeds, producing the persistent black screen.

`BackgroundTasks.framework` was only the last image reported by the add-image callback. It was not the cause.

Conclusion: MVP8E completed the diagnosis. Repeating the deep sampler unchanged has no value.

### MVP8F — solution implemented: thread-scoped dyld no-lock load

Solution selected from the current upstream LiveContainer black-screen fix and adapted to this standalone tvOS host:

- locate `dyld4::LibSystemHelpers` and its recursive lock/unlock methods in the dyld shared cache through the pinned `litehook` submodule;
- temporarily replace only the two corresponding libdyld vtable slots;
- identify the guest-loading thread and bypass only the first matching dyld recursive API lock on that thread;
- preserve the real lock behavior for every other thread and for every unrelated lock;
- call the transformed guest with `RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST`;
- restore the original vtable entries immediately after `dlopen()` returns, before tracing or continuing to `LC_MAIN`;
- keep the MVP8E watchdog and stack sampler as fallback evidence if a different wait remains;
- refuse to fall back to the known-deadlocking raw `dlopen()` if symbol lookup or vtable protection fails.

Safety details:

- no Foundation/Objective-C logging occurs between vtable patching and `dlopen()`;
- installation is serialized with an atomic guard;
- shared-cache page writes use the direct Mach protection wrapper and TPRO fallback already used by LiveContainer;
- the target Mach thread right is released and all temporary global state is cleared after restoration;
- the signed code-slot, writable resource split, guest identity virtualization, stable outer bundle ID, and real `LC_MAIN` path remain unchanged.

Expected hardware trace for the first MVP8F run:

`MVP8F_NOLOCK_BEGIN -> MVP8F_NOLOCK_RESTORED -> DLOPEN_RETURN OK`

After `DLOPEN_RETURN OK`, the loader should locate the transformed image's `LC_MAIN`, finish guest identity setup, and enter Infuse's real main function. Hardware validation is pending.

DO NOT REPEAT:

- raw `dlopen(RTLD_NOW | RTLD_GLOBAL)` for this Infuse path;
- moving guest `dlopen()` to a worker thread as a substitute for breaking the proven dyld/UIKit/BoardServices cycle;
- leaving the libdyld vtable patched after guest `dlopen()` returns;
- bypassing dyld locking globally or for threads other than the single guest-loading thread.

### MVP8F — hardware attempt 1 blocked before guest execution

The first MVP8F launch attempt did not exercise the no-lock loader.

Observed `lctv jit launch` sequence:

- userspace RemotePairing tunnel — PASS
- DVT suspended launch — PASS (`PID 310`)
- debugserver service lookup — FAIL: `No such service: com.apple.internal.dt.remote.debugproxy`
- `ATTACH OK` was never reached
- TV displayed a black frame because the host remained suspended before `main`

Interpretation:

- this is a JIT-launch infrastructure failure, not an MVP8F or Infuse runtime result;
- neither the JIT gate nor `MVP8F_NOLOCK_BEGIN` executed;
- the armed guest selection should remain available because host `main` did not run.

JIT helper safety fix:

- resolve the RSD `remote.debugproxy` port before killing/relaunching the host;
- if the service is missing, fail without creating a suspended process;
- track whether a suspended launch was successfully released by RSP detach;
- on any post-launch attach/detach failure, kill that exact suspended PID through DVT before closing the tunnel;
- print `SAFE CLEANUP` when automatic recovery succeeds.

This prevents the same transient service failure from forcing another Apple TV reboot. A new MVP8F hardware attempt remains pending.
