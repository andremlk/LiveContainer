#import "IdentityHooks.h"

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

extern const char *LCTVUIKitGuestMarker(void);

static NSString * const LCTVExpectedGuestBundleID = @"dev.livecontainertv.uikitguest.patched";
static NSString * const LCTVExpectedProcessName = @"UIKitGuestTV";

static LCTVIdentityProbeMode gLCTVProbeMode = LCTVIdentityProbeModeBaseline;
static NSBundle *gLCTVVirtualMainBundle = nil;
static IMP gLCTVOriginalMainBundleIMP = NULL;
static CFBundleRef gLCTVVirtualCFMainBundle = NULL;
static char *gLCTVVirtualExecutableCString = NULL;
static NSString *gLCTVExpectedExecutablePath = nil;
static NSString *gLCTVExpectedHomePath = nil;
static NSString *gLCTVProbeStatus = nil;
static BOOL gLCTVPreMainSetupOK = YES;

__attribute__((visibility("default")))
void LCTVSetIdentityProbeMode(int mode) {
    if (mode < LCTVIdentityProbeModeBaseline || mode > LCTVIdentityProbeModeAll) {
        gLCTVProbeMode = LCTVIdentityProbeModeBaseline;
    } else {
        gLCTVProbeMode = (LCTVIdentityProbeMode)mode;
    }
}

static BOOL LCTVModeIncludes(LCTVIdentityProbeMode mode) {
    return gLCTVProbeMode == mode || gLCTVProbeMode == LCTVIdentityProbeModeAll;
}

static NSString *LCTVGuestFrameworkPath(void) {
    Dl_info imageInfo = {0};
    if (dladdr((const void *)&LCTVUIKitGuestMarker, &imageInfo) == 0 || !imageInfo.dli_fname) {
        return nil;
    }
    NSString *imagePath = [NSString stringWithUTF8String:imageInfo.dli_fname];
    return imagePath.stringByDeletingLastPathComponent;
}

static NSBundle *LCTVGuestBundle(void) {
    NSString *frameworkPath = LCTVGuestFrameworkPath();
    if (!frameworkPath) {
        return nil;
    }
    return [NSBundle bundleWithPath:frameworkPath];
}

static NSString *LCTVGuestExecutablePath(void) {
    NSString *frameworkPath = LCTVGuestFrameworkPath();
    return frameworkPath ? [frameworkPath stringByAppendingPathComponent:@"UIKitGuestTV"] : nil;
}

static NSString *LCTVCurrentExecutablePath(void) {
    char path[PATH_MAX] = {0};
    uint32_t size = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        return [NSString stringWithUTF8String:path] ?: @"(invalid UTF-8)";
    }
    return [NSString stringWithFormat:@"(buffer too small; required=%u)", size];
}

static NSString *LCTVCFMainBundleIdentifier(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) {
        return @"(nil)";
    }
    CFStringRef identifier = CFBundleGetIdentifier(bundle);
    return identifier ? [(__bridge NSString *)identifier copy] : @"(nil)";
}

static NSString *LCTVCFMainBundlePath(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) {
        return @"(nil)";
    }
    CFURLRef url = CFBundleCopyBundleURL(bundle);
    if (!url) {
        return @"(nil)";
    }
    NSString *path = [(__bridge NSURL *)url path] ?: @"(nil)";
    CFRelease(url);
    return path;
}

static NSString *LCTVCFProgname(void) {
    typedef const char **(*CFGetPrognameFn)(void);
    CFGetPrognameFn fn = (CFGetPrognameFn)dlsym(RTLD_DEFAULT, "_CFGetProgname");
    if (!fn) {
        return @"(symbol unavailable)";
    }
    const char **value = fn();
    if (!value || !*value) {
        return @"(nil)";
    }
    return [NSString stringWithUTF8String:*value] ?: @"(invalid UTF-8)";
}

static NSBundle *LCTVMainBundleOverride(id self, SEL _cmd) {
    if (gLCTVVirtualMainBundle) {
        return gLCTVVirtualMainBundle;
    }
    if (gLCTVOriginalMainBundleIMP) {
        NSBundle *(*original)(id, SEL) = (NSBundle *(*)(id, SEL))gLCTVOriginalMainBundleIMP;
        return original(self, _cmd);
    }
    return nil;
}

