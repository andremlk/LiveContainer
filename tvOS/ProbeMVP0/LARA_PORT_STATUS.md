# Lara / DarkSword -> LiveContainerTV tvOS port status

Branch: `tvos-lara-darksword-probe`
Base: `tvos-mvp7i-nonjit`

## Goal

Evaluate whether Lara's DarkSword kernel exploit core can be adapted to run on Apple TV (`AppleTV14,1`, A15) with tvOS 18.6, then expose only the useful primitives to LiveContainerTV.

This branch is intentionally isolated from the stable non-JIT MVP7I path.

## Important upstream facts

Upstream Lara is an iOS toolbox using DarkSword. It is built for `iphoneos`, `arm64e`, and iPhone/iPad device families. Its README does not claim tvOS support.

However, Lara already contains explicit LiveContainer runtime handling:

- `islcruntime()` detection
- rehosted-process markers in `darksword.m`
- LiveContainer fallbacks in APFS/VFS/sandbox helpers
- LiveContainer-aware RemoteCall paths

This means LiveContainer hosting itself is not foreign to Lara; the main unknown is tvOS compatibility.

## Why the A15 Apple TV is promising

Lara's offset logic explicitly recognizes the A15 CPU family (`CPUFAMILY_ARM_BLIZZARD_AVALANCHE`) and has A15+ structure-offset branches. This is encouraging but does **not** prove that the same kernel structures/offsets apply on tvOS 18.6.

## Known blockers / differences

1. Upstream build targets `iphoneos`; tvOS uses `appletvos`.
2. UI is SwiftUI/UIKit designed around iPhone/iPad concepts.
3. Several features depend on SpringBoard and iOS-only paths/services.
4. Upstream entitlements include iOS/private capabilities that may not sign or behave the same way on tvOS.
5. Kernel offsets are selected mostly by OS version + CPU family and must be revalidated on tvOS.
6. Kernelcache acquisition/parsing must be validated for Apple TV firmware.
7. The DarkSword exploit itself may rely on kernel behavior that differs between iOS and tvOS even on the same SoC family.

## Port strategy

Do **not** port Lara's whole UI first.

Phase 1 should isolate DarkSword and create a small tvOS diagnostic host that reports:

- `hw.machine`
- `hw.cpufamily`
- `hw.cpusubtype`
- tvOS product version/build
- PAC support
- whether the required system APIs/frameworks link on tvOS
- whether Lara's offset initialization can run without aborting

Phase 2 should attempt `ds_run()` with detailed persistent logging and no post-exploit tweaks.

Success criteria for Phase 2:

- `ds_run()` returns success
- `ds_is_ready()` is true
- non-zero kernel base / slide
- safe read of a validated kernel address

Only after KRW is proven should we consider sandbox/elevation/JIT integration.

## Current conclusion

Best path: port the DarkSword core as a separate diagnostic component and keep it independent of the current LiveContainer guest loader until hardware confirms that DarkSword itself works on tvOS 18.6.

Do not mix this experiment into the stable MVP7I loader until the probe passes.
