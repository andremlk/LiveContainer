# LiveContainerTV tvOS — MVP7J to Final Test Matrix

This matrix is intentionally linear. Do not skip a gate just because a later build compiles.

| Gate | Build | Device observation | Interpretation | Next action |
|---|---|---|---|---|
| J0 | MVP7J | `CS_DEBUGGED=NO` | JIT/debug state is not active for the host process | Enable/attach JIT, then repeat MVP7J before guest-entry work |
| J1 | MVP7J | `CS_DEBUGGED=YES`, executable-memory probe `PASS return=42` | Basic dynamic executable memory is usable | MVP8 entry trace is eligible for device testing |
| J2 | MVP7J | `CS_DEBUGGED=YES`, executable-memory probe fails | Need memory-policy detail | Run MVP7K diagnostics |
| K1 | MVP7K | plain RW->RX passes | Standard W^X transition works | Continue to MVP8; MAP_JIT is informative, not blocking |
| K2 | MVP7K | plain RW->RX fails but MAP_JIT path passes | Guest/JIT path must use MAP_JIT-compatible allocation | Wire MAP_JIT strategy before production guest runtime |
| K3 | MVP7K | both executable-memory paths fail | Host signing/JIT policy is still blocking execution | Stop guest-entry tests; fix signing/JIT activation first |
| E0 | MVP8 | trace reaches `HOST_MAIN_ENTER armed=...` | Cold-start selection survived | Observe next legacy stage |
| E1 | MVP8 | `RESOURCE PREP FAIL` / descriptor failure | Import/store problem before dyld | Fix registry/seed/descriptor only |
| E2 | MVP8 | `DLOPEN FAIL` | Signed guest code cannot be loaded | Investigate guest signature/dependencies/load commands |
| E3 | MVP8 | loaded-image lookup fails | dyld accepted load but image discovery/path identity differs | Fix loaded-image matching |
| E4 | MVP8 | `LC_MAIN FAIL` | Guest image loaded but entry metadata is incompatible/missing | Fix Mach-O conversion/LC_MAIN patching |
| E5 | MVP8 | legacy `PASS ... entryoff=...` then guest UI appears | Guest main boundary succeeded | Begin app-specific compatibility work |
| E6 | MVP8 | legacy `PASS ... entryoff=...` then immediate exit/crash, no `HOST_MAIN_RETURN` | Failure occurs at/inside guest main boundary | Capture device crash/log and instrument guest startup |
| E7 | MVP8 | `HOST_MAIN_RETURN result=N` | Guest main returned to host instead of owning process lifecycle | Diagnose return code and UIApplicationMain/startup path |
| F0 | Final assembler | safety workflow passes | Host binary can be replaced while preserving outer identity + guest catalog | Use approved host template + current installed-chain IPA |
| F1 | Final package | outer ID is exactly `dev.andre.livecontainertv.mvp3` before signing | Update will target the existing app identity | Sign with the same App ID/provisioning chain |
| F2 | Final package | all existing guest bundle IDs are `preserved`; expected new guests are `added/updated` | Catalog delta is sane | Install over existing LiveContainerTV and verify app data |

## Frozen baselines

- MVP7J remains on `tvos-mvp0`; do not modify it while interpreting device results.
- MVP7K diagnostics live on `tvos-mvp7k-diagnostics`.
- MVP8 entry tracing lives on `tvos-mvp8-entry-trace`.
- Final host-replacement assembler preparation lives on `tvos-final-assembler-prep`.

## Final package invariants

1. The approved new host binary must come from the gate that passed device testing.
2. The outer `CFBundleIdentifier` must be copied from the currently installed-chain IPA and must equal `dev.andre.livecontainertv.mvp3` for the present deployment.
3. Imported code slots are preserved only through `LCTVImportCatalog.json`/registry metadata; do not blindly copy the whole old `Frameworks` directory over the new host.
4. Resource seeds must remain code-free: no guest executable, nested `Frameworks`, or loose dylibs.
5. Any outer `_CodeSignature` or `embedded.mobileprovision` from a template is discarded after rehosting; the resulting IPA is unsigned and must be signed again.
6. Guest HOME/data continuity remains keyed by guest bundle ID under `Library/Caches/LiveContainerTV/Guests/<bundle-id>/Data`.