static BOOL LCTVInstallNSBundleOverride(NSString **errorOut) {
    NSBundle *guestBundle = LCTVGuestBundle();
    if (!guestBundle) {
        if (errorOut) *errorOut = @"could not construct UIKitGuestTV NSBundle";
        return NO;
    }

    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    if (!method) {
        if (errorOut) *errorOut = @"+[NSBundle mainBundle] method not found";
        return NO;
    }

    gLCTVVirtualMainBundle = guestBundle;
    if (!gLCTVOriginalMainBundleIMP) {
        gLCTVOriginalMainBundleIMP = method_setImplementation(method, (IMP)LCTVMainBundleOverride);
    } else {
        method_setImplementation(method, (IMP)LCTVMainBundleOverride);
    }

    BOOL ok = [NSBundle.mainBundle.bundleIdentifier isEqualToString:LCTVExpectedGuestBundleID];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"observed %@ at %@",
                     NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
                     NSBundle.mainBundle.bundlePath ?: @"(nil)"];
    }
    return ok;
}

static uint64_t LCTVAarch64GetTbnzJumpAddress(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0xFF000000) != 0x37000000) {
        return 0;
    }
    int64_t imm14 = (int64_t)((instruction >> 5) & 0x3FFF);
    if (imm14 & 0x2000) {
        imm14 |= ~0x3FFFLL;
    }
    return (uint64_t)((int64_t)pc + (imm14 << 2));
}

static uint64_t LCTVAarch64EmulateAdrp(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0x9F000000) != 0x90000000) {
        return 0;
    }

    int32_t immHiLo = (instruction & 0xFFFFE0) >> 3;
    immHiLo |= (instruction & 0x60000000) >> 29;
    if (instruction & 0x800000) {
        immHiLo |= 0xFFE00000;
    }
    int64_t imm = ((int64_t)immHiLo << 12);
    return (pc & ~(0xFFFULL)) + imm;
}

static uint64_t LCTVAarch64EmulateAdrpLdr(uint32_t adrpInstruction,
                                          uint32_t ldrInstruction,
                                          uint64_t pc) {
    uint64_t adrpTarget = LCTVAarch64EmulateAdrp(adrpInstruction, pc);
    if (!adrpTarget) {
        return 0;
    }
    if ((adrpInstruction & 0x1F) != ((ldrInstruction >> 5) & 0x1F)) {
        return 0;
    }
    if ((ldrInstruction & 0xFFC00000) != 0xF9400000) {
        return 0;
    }
    uint32_t imm12 = ((ldrInstruction >> 10) & 0xFFF) << 3;
    return adrpTarget + (uint64_t)imm12;
}

static BOOL LCTVMakePointerWritable(void *address, NSString **errorOut) {
    vm_size_t pageSize = (vm_size_t)vm_page_size;
    vm_address_t page = (vm_address_t)((uintptr_t)address & ~((uintptr_t)pageSize - 1));
    kern_return_t kr = vm_protect(mach_task_self(),
                                  page,
                                  pageSize,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"vm_protect failed: %d", kr];
        }
        return NO;
    }
    return YES;
}

