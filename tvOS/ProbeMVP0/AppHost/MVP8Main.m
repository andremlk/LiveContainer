#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
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

// MVP8D diagnostic layer -----------------------------------------------------
// MVP8C proved that the main thread is blocked in __ulock_wait -> libdispatch
// with UIKitCore as the first visible non-dispatch caller while dlopen remains
// stuck. MVP8D keeps that sample and, at 20s, scans the other process threads
// to find the likely initializer/queue owner instead of assuming UIKitCore or
// the last dyld-added image is the root cause.
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

        // arm64 frame records are {previous FP, saved LR}. tvOS exposes the
        // classic vm_read_overwrite API (not mach_vm_read_overwrite).
        for (unsigned depth = 0; depth < 6 && fp && sample.count < 8; depth++) {
            LCTVMVP8FrameRecord record = {0};
            vm_size_t copied = 0;
            kern_return_t readKR = vm_read_overwrite(mach_task_self(),
                                                     (vm_address_t)fp,
                                                     (vm_size_t)sizeof(record),
                                                     (vm_address_t)&record,
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

static NSString *LCTVMVP8ImagePathForAddress(uint64_t address) {
    if (!address) return nil;
    Dl_info info = {0};
    if (dladdr((const void *)(uintptr_t)address, &info) == 0 || !info.dli_fname) return nil;
    return [NSString stringWithUTF8String:info.dli_fname];
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

static uint64_t LCTVMVP8ThreadID(thread_t thread) {
    thread_identifier_info_data_t info = {0};
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t kr = thread_info(thread,
                                   THREAD_IDENTIFIER_INFO,
                                   (thread_info_t)&info,
                                   &count);
    return kr == KERN_SUCCESS ? info.thread_id : 0;
}

static void LCTVMVP8TraceMainThreadSample(thread_t mainThread, unsigned seconds) {
    LCTVMVP8StackSample sample = LCTVMVP8SampleThread(mainThread);
    LCTVMVP8TraceEvent([NSString stringWithFormat:@"DLOPEN_MAIN_STACK t=%us frames=%u suspendKR=%d stateKR=%d",
                        seconds,
                        sample.count,
                        sample.suspendKR,
                        sample.stateKR]);
    uint32_t limit = sample.count < 5 ? sample.count : 5;
    for (uint32_t i = 0; i < limit; i++) {
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"STACK t=%us #%u %@",
                            seconds,
                            i,
                            LCTVMVP8CompactAddress(sample.addresses[i])]);
    }
}

static NSInteger LCTVMVP8ScoreThreadSample(LCTVMVP8StackSample sample,
                                           thread_basic_info_data_t basic) {
    NSInteger score = 0;
    if (basic.run_state == TH_STATE_RUNNING) score += 40;
    else if (basic.run_state == TH_STATE_WAITING) score += 5;
    score += MIN((NSInteger)(basic.cpu_usage / 10), 30);

    for (uint32_t i = 0; i < sample.count; i++) {
        NSString *path = LCTVMVP8ImagePathForAddress(sample.addresses[i]);
        if (!path.length) continue;
        NSString *lower = path.lowercaseString;
        if ([lower containsString:@"com.firecore.infuse.code.framework"]) score += 180;
        else if ([lower containsString:@"infuse"]) score += 140;
        else if ([lower containsString:@"uikitcore"]) score += 80;
        else if ([lower containsString:@"foundation.framework"] ||
                 [lower containsString:@"corefoundation.framework"]) score += 45;
    }

    NSString *top = sample.count ? LCTVMVP8CompactAddress(sample.addresses[0]) : @"";
    if ([top containsString:@"__ulock_wait"] ||
        [top containsString:@"mach_msg"] ||
        [top containsString:@"semaphore_wait"]) {
        score -= 20;
    }
    return score;
}

static void LCTVMVP8TraceOtherThreads(thread_t mainThread, unsigned seconds) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    kern_return_t taskKR = task_threads(mach_task_self(), &threads, &threadCount);
    if (taskKR != KERN_SUCCESS || !threads) {
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"THREAD_SCAN t=%us task_threads_KR=%d",
                            seconds, taskKR]);
        return;
    }

    thread_t samplerThread = mach_thread_self();
    uint64_t samplerID = LCTVMVP8ThreadID(samplerThread);
    uint64_t mainID = LCTVMVP8ThreadID(mainThread);
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];

    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        thread_t thread = threads[i];
        uint64_t tid = LCTVMVP8ThreadID(thread);
        if ((samplerID && tid == samplerID) || (mainID && tid == mainID)) continue;

        thread_basic_info_data_t basic = {0};
        mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
        kern_return_t basicKR = thread_info(thread,
                                            THREAD_BASIC_INFO,
                                            (thread_info_t)&basic,
                                            &basicCount);
        if (basicKR != KERN_SUCCESS) continue;

        LCTVMVP8StackSample sample = LCTVMVP8SampleThread(thread);
        if (sample.stateKR != KERN_SUCCESS || sample.count == 0) continue;

        NSInteger score = LCTVMVP8ScoreThreadSample(sample, basic);
        NSMutableArray<NSString *> *frames = [NSMutableArray array];
        uint32_t frameLimit = sample.count < 3 ? sample.count : 3;
        for (uint32_t f = 0; f < frameLimit; f++) {
            [frames addObject:LCTVMVP8CompactAddress(sample.addresses[f])];
        }
        NSString *chain = [frames componentsJoinedByString:@" <- "];
        [candidates addObject:@{
            @"score": @(score),
            @"tid": @(tid),
            @"state": @(basic.run_state),
            @"cpu": @(basic.cpu_usage),
            @"chain": chain ?: @"?",
        }];
    }

    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(),
                  (vm_address_t)threads,
                  (vm_size_t)(threadCount * sizeof(thread_t)));
    mach_port_deallocate(mach_task_self(), samplerThread);

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue];
        NSInteger sb = [b[@"score"] integerValue];
        if (sa > sb) return NSOrderedAscending;
        if (sa < sb) return NSOrderedDescending;
        NSInteger ca = [a[@"cpu"] integerValue];
        NSInteger cb = [b[@"cpu"] integerValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    LCTVMVP8TraceEvent([NSString stringWithFormat:@"THREAD_SCAN t=%us threads=%u candidates=%lu",
                        seconds,
                        threadCount,
                        (unsigned long)candidates.count]);
    NSUInteger limit = MIN((NSUInteger)4, candidates.count);
    for (NSUInteger i = 0; i < limit; i++) {
        NSDictionary *candidate = candidates[i];
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"THREAD_CAND #%lu tid=%llu state=%ld cpu=%ld score=%ld %@",
                            (unsigned long)i,
                            [candidate[@"tid"] unsignedLongLongValue],
                            (long)[candidate[@"state"] integerValue],
                            (long)[candidate[@"cpu"] integerValue],
                            (long)[candidate[@"score"] integerValue],
                            candidate[@"chain"]]);
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
                    if (now == 20) LCTVMVP8TraceOtherThreads(mainThread, now);
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
