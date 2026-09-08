#import "MVP8DyldNoLock.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_prot.h>
#import <os/lock.h>
#import <stdatomic.h>

#import "../../../litehook/src/litehook.h"

// Exported by the pinned litehook submodule. This is the direct mach_vm_protect
// syscall wrapper used by upstream LiveContainer for shared-cache vtables.
extern kern_return_t litehook_vm_protect(mach_port_name_t target,
                                         mach_vm_address_t address,
                                         mach_vm_size_t size,
                                         boolean_t setMaximum,
                                         vm_prot_t protection);

typedef void (*LCTVMVP8FLockMethod)(void *helpers, void *lock, uint32_t options);
typedef void (*LCTVMVP8FUnlockMethod)(void *helpers, void *lock);
typedef void (*LCTVMVP8FRawLock)(void *lock, uint32_t options);
typedef void (*LCTVMVP8FRawUnlock)(void *lock);

static mach_port_t LCTVMVP8FTargetThread = MACH_PORT_NULL;
static void *LCTVMVP8FLockToIgnore = NULL;
static LCTVMVP8FRawLock LCTVMVP8FRealLock = NULL;
static LCTVMVP8FRawUnlock LCTVMVP8FRealUnlock = NULL;
static atomic_flag LCTVMVP8FInstallGuard = ATOMIC_FLAG_INIT;

static BOOL LCTVMVP8FIsTargetThread(void) {
    if (LCTVMVP8FTargetThread == MACH_PORT_NULL) return NO;
    mach_port_t current = mach_thread_self();
    BOOL matches = current == LCTVMVP8FTargetThread;
    mach_port_deallocate(mach_task_self(), current);
    return matches;
}

static void LCTVMVP8FLockHook(void *helpers, void *lock, uint32_t options) {
    (void)helpers;
    BOOL target = LCTVMVP8FIsTargetThread();
    if (target && !LCTVMVP8FLockToIgnore) LCTVMVP8FLockToIgnore = lock;
    if (!target || lock != LCTVMVP8FLockToIgnore) {
        LCTVMVP8FRealLock(lock, options);
    }
}

static void LCTVMVP8FUnlockHook(void *helpers, void *lock) {
    (void)helpers;
    if (!LCTVMVP8FIsTargetThread() || lock != LCTVMVP8FLockToIgnore) {
        LCTVMVP8FRealUnlock(lock);
    }
}

static NSInteger LCTVMVP8FVtableIndex(void **vtable, void *function) {
    if (!vtable || !function) return NSNotFound;
    for (NSInteger i = 0; i < 100; i++) {
        if (vtable[i] == function) return i;
    }
    return NSNotFound;
}

static BOOL LCTVMVP8FSetVtableProtection(mach_vm_address_t start,
                                         mach_vm_size_t size,
                                         vm_prot_t protection,
                                         BOOL *tproWritable,
                                         NSString **errorOut) {
    kern_return_t kr = litehook_vm_protect(mach_task_self(),
                                           start,
                                           size,
                                           false,
                                           protection);
    if (kr == KERN_SUCCESS) return YES;

    if ((protection & VM_PROT_WRITE) && os_tpro_is_supported()) {
        os_thread_self_restrict_tpro_to_rw();
        if (tproWritable) *tproWritable = YES;
        return YES;
    }

    if (errorOut) {
        *errorOut = [NSString stringWithFormat:@"vtable protection failed kr=%d prot=0x%x",
                     kr,
                     protection];
    }
    return NO;
}

