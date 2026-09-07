#import "IdentityHooks.h"
#import "GuestImportRebinder.h"

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
static int (*gLCTVOriginalNSGetExecutablePath)(char *, uint32_t *) = NULL;
static NSString *(*gLCTVOriginalNSHomeDirectory)(void) = NULL;

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
    if (!frameworkPath) return nil;
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
    if (!bundle) return @"(nil)";
    CFStringRef identifier = CFBundleGetIdentifier(bundle);
    return identifier ? [(__bridge NSString *)identifier copy] : @"(nil)";
}

static NSString *LCTVCFMainBundlePath(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return @"(nil)";
    CFURLRef url = CFBundleCopyBundleURL(bundle);
    if (!url) return @"(nil)";
    NSString *path = [(__bridge NSURL *)url path] ?: @"(nil)";
    CFRelease(url);
    return path;
}

static NSString *LCTVCFProgname(void) {
    typedef const char **(*CFGetPrognameFn)(void);
    CFGetPrognameFn fn = (CFGetPrognameFn)dlsym(RTLD_DEFAULT, "_CFGetProgname");
    if (!fn) return @"(symbol unavailable)";
    const char **value = fn();
    if (!value || !*value) return @"(nil)";
    return [NSString stringWithUTF8String:*value] ?: @"(invalid UTF-8)";
}

static NSBundle *LCTVMainBundleOverride(id self, SEL _cmd) {
    if (gLCTVVirtualMainBundle) return gLCTVVirtualMainBundle;
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
    if ((instruction & 0xFF000000) != 0x37000000) return 0;
    int64_t imm14 = (int64_t)((instruction >> 5) & 0x3FFF);
    if (imm14 & 0x2000) imm14 |= ~0x3FFFLL;
    return (uint64_t)((int64_t)pc + (imm14 << 2));
}

static uint64_t LCTVAarch64EmulateAdrp(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0x9F000000) != 0x90000000) return 0;
    int32_t immHiLo = (instruction & 0xFFFFE0) >> 3;
    immHiLo |= (instruction & 0x60000000) >> 29;
    if (instruction & 0x800000) immHiLo |= 0xFFE00000;
    int64_t imm = ((int64_t)immHiLo << 12);
    return (pc & ~(0xFFFULL)) + imm;
}

static uint64_t LCTVAarch64EmulateAdrpLdr(uint32_t adrpInstruction,
                                          uint32_t ldrInstruction,
                                          uint64_t pc) {
    uint64_t adrpTarget = LCTVAarch64EmulateAdrp(adrpInstruction, pc);
    if (!adrpTarget) return 0;
    if ((adrpInstruction & 0x1F) != ((ldrInstruction >> 5) & 0x1F)) return 0;
    if ((ldrInstruction & 0xFFC00000) != 0xF9400000) return 0;
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
        if (errorOut) *errorOut = [NSString stringWithFormat:@"vm_protect failed: %d", kr];
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
        if (!branchAddress) continue;

        intptr_t distance = (intptr_t)branchAddress - (intptr_t)start;
        if (distance < -0x10000 || distance > 0x10000 || (branchAddress & 3)) continue;

        uint32_t branchInstruction = *(uint32_t *)(uintptr_t)branchAddress;
        uint64_t candidateAddress = LCTVAarch64EmulateAdrpLdr(*(pc - 1),
                                                               branchInstruction,
                                                               (uint64_t)(pc - 1));
        if (!candidateAddress || (candidateAddress & (sizeof(void *) - 1))) continue;

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

// MVP4C v2: do not mutate dyld4 internals. Rebind only UIKitGuestTV's import slot.
static int LCTVExecutablePathOverride(char *buf, uint32_t *bufsize) {
    if (!gLCTVVirtualExecutableCString) {
        return gLCTVOriginalNSGetExecutablePath ? gLCTVOriginalNSGetExecutablePath(buf, bufsize) : -1;
    }

    if (!bufsize) return -1;
    size_t required = strlen(gLCTVVirtualExecutableCString) + 1;
    if (required > UINT32_MAX) return -1;

    if (!buf || *bufsize < (uint32_t)required) {
        *bufsize = (uint32_t)required;
        return -1;
    }

    memcpy(buf, gLCTVVirtualExecutableCString, required);
    *bufsize = (uint32_t)required;
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

    NSUInteger reboundCount = 0;
    NSString *rebindError = nil;
    void *original = NULL;
    BOOL rebound = LCTVRebindGuestImport("_NSGetExecutablePath",
                                         (void *)&LCTVExecutablePathOverride,
                                         &original,
                                         &reboundCount,
                                         &rebindError);
    if (!rebound) {
        if (errorOut) *errorOut = rebindError;
        return NO;
    }
    if (!gLCTVOriginalNSGetExecutablePath && original) {
        gLCTVOriginalNSGetExecutablePath = (int (*)(char *, uint32_t *))original;
    }

    NSString *observed = LCTVCurrentExecutablePath();
    BOOL ok = [observed isEqualToString:guestExecutable];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"guest import rebound=%lu but observed %@",
                     (unsigned long)reboundCount, observed];
    }
    return ok;
}

