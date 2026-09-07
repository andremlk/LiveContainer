#include <TargetConditionals.h>

__attribute__((visibility("default")))
const char *LCTVGuestEntry(void) {
#if TARGET_OS_TV
    return "PASS: tvOS guest payload executed through dlopen + dlsym";
#else
    return "FAIL: payload was not compiled for tvOS";
#endif
}
