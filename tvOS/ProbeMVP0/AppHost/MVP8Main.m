#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdatomic.h>
#import <sys/types.h>
#import <unistd.h>
#import "MVP8Trace.h"

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static BOOL LCTVMVP8IsDebugged(void) {
    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & CS_DEBUGGED) != 0;
}

// MVP8B diagnostic layer -----------------------------------------------------
// Keep the proven MVP7H loader source frozen.  We interpose only its dlopen()
// call at compile time so we can learn whether dyld returns, how long it stays
// inside the load, and which image was most recently announced by dyld.
//
// The dyld callback itself performs no Foundation work and no logging.  It only
// stores a header pointer/counter.  A separate watchdog queue turns that state
// into persistent MVP8 trace entries while the main thread is inside dlopen().
static _Atomic(uint64_t) LCTVMVP8DyldGeneration = 0;
static _Atomic(uintptr_t) LCTVMVP8LastDyldHeader = 0;
static dispatch_once_t LCTVMVP8DyldRegistrationOnce;

static void LCTVMVP8DyldImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    atomic_store_explicit(&LCTVMVP8LastDyldHeader, (uintptr_t)header, memory_order_relaxed);
    atomic_fetch_add_explicit(&LCTVMVP8DyldGeneration, 1, memory_order_relaxed);
}

static void LCTVMVP8RegisterDyldObserver(void) {
    dispatch_once(&LCTVMVP8DyldRegistrationOnce, ^{
        _dyld_register_func_for_add_image(LCTVMVP8DyldImageAdded);
    });
}

static NSString *LCTVMVP8CompactImageName(uintptr_t headerValue) {
    if (!headerValue) return @"none";
    Dl_info info = {0};
    if (dladdr((const void *)headerValue, &info) == 0 || !info.dli_fname) {
        return [NSString stringWithFormat:@"header=0x%llx", (unsigned long long)headerValue];
    }
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    if (!path.length) return @"unknown";
    NSString *leaf = path.lastPathComponent ?: path;
    NSString *parent = path.stringByDeletingLastPathComponent.lastPathComponent;
    if (parent.length && ![parent isEqualToString:@"Frameworks"]) {
        return [NSString stringWithFormat:@"%@/%@", parent, leaf];
    }
    return leaf;
}

static void *LCTVMVP8Dlopen(const char *path, int mode) {
    @autoreleasepool {
        LCTVMVP8RegisterDyldObserver();
        NSString *guestPath = path ? [NSString stringWithUTF8String:path] : @"(null)";
        NSString *guestName = guestPath.lastPathComponent ?: guestPath;
        uint64_t baseline = atomic_load_explicit(&LCTVMVP8DyldGeneration, memory_order_relaxed);

        LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_ENTER target=%@ imagesBaseline=%llu",
                            guestName,
                            (unsigned long long)baseline]);

        atomic_bool *finished = malloc(sizeof(*finished));
        if (finished) {
            atomic_init(finished, false);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                const unsigned checkpoints[] = {1, 3, 5, 10, 20};
                unsigned previous = 0;
                for (NSUInteger i = 0; i < sizeof(checkpoints) / sizeof(checkpoints[0]); i++) {
                    unsigned now = checkpoints[i];
                    sleep(now - previous);
                    previous = now;
                    if (atomic_load_explicit(finished, memory_order_acquire)) return;

                    uint64_t generation = atomic_load_explicit(&LCTVMVP8DyldGeneration, memory_order_relaxed);
                    uintptr_t lastHeader = atomic_load_explicit(&LCTVMVP8LastDyldHeader, memory_order_relaxed);
                    uint64_t added = generation >= baseline ? generation - baseline : 0;

                    // Persist the heartbeat first.  If resolving the image name happens to
                    // block behind dyld, the timing/count evidence is already durable.
                    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_STILL_RUNNING t=%us imagesAdded=%llu",
                                        now,
                                        (unsigned long long)added]);

                    NSString *lastImage = LCTVMVP8CompactImageName(lastHeader);
                    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_LAST_IMAGE t=%us %@",
                                        now,
                                        lastImage]);
                }
            });
        }

        void *handle = dlopen(path, mode);
        if (finished) atomic_store_explicit(finished, true, memory_order_release);

        LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_RETURN %@ target=%@ imagesAdded=%llu",
                            handle ? @"OK" : @"NULL",
                            guestName,
                            (unsigned long long)(atomic_load_explicit(&LCTVMVP8DyldGeneration, memory_order_relaxed) - baseline)]);
        return handle;
    }
}

// Compile the proven MVP7H loader unchanged, but rename its process entry point
// and route only its dlopen() call through the MVP8B diagnostic wrapper.
#define dlopen LCTVMVP8Dlopen
#define main LCTVMVP7HOriginalMain
#include "MVP7HMain.m"
#undef main
#undef dlopen

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *armed = [defaults stringForKey:@"LCTVMVP7HSelectedSlotNextLaunch"];
        BOOL debugged = LCTVMVP8IsDebugged();

        LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_ENTER debugged=%@ armed=%@",
                            debugged ? @"YES" : @"NO",
                            armed.length ? armed : @"none"]);

        // An armed guest is consumed from process main, before the host UIKit UI exists.
        // Therefore attaching after a normal manual reopen is too late.  Refuse that unsafe
        // path and require `lctv jit launch`, which DVT-starts the process suspended and
        // debugserver-attaches before this main executes.
        if (armed.length && !debugged) {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"JIT_GATE_BLOCKED guest=%@", armed]);
            [defaults removeObjectForKey:@"LCTVMVP7HSelectedSlotNextLaunch"];
            [defaults setObject:@"MVP8 JIT REQUIRED: guest launch blocked before dlopen. Arm it again, then run: lctv jit launch"
                       forKey:@"LCTVMVP7HResult"];
            [defaults synchronize];
        } else if (armed.length) {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"JIT_GATE_PASS guest=%@", armed]);
        } else {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_UI_BOOT debugged=%@", debugged ? @"YES" : @"NO"]);
        }

        int result = LCTVMVP7HOriginalMain(argc, argv);
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_RETURN result=%d", result]);
        return result;
    }
}
