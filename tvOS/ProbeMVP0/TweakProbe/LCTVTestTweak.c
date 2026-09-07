#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// Native tvOS tweak probe used to validate the loader before any third-party tweak.
// The host/test harness may set LCTV_TWEAK_MARKER_PATH to a writable location.
__attribute__((constructor))
static void lctv_tweak_constructor(void) {
    const char *marker = getenv("LCTV_TWEAK_MARKER_PATH");
    if (!marker || !*marker) {
        return;
    }
    FILE *f = fopen(marker, "a");
    if (!f) {
        return;
    }
    fputs("LCTV_TWEAK_LOADED\n", f);
    fclose(f);
}

__attribute__((visibility("default")))
uint32_t LCTVTestTweakMagic(void) {
    return 0x5445574B; // 'TEWK'
}