void *LCTVMVP8FDlopenNoLock(const char *path, int mode, NSString **errorOut) {
    if (errorOut) *errorOut = nil;
    if (!path) {
        if (errorOut) *errorOut = @"guest path is null";
        return NULL;
    }
    if (atomic_flag_test_and_set_explicit(&LCTVMVP8FInstallGuard, memory_order_acquire)) {
        if (errorOut) *errorOut = @"another no-lock load is already active";
        return NULL;
    }

    const char *libdyldPath = "/usr/lib/system/libdyld.dylib";
    LCTVMVP8FRealLock = (LCTVMVP8FRawLock)dlsym(RTLD_DEFAULT,
                                                "os_unfair_recursive_lock_lock_with_options");
    LCTVMVP8FRealUnlock = (LCTVMVP8FRawUnlock)dlsym(RTLD_DEFAULT,
                                                    "os_unfair_recursive_lock_unlock");
    void **vtable = litehook_find_dsc_symbol(libdyldPath, "__ZTVN5dyld416LibSystemHelpersE");
    void *lockFunction = litehook_find_dsc_symbol(
        libdyldPath,
        "__ZNK5dyld416LibSystemHelpers42os_unfair_recursive_lock_lock_with_optionsEP26os_unfair_recursive_lock_s24os_unfair_lock_options_t");
    void *unlockFunction = litehook_find_dsc_symbol(
        libdyldPath,
        "__ZNK5dyld416LibSystemHelpers31os_unfair_recursive_lock_unlockEP26os_unfair_recursive_lock_s");

    NSInteger lockIndex = LCTVMVP8FVtableIndex(vtable, lockFunction);
    NSInteger unlockIndex = LCTVMVP8FVtableIndex(vtable, unlockFunction);
    if (!LCTVMVP8FRealLock || !LCTVMVP8FRealUnlock ||
        !vtable || !lockFunction || !unlockFunction ||
        lockIndex == NSNotFound || unlockIndex == NSNotFound) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:
                         @"libdyld symbols unavailable raw=%@ vtable=%@ lock=%@ unlock=%@ lockIndex=%ld unlockIndex=%ld",
                         (LCTVMVP8FRealLock && LCTVMVP8FRealUnlock) ? @"YES" : @"NO",
                         vtable ? @"YES" : @"NO",
                         lockFunction ? @"YES" : @"NO",
                         unlockFunction ? @"YES" : @"NO",
                         (long)lockIndex,
                         (long)unlockIndex];
        }
        atomic_flag_clear_explicit(&LCTVMVP8FInstallGuard, memory_order_release);
        return NULL;
    }

    void **lockSlot = vtable + lockIndex;
    void **unlockSlot = vtable + unlockIndex;
    uintptr_t first = MIN((uintptr_t)lockSlot, (uintptr_t)unlockSlot);
    uintptr_t last = MAX((uintptr_t)lockSlot, (uintptr_t)unlockSlot) + sizeof(void *);
    mach_vm_size_t pageSize = (mach_vm_size_t)vm_page_size;
    mach_vm_address_t pageStart = (mach_vm_address_t)(first & ~(pageSize - 1));
    mach_vm_size_t regionSize = (mach_vm_size_t)(((last + pageSize - 1) & ~(pageSize - 1)) - pageStart);

    BOOL tproWritable = NO;
    NSString *protectionError = nil;
    if (!LCTVMVP8FSetVtableProtection(pageStart,
                                      regionSize,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                                      &tproWritable,
                                      &protectionError)) {
        if (errorOut) *errorOut = protectionError;
        atomic_flag_clear_explicit(&LCTVMVP8FInstallGuard, memory_order_release);
        return NULL;
    }

    LCTVMVP8FLockMethod originalLock = (LCTVMVP8FLockMethod)*lockSlot;
    LCTVMVP8FUnlockMethod originalUnlock = (LCTVMVP8FUnlockMethod)*unlockSlot;
    LCTVMVP8FTargetThread = mach_thread_self();
    LCTVMVP8FLockToIgnore = NULL;
    *lockSlot = (void *)LCTVMVP8FLockHook;
    *unlockSlot = (void *)LCTVMVP8FUnlockHook;

    // Do not log, allocate Objective-C objects, or call unrelated APIs between
    // installing the wrappers and dlopen. The first target-thread lock observed
    // here must be dyld's outer API lock.
    if (tproWritable) {
        os_thread_self_restrict_tpro_to_ro();
        tproWritable = NO;
    } else {
        litehook_vm_protect(mach_task_self(), pageStart, regionSize, false, VM_PROT_READ);
    }

    void *result = dlopen(path, mode);

    // Restoration is unconditional after dlopen returns. Other threads always
    // used the real lock functions even while these two slots were patched.
    protectionError = nil;
    if (LCTVMVP8FSetVtableProtection(pageStart,
                                     regionSize,
                                     VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY,
                                     &tproWritable,
                                     &protectionError)) {
        *lockSlot = (void *)originalLock;
        *unlockSlot = (void *)originalUnlock;
        if (tproWritable) {
            os_thread_self_restrict_tpro_to_ro();
        } else {
            litehook_vm_protect(mach_task_self(), pageStart, regionSize, false, VM_PROT_READ);
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithFormat:@"CRITICAL: dlopen returned but vtable restore failed: %@",
                     protectionError ?: @"unknown"];
    }

    if (LCTVMVP8FTargetThread != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), LCTVMVP8FTargetThread);
    }
    LCTVMVP8FTargetThread = MACH_PORT_NULL;
    LCTVMVP8FLockToIgnore = NULL;
    atomic_flag_clear_explicit(&LCTVMVP8FInstallGuard, memory_order_release);
    return result;
}