static BOOL LCTVInstallCFBundleOverride(NSString **errorOut) {
    NSBundle *guestBundle = LCTVGuestBundle();
    if (!guestBundle) {
        if (errorOut) *errorOut = @"could not construct UIKitGuestTV NSBundle";
        return NO;
    }

    if (!gLCTVVirtualCFMainBundle) {
        gLCTVVirtualCFMainBundle = CFBundleCreate(kCFAllocatorDefault,
                                                  (__bridge CFURLRef)guestBundle.bundleURL);
    }
    if (!gLCTVVirtualCFMainBundle) {
        if (errorOut) *errorOut = @"CFBundleCreate failed for UIKitGuestTV.framework";
        return NO;
    }

    CFBundleRef originalMain = CFBundleGetMainBundle();
    uint32_t *start = (uint32_t *)(uintptr_t)CFBundleGetMainBundle;
    void **mainBundleSlot = NULL;

    for (NSUInteger i = 1; i < 160; i++) {
        uint32_t *pc = start + i;
        uint64_t branchAddress = LCTVAarch64GetTbnzJumpAddress(*pc, (uint64_t)pc);
        if (!branchAddress) {
            continue;
        }

        intptr_t distance = (intptr_t)branchAddress - (intptr_t)start;
        if (distance < -0x10000 || distance > 0x10000 || (branchAddress & 3)) {
            continue;
        }

        uint32_t branchInstruction = *(uint32_t *)(uintptr_t)branchAddress;
        uint64_t candidateAddress = LCTVAarch64EmulateAdrpLdr(*(pc - 1),
                                                               branchInstruction,
                                                               (uint64_t)(pc - 1));
        if (!candidateAddress || (candidateAddress & (sizeof(void *) - 1))) {
            continue;
        }

        void **candidate = (void **)(uintptr_t)candidateAddress;
        if (*candidate == (void *)originalMain) {
            mainBundleSlot = candidate;
            break;
        }
    }

    if (!mainBundleSlot) {
        if (errorOut) *errorOut = @"could not locate CoreFoundation main-bundle storage";
        return NO;
    }

    NSString *protectError = nil;
    if (!LCTVMakePointerWritable(mainBundleSlot, &protectError)) {
        if (errorOut) *errorOut = protectError;
        return NO;
    }
    *mainBundleSlot = (void *)gLCTVVirtualCFMainBundle;

    BOOL ok = [LCTVCFMainBundleIdentifier() isEqualToString:LCTVExpectedGuestBundleID];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"CFBundleGetMainBundle still reports %@ at %@",
                     LCTVCFMainBundleIdentifier(), LCTVCFMainBundlePath()];
    }
    return ok;
}

typedef struct {
    void *gap0[2];
    char *mainExecutablePathOld;
    void *gap18;
    char *mainExecutablePath184;
    size_t mainExecutablePathLengthNewer;
} LCTVDyldConfig;

typedef struct {
    void *gap0;
    LCTVDyldConfig *dyldConfig;
} LCTVDyldAPI;

static BOOL LCTVFindDyldVtableSlot(const char *functionName,
                                   uint32_t initialOffset,
                                   void ***slotOut,
                                   NSString **errorOut) {
    uint32_t *base = (uint32_t *)dlsym(RTLD_DEFAULT, functionName);
    if (!base) {
        if (errorOut) *errorOut = @"dlsym could not resolve dyld API stub";
        return NO;
    }

    uint32_t *scanStart = base + initialOffset;
    uint32_t *adrp = NULL;
    for (NSUInteger i = 0; i < 200; i++) {
        uint32_t *cur = scanStart + i;
        if ((*cur & 0x9F000000) != 0x90000000) continue;
        if ((*(cur + 1) & 0xFFC00000) != 0xF9400000) continue;
        if ((*(cur + 2) & 0xFFC00000) != 0xF9400000) continue;
        adrp = cur;
        break;
    }

    if (!adrp) {
        if (errorOut) *errorOut = @"dyld API adrp/ldr/ldr pattern not found";
        return NO;
    }

    uint64_t gdyldAddress = LCTVAarch64EmulateAdrpLdr(*adrp, *(adrp + 1), (uint64_t)adrp);
    if (!gdyldAddress) {
        if (errorOut) *errorOut = @"could not resolve dyld4::gAPIs";
        return NO;
    }

    void **dyldObject = *(void ***)(uintptr_t)gdyldAddress;
    if (!dyldObject || !dyldObject[0]) {
        if (errorOut) *errorOut = @"dyld4::gAPIs object/vtable is null";
        return NO;
    }
    uint8_t *vtable = (uint8_t *)dyldObject[0];

    uint32_t *selectorInstruction = adrp + 6;
    void **slot = NULL;

    if ((*selectorInstruction & 0x7F800000) == 0x52800000) {
        uint32_t imm16 = (*selectorInstruction & 0x1FFFE0) >> 5;
        slot = (void **)(vtable + imm16);
    } else if ((*selectorInstruction & 0xFFE00C00) == 0xF8400C00) {
        uint32_t imm9 = (*selectorInstruction & 0x1FF000) >> 12;
        slot = (void **)(vtable + imm9);
    } else {
        uint32_t *ldr2 = adrp + 3;
        if ((*ldr2 & 0xBFC00000) != 0xB9400000) {
            if (errorOut) *errorOut = @"unsupported dyld vtable selector pattern";
            return NO;
        }
        uint32_t size = (*ldr2 & 0xC0000000) >> 30;
        uint32_t imm12 = (*ldr2 & 0x3FFC00) >> 10;
        slot = (void **)(vtable + (imm12 << size));
    }

    if (!slot || !*slot) {
        if (errorOut) *errorOut = @"resolved dyld vtable slot is null";
        return NO;
    }
    if (slotOut) *slotOut = slot;
    return YES;
}

