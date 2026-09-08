#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/arm/thread_status.h>
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

// MVP8C diagnostic layer -----------------------------------------------------
// MVP8B proved that Infuse no longer fails immediately in dlopen(): dyld adds
// ~150 images, then the main thread remains inside dlopen for 20+ seconds.
// MVP8C keeps that watchdog and also samples the blocked main thread's arm64
// stack from a utility thread.  This lets us distinguish a dyld/initializer
// wait from a guest-framework constructor without modifying the frozen MVP7H
// loader itself.
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

typedef struct {
    uint64_t previousFP;
    uint64_t returnPC;
} LCTVMVP8FrameRecord;

typedef struct {
    uint64_t addresses[8];
    uint32_t count;
    kern_return_t suspendKR;
    kern_return_t stateKR;
} LCTVMVP8StackSample;

static LCTVMVP8StackSample LCTVMVP8SampleThread(thread_t thread) {
    LCTVMVP8StackSample sample = {0};
    sample.suspendKR = thread_suspend(thread);
    if (sample.suspendKR != KERN_SUCCESS) return sample;

    arm_thread_state64_t state = {0};
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    sample.stateKR = thread_get_state(thread,
                                      ARM_THREAD_STATE64,
                                      (thread_state_t)&state,
                                      &stateCount);
    if (sample.stateKR == KERN_SUCCESS) {
        uint64_t pc = state.__pc;
        uint64_t lr = state.__lr;
        uint64_t fp = state.__fp;
        if (pc) sample.addresses[sample.count++] = pc;
        if (lr && sample.count < 8) sample.addresses[sample.count++] = lr;

        // arm64 frame records are {previous FP, saved LR}.  Read through Mach
        // rather than dereferencing the other thread's stack directly.
        for (unsigned depth = 0; depth < 6 && fp && sample.count < 8; depth++) {
            LCTVMVP8FrameRecord record = {0};
            mach_vm_size_t copied = 0;
            kern_return_t readKR = mach_vm_read_overwrite(mach_task_self(),
                                                          (mach_vm_address_t)fp,
                                                          sizeof(record),
                                                          (mach_vm_address_t)&record,
                                                          &copied);
            if (readKR != KERN_SUCCESS || copied != sizeof(record)) break;
            if (record.returnPC) sample.addresses[sample.count++] = record.returnPC;
            if (!record.previousFP || record.previousFP <= fp || record.previousFP - fp > (1ULL << 20)) break;
            fp = record.previousFP;
        }
    }

    thread_resume(thread);
    return sample;
}

static NSString *LCTVMVP8CompactAddress(uint64_t address) {
    if (!address) return @"0x0";
    Dl_info info = {0};
    if (dladdr((const void *)(uintptr_t)address, &info) == 0 || !info.dli_fname) {
        return [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
    }
    NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"?";
    NSString *leaf = path.lastPathComponent ?: path;
    NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : nil;
    if (!symbol.length) return [NSString stringWithFormat:@"%@+0x%llx", leaf, (unsigned long long)address];
    uintptr_t symbolAddress = (uintptr_t)info.dli_saddr;
    uint64_t offset = symbolAddress && address >= symbolAddress ? address - symbolAddress : 0;
    return [NSString stringWithFormat:@"%@!%@+0x%llx", leaf, symbol, (unsigned long long)offset];
}

static void LCTVMVP8TraceMainThreadSample(thread_t mainThread, unsigned seconds) {
    LCTVMVP8StackSample sample = LCTVMVP8SampleThread(mainThread);
    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_MAIN_STACK t=%us frames=%u suspendKR=%d stateKR=%d",
                        seconds,
                        sample.count,
                        sample.suspendKR,
                        sample.stateKR]);
    // Five frames are enough to retain the blocking site plus its callers while
    // keeping the persistent panel readable after the host is reopened.
    uint32_t limit = sample.count < 5 ? sample.count : 5;
    for (uint32_t i = 0; i < limit; i++) {
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"STACK t=%us #%u %@",
                            seconds,
                            i,
                            LCTVMVP8CompactAddress(sample.addresses[i])]);
    }
}

static void *LCTVMVP8Dlopen(const char *path, int mode) {
    @autoreleasepool {
        LCTVMVP8RegisterDyldObserver();
        NSString *guestPath = path ? [NSString stringWithUTF8String:path] : @"(null)";
        NSString *guestName = guestPath.lastPathComponent ?: guestPath;
        uint64_t baseline = atomic_load_explicit(&LCTVMVP8DyldGeneration, memory_order_relaxed);
        thread_t mainThread = mach_thread_self();

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

                    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_STILL_RUNNING t=%us imagesAdded=%llu",
                                        now,
                                        (unsigned long long)added]);
                    NSString *lastImage = LCTVMVP8CompactImageName(lastHeader);
                    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_LAST_IMAGE t=%us %@",
                                        now,
                                        lastImage]);
                    LCTVMVP8TraceMainThreadSample(mainThread, now);
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
// and route only its dlopen() call through the MVP8C diagnostic wrapper.
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