// MVP4D v2: HOME is an environment value, while NSHomeDirectory is cached by Foundation.
// Keep HOME/CFFIXED_USER_HOME and rebind only the guest's direct NSHomeDirectory import.
static NSString *LCTVNSHomeDirectoryOverride(void) {
    if (gLCTVExpectedHomePath) return gLCTVExpectedHomePath;
    return gLCTVOriginalNSHomeDirectory ? gLCTVOriginalNSHomeDirectory() : @"/";
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

    NSUInteger reboundCount = 0;
    NSString *rebindError = nil;
    void *original = NULL;
    BOOL rebound = LCTVRebindGuestImport("NSHomeDirectory",
                                         (void *)&LCTVNSHomeDirectoryOverride,
                                         &original,
                                         &reboundCount,
                                         &rebindError);
    if (!rebound) {
        if (errorOut) *errorOut = rebindError;
        return NO;
    }
    if (!gLCTVOriginalNSHomeDirectory && original) {
        gLCTVOriginalNSHomeDirectory = (NSString *(*)(void))original;
    }

    const char *homeCString = getenv("HOME");
    NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
    BOOL ok = [home isEqualToString:guestHome] && [NSHomeDirectory() isEqualToString:guestHome];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"guest import rebound=%lu; HOME=%@ NSHomeDirectory=%@",
                     (unsigned long)reboundCount, home ?: @"(nil)", NSHomeDirectory() ?: @"(nil)"];
    }
    return ok;
}

static BOOL LCTVPrepareProcessNameOverride(NSString **errorOut) {
    NSProcessInfo.processInfo.processName = LCTVExpectedProcessName;

    typedef const char **(*CFGetPrognameFn)(void);
    CFGetPrognameFn fn = (CFGetPrognameFn)dlsym(RTLD_DEFAULT, "_CFGetProgname");
    if (fn) {
        const char **slot = fn();
        if (slot) *slot = strdup(LCTVExpectedProcessName.UTF8String);
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
        [messages addObject:ok ? @"HOME + NSHomeDirectory guest import v2 installed"
                               : [NSString stringWithFormat:@"HOME v2 setup failed: %@", error ?: @"unknown"]];
    }

    if (LCTVModeIncludes(LCTVIdentityProbeModeProcessName)) {
        NSString *error = nil;
        BOOL ok = LCTVPrepareProcessNameOverride(&error);
        gLCTVPreMainSetupOK &= ok;
        [messages addObject:ok ? @"processName pre-main setup installed"
                               : [NSString stringWithFormat:@"processName pre-main setup failed: %@", error ?: @"unknown"]];
    }

    if (messages.count) gLCTVProbeStatus = [messages componentsJoinedByString:@"; "];
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
        [messages addObject:step ? @"_NSGetExecutablePath guest import v2 installed"
                                 : [NSString stringWithFormat:@"_NSGetExecutablePath v2 failed: %@", error ?: @"unknown"]];
    }

    if (gLCTVProbeStatus.length) [messages insertObject:gLCTVProbeStatus atIndex:0];
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
        case LCTVIdentityProbeModeExecutablePath: return LCTVIdentityProbePassed() ? @"MVP4C2 PASS" : @"MVP4C2 FAIL";
        case LCTVIdentityProbeModeHome: return LCTVIdentityProbePassed() ? @"MVP4D2 PASS" : @"MVP4D2 FAIL";
        case LCTVIdentityProbeModeProcessName: return LCTVIdentityProbePassed() ? @"MVP4E PASS" : @"MVP4E FAIL";
        case LCTVIdentityProbeModeAll: return LCTVIdentityProbePassed() ? @"MVP4F2 ALL PASS" : @"MVP4F2 ALL FAIL";
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
            return @"MVP4C2: guest-scoped _NSGetExecutablePath import should report UIKitGuestTV without mutating dyld internals.";
        case LCTVIdentityProbeModeHome:
            return @"MVP4D2: HOME and the guest NSHomeDirectory import should point to the isolated guest Data directory.";
        case LCTVIdentityProbeModeProcessName:
            return @"NSProcessInfo.processName should report UIKitGuestTV.";
        case LCTVIdentityProbeModeAll:
            return @"MVP4F2: all identity hooks should identify the guest simultaneously using safe C/D import rebinding.";
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