static int LCTVExecutablePathMutationHook(LCTVDyldAPI *api, char *newPath, uint32_t *bufsize) {
    (void)bufsize;
    if (!api || !api->dyldConfig || !newPath) {
        return -1;
    }

    LCTVDyldConfig *config = api->dyldConfig;
    char **pathSlot = NULL;
    if (config->mainExecutablePathOld && config->mainExecutablePathOld[0] == '/') {
        pathSlot = &config->mainExecutablePathOld;
    } else if (config->mainExecutablePath184 && config->mainExecutablePath184[0] == '/') {
        pathSlot = &config->mainExecutablePath184;
    }
    if (!pathSlot) {
        return -2;
    }

    if (!LCTVMakePointerWritable(pathSlot, NULL)) {
        return -3;
    }
    *pathSlot = newPath;
    return 0;
}

static BOOL LCTVInstallExecutablePathOverride(NSString **errorOut) {
    NSString *guestExecutable = LCTVGuestExecutablePath();
    if (!guestExecutable) {
        if (errorOut) *errorOut = @"guest executable path unavailable";
        return NO;
    }

    free(gLCTVVirtualExecutableCString);
    gLCTVVirtualExecutableCString = strdup(guestExecutable.fileSystemRepresentation);
    gLCTVExpectedExecutablePath = guestExecutable;
    if (!gLCTVVirtualExecutableCString) {
        if (errorOut) *errorOut = @"strdup failed for guest executable path";
        return NO;
    }

    void **slot = NULL;
    NSString *findError = nil;
    if (!LCTVFindDyldVtableSlot("_NSGetExecutablePath", 2, &slot, &findError)) {
        if (errorOut) *errorOut = findError;
        return NO;
    }

    void *original = *slot;
    NSString *protectError = nil;
    if (!LCTVMakePointerWritable(slot, &protectError)) {
        if (errorOut) *errorOut = protectError;
        return NO;
    }
    *slot = (void *)&LCTVExecutablePathMutationHook;

    int mutationResult = _NSGetExecutablePath(gLCTVVirtualExecutableCString, NULL);
    *slot = original;

    if (mutationResult != 0) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"dyld path mutation hook returned %d", mutationResult];
        }
        return NO;
    }

    NSString *observed = LCTVCurrentExecutablePath();
    BOOL ok = [observed isEqualToString:guestExecutable];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"_NSGetExecutablePath still reports %@", observed];
    }
    return ok;
}

static BOOL LCTVPrepareHomeOverride(NSString **errorOut) {
    const char *hostHomeCString = getenv("HOME");
    if (!hostHomeCString) {
        if (errorOut) *errorOut = @"HOME is not set";
        return NO;
    }
    NSString *hostHome = [NSString stringWithUTF8String:hostHomeCString];
    NSString *guestHome = [hostHome stringByAppendingPathComponent:@"Library/Caches/LiveContainerTV/Guests/UIKitGuestTV/Data"];

    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:guestHome
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&mkdirError]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest HOME mkdir failed: %@", mkdirError];
        return NO;
    }

    gLCTVExpectedHomePath = guestHome;
    if (setenv("HOME", guestHome.fileSystemRepresentation, 1) != 0) {
        if (errorOut) *errorOut = @"setenv(HOME) failed";
        return NO;
    }
    if (setenv("CFFIXED_USER_HOME", guestHome.fileSystemRepresentation, 1) != 0) {
        if (errorOut) *errorOut = @"setenv(CFFIXED_USER_HOME) failed";
        return NO;
    }
    return YES;
}

static BOOL LCTVPrepareProcessNameOverride(NSString **errorOut) {
    NSProcessInfo.processInfo.processName = LCTVExpectedProcessName;

    typedef const char **(*CFGetPrognameFn)(void);
    CFGetPrognameFn fn = (CFGetPrognameFn)dlsym(RTLD_DEFAULT, "_CFGetProgname");
    if (fn) {
        const char **slot = fn();
        if (slot) {
            *slot = strdup(LCTVExpectedProcessName.UTF8String);
        }
    }

    BOOL ok = [NSProcessInfo.processInfo.processName isEqualToString:LCTVExpectedProcessName];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"NSProcessInfo still reports %@", NSProcessInfo.processInfo.processName];
    }
    return ok;
}

