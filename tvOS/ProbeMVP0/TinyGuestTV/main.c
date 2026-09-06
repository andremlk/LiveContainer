#include <TargetConditionals.h>

__attribute__((visibility("default")))
const char *LCTVGuestMarker(void) {
#if TARGET_OS_TV
    return "TinyGuestTV/tvOS";
#else
    return "TinyGuestTV/not-tvOS";
#endif
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    return 0;
}