void LCTVPrepareIdentityBeforeUIApplicationMain(void) {
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    gLCTVPreMainSetupOK = YES;

    if (LCTVModeIncludes(LCTVIdentityProbeModeHome)) {
        NSString *error = nil;
        BOOL ok = LCTVPrepareHomeOverride(&error);
        gLCTVPreMainSetupOK &= ok;
        [messages addObject:ok ? @"HOME pre-main setup installed"
                               : [NSString stringWithFormat:@"HOME pre-main setup failed: %@", error ?: @"unknown"]];
    }

    if (LCTVModeIncludes(LCTVIdentityProbeModeProcessName)) {
        NSString *error = nil;
        BOOL ok = LCTVPrepareProcessNameOverride(&error);
        gLCTVPreMainSetupOK &= ok;
        [messages addObject:ok ? @"processName pre-main setup installed"
                               : [NSString stringWithFormat:@"processName pre-main setup failed: %@", error ?: @"unknown"]];
    }

    if (messages.count) {
        gLCTVProbeStatus = [messages componentsJoinedByString:@"; "];
    }
}

BOOL LCTVApplyIdentityAtDidFinishLaunching(void) {
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    BOOL ok = gLCTVPreMainSetupOK;

    if (LCTVModeIncludes(LCTVIdentityProbeModeNSBundle)) {
        NSString *error = nil;
        BOOL step = LCTVInstallNSBundleOverride(&error);
        ok &= step;
        [messages addObject:step ? @"NSBundle override installed"
                                 : [NSString stringWithFormat:@"NSBundle override failed: %@", error ?: @"unknown"]];
    }

    if (LCTVModeIncludes(LCTVIdentityProbeModeCFBundle)) {
        NSString *error = nil;
        BOOL step = LCTVInstallCFBundleOverride(&error);
        ok &= step;
        [messages addObject:step ? @"CFBundle override installed"
                                 : [NSString stringWithFormat:@"CFBundle override failed: %@", error ?: @"unknown"]];
    }

    if (LCTVModeIncludes(LCTVIdentityProbeModeExecutablePath)) {
        NSString *error = nil;
        BOOL step = LCTVInstallExecutablePathOverride(&error);
        ok &= step;
        [messages addObject:step ? @"_NSGetExecutablePath override installed"
                                 : [NSString stringWithFormat:@"_NSGetExecutablePath override failed: %@", error ?: @"unknown"]];
    }

    if (gLCTVProbeStatus.length) {
        [messages insertObject:gLCTVProbeStatus atIndex:0];
    }

    if (gLCTVProbeMode == LCTVIdentityProbeModeBaseline) {
        [messages addObject:@"baseline: no identity virtualization applied"];
    }

    gLCTVProbeStatus = [messages componentsJoinedByString:@"; "];
    return ok && LCTVIdentityProbePassed();
}

BOOL LCTVIdentityProbePassed(void) {
    BOOL nsBundleOK = [NSBundle.mainBundle.bundleIdentifier isEqualToString:LCTVExpectedGuestBundleID];
    BOOL cfBundleOK = [LCTVCFMainBundleIdentifier() isEqualToString:LCTVExpectedGuestBundleID];
    BOOL execOK = gLCTVExpectedExecutablePath && [LCTVCurrentExecutablePath() isEqualToString:gLCTVExpectedExecutablePath];

    const char *homeCString = getenv("HOME");
    NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
    BOOL homeOK = gLCTVExpectedHomePath && [home isEqualToString:gLCTVExpectedHomePath] &&
                  [NSHomeDirectory() isEqualToString:gLCTVExpectedHomePath];
    BOOL processOK = [NSProcessInfo.processInfo.processName isEqualToString:LCTVExpectedProcessName];

    switch (gLCTVProbeMode) {
        case LCTVIdentityProbeModeBaseline: return YES;
        case LCTVIdentityProbeModeNSBundle: return nsBundleOK;
        case LCTVIdentityProbeModeCFBundle: return cfBundleOK;
        case LCTVIdentityProbeModeExecutablePath: return execOK;
        case LCTVIdentityProbeModeHome: return homeOK;
        case LCTVIdentityProbeModeProcessName: return processOK;
        case LCTVIdentityProbeModeAll: return nsBundleOK && cfBundleOK && execOK && homeOK && processOK;
    }
    return NO;
}

NSString *LCTVIdentityProbeTitle(void) {
    switch (gLCTVProbeMode) {
        case LCTVIdentityProbeModeBaseline: return @"MVP3 PASS";
        case LCTVIdentityProbeModeNSBundle: return LCTVIdentityProbePassed() ? @"MVP4A PASS" : @"MVP4A FAIL";
        case LCTVIdentityProbeModeCFBundle: return LCTVIdentityProbePassed() ? @"MVP4B PASS" : @"MVP4B FAIL";
        case LCTVIdentityProbeModeExecutablePath: return LCTVIdentityProbePassed() ? @"MVP4C PASS" : @"MVP4C FAIL";
        case LCTVIdentityProbeModeHome: return LCTVIdentityProbePassed() ? @"MVP4D PASS" : @"MVP4D FAIL";
        case LCTVIdentityProbeModeProcessName: return LCTVIdentityProbePassed() ? @"MVP4E PASS" : @"MVP4E FAIL";
        case LCTVIdentityProbeModeAll: return LCTVIdentityProbePassed() ? @"MVP4F ALL PASS" : @"MVP4F ALL FAIL";
    }
    return @"IDENTITY PROBE";
}

NSString *LCTVIdentityProbeStatus(void) {
    return gLCTVProbeStatus ?: @"(no hook status)";
}

NSString *LCTVIdentityProbeExpectation(void) {
    switch (gLCTVProbeMode) {
        case LCTVIdentityProbeModeBaseline:
            return @"No virtualization; all identity APIs should still describe LiveContainerTV.";
        case LCTVIdentityProbeModeNSBundle:
            return @"Only NSBundle.mainBundle should point to UIKitGuestTV.framework.";
        case LCTVIdentityProbeModeCFBundle:
            return @"Only CFBundleGetMainBundle should identify UIKitGuestTV.framework.";
        case LCTVIdentityProbeModeExecutablePath:
            return @"Only _NSGetExecutablePath should report Frameworks/UIKitGuestTV.framework/UIKitGuestTV.";
        case LCTVIdentityProbeModeHome:
            return @"HOME and NSHomeDirectory should point to an isolated guest Data directory.";
        case LCTVIdentityProbeModeProcessName:
            return @"NSProcessInfo.processName should report UIKitGuestTV.";
        case LCTVIdentityProbeModeAll:
            return @"NSBundle + CFBundle + executable path + HOME + processName should all identify the guest simultaneously.";
    }
    return @"";
}

NSString *LCTVIdentitySnapshot(void) {
    NSBundle *mainBundle = NSBundle.mainBundle;
    NSString *bundleID = mainBundle.bundleIdentifier ?: @"(nil)";
    NSString *bundlePath = mainBundle.bundlePath ?: @"(nil)";
    NSString *cfBundleID = LCTVCFMainBundleIdentifier();
    NSString *cfBundlePath = LCTVCFMainBundlePath();
    NSString *executablePath = LCTVCurrentExecutablePath();
    const char *homeEnv = getenv("HOME");
    NSString *home = homeEnv ? ([NSString stringWithUTF8String:homeEnv] ?: @"(invalid UTF-8)") : @"(unset)";
    NSString *nsHome = NSHomeDirectory() ?: @"(nil)";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"(nil)";
    NSString *cfProgname = LCTVCFProgname();

    return [NSString stringWithFormat:
            @"NSBundle.mainBundle.bundleID=%@\n"
             "NSBundle.mainBundle.bundlePath=%@\n"
             "CFBundleGetMainBundle.bundleID=%@\n"
             "CFBundleGetMainBundle.bundlePath=%@\n"
             "_NSGetExecutablePath=%@\n"
             "HOME=%@\n"
             "NSHomeDirectory=%@\n"
             "processName=%@\n"
             "_CFGetProgname=%@",
            bundleID,
            bundlePath,
            cfBundleID,
            cfBundlePath,
            executablePath,
            home,
            nsHome,
            processName,
            cfProgname];
}
