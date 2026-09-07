#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdint.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVBootUIKitGuestNextLaunchKey = @"LCTVBootUIKitGuestNextLaunch";
static NSString * const LCTVIdentityProbeModeNextLaunchKey = @"LCTVIdentityProbeModeNextLaunch";
static NSString * const LCTVBootExternalGuestNextLaunchKey = @"LCTVBootExternalGuestNextLaunch";
static NSString * const LCTVLastMVP3ResultKey = @"LCTVLastMVP3Result";

typedef int (*LCTVGuestMainFn)(int, char **);

typedef NS_ENUM(NSInteger, LCTVIdentityProbeMode) {
    LCTVIdentityProbeModeBaseline = 0,
    LCTVIdentityProbeModeNSBundle = 1,
    LCTVIdentityProbeModeCFBundle = 2,
    LCTVIdentityProbeModeExecutablePath = 3,
    LCTVIdentityProbeModeHome = 4,
    LCTVIdentityProbeModeProcessName = 5,
    LCTVIdentityProbeModeAll = 6,
    // Host applies all proven MVP4 identity hooks before guest LC_MAIN. The
    // synthetic guest only observes them; it installs no identity hooks itself.
    LCTVIdentityProbeModeHostPreMain = 7,
};

static NSString *LCTVIdentityModeName(NSInteger mode) {
    switch (mode) {
        case LCTVIdentityProbeModeBaseline: return @"MVP3 baseline";
        case LCTVIdentityProbeModeNSBundle: return @"MVP4A NSBundle";
        case LCTVIdentityProbeModeCFBundle: return @"MVP4B CFBundle";
        case LCTVIdentityProbeModeExecutablePath: return @"MVP4C executable path";
        case LCTVIdentityProbeModeHome: return @"MVP4D HOME";
        case LCTVIdentityProbeModeProcessName: return @"MVP4E processName";
        case LCTVIdentityProbeModeAll: return @"MVP4F ALL identity hooks";
        case LCTVIdentityProbeModeHostPreMain: return @"MVP5P host pre-main identity";
        default: return @"unknown identity mode";
    }
}

static NSString *LCTVFrameworkExecutablePath(NSString *frameworkName, NSString *executableName) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    NSString *relative = [NSString stringWithFormat:@"%@.framework/%@", frameworkName, executableName];
    return [[frameworksURL URLByAppendingPathComponent:relative] path];
}

static NSString *LCTVExternalGuestBundlePath(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    return [[frameworksURL URLByAppendingPathComponent:@"MVP5ExternalGuest.framework"] path];
}

static NSBundle *LCTVExternalGuestBundle(void) {
    NSString *bundlePath = LCTVExternalGuestBundlePath();
    if (!bundlePath.length) return nil;
    return [NSBundle bundleWithPath:bundlePath];
}

static NSString *LCTVExternalGuestExecutablePath(void) {
    NSBundle *bundle = LCTVExternalGuestBundle();
    NSString *executable = bundle.infoDictionary[@"CFBundleExecutable"];
    if (!bundle || !executable.length) return nil;
    return [bundle.bundlePath stringByAppendingPathComponent:executable];
}

static NSString *LCTVRunFrameworkProbe(void) {
    NSString *payloadPath = LCTVFrameworkExecutablePath(@"GuestPayload", @"GuestPayload");
    if (!payloadPath) return @"FAIL MVP0: Frameworks directory unavailable";

    dlerror();
    void *handle = dlopen(payloadPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        return [NSString stringWithFormat:@"FAIL MVP0 dlopen: %s", error ?: "unknown error"];
    }

    dlerror();
    typedef const char *(*GuestEntryFn)(void);
    GuestEntryFn guestEntry = (GuestEntryFn)dlsym(handle, "LCTVGuestEntry");
    const char *symbolError = dlerror();
    if (!guestEntry || symbolError) {
        NSString *message = [NSString stringWithFormat:@"FAIL MVP0 dlsym: %s", symbolError ?: "symbol missing"];
        dlclose(handle);
        return message;
    }

    const char *result = guestEntry();
    NSString *message = result ? [NSString stringWithUTF8String:result] : @"FAIL MVP0: guest returned NULL";
    dlclose(handle);
    return message;
}

static NSString *LCTVPatchedGuestPath(void) {
    return LCTVFrameworkExecutablePath(@"TinyGuestTV", @"TinyGuestTV");
}

static NSString *LCTVUIKitGuestPath(void) {
    return LCTVFrameworkExecutablePath(@"UIKitGuestTV", @"UIKitGuestTV");
}

static NSString *LCTVRunPatchedExecutableProbe(void) {
    NSString *guestPath = LCTVPatchedGuestPath();
    if (!guestPath) return @"FAIL MVP2A: Frameworks directory unavailable";
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        return [NSString stringWithFormat:@"FAIL MVP2A: patched guest missing at %@", guestPath];
    }

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        return [NSString stringWithFormat:@"FAIL MVP2A dlopen: %s", error ?: "unknown error"];
    }

    dlerror();
    typedef const char *(*GuestMarkerFn)(void);
    GuestMarkerFn marker = (GuestMarkerFn)dlsym(handle, "LCTVGuestMarker");
    const char *symbolError = dlerror();
    if (!marker || symbolError) {
        NSString *message = [NSString stringWithFormat:@"FAIL MVP2A dlsym: %s", symbolError ?: "symbol missing"];
        dlclose(handle);
        return message;
    }

    const char *result = marker();
    NSString *guestResult = result ? [NSString stringWithUTF8String:result] : @"guest returned NULL";
    NSString *message = [NSString stringWithFormat:@"PASS MVP2A: patched MH_EXECUTE loaded as MH_DYLIB (%@)", guestResult];
    dlclose(handle);
    return message;
}

static BOOL LCTVFindLCMainEntryOffset(const struct mach_header_64 *header,
                                      uint64_t *entryOffsetOut,
                                      NSString **errorOut) {
    if (!header || header->magic != MH_MAGIC_64) {
        if (errorOut) *errorOut = @"loaded image does not have an ARM64 Mach-O 64 header";
        return NO;
    }
    if (header->filetype != MH_DYLIB) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"loaded image is not MH_DYLIB (filetype=%u)", header->filetype];
        return NO;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > end) {
            if (errorOut) *errorOut = @"load-command table truncated";
            return NO;
        }
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > end) {
            if (errorOut) *errorOut = @"invalid Mach-O load-command size";
            return NO;
        }
        if (command->cmd == LC_MAIN) {
            if (command->cmdsize < sizeof(struct entry_point_command)) {
                if (errorOut) *errorOut = @"LC_MAIN is smaller than entry_point_command";
                return NO;
            }
            const struct entry_point_command *entry = (const struct entry_point_command *)command;
            if (entryOffsetOut) *entryOffsetOut = entry->entryoff;
            return YES;
        }
        cursor += command->cmdsize;
    }
    if (errorOut) *errorOut = @"LC_MAIN not found in loaded guest";
    return NO;
}

static LCTVGuestMainFn LCTVMainForHeader(const struct mach_header_64 *header,
                                         uint64_t *entryOffsetOut,
                                         NSString **errorOut) {
    uint64_t entryOffset = 0;
    NSString *parseError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryOffset, &parseError)) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Mach-O parse failed: %@", parseError ?: @"unknown error"];
        return NULL;
    }
    if (entryOffset > UINTPTR_MAX - (uintptr_t)header) {
        if (errorOut) *errorOut = @"LC_MAIN entry offset overflows address space";
        return NULL;
    }
    if (entryOffsetOut) *entryOffsetOut = entryOffset;
    return (LCTVGuestMainFn)((uintptr_t)header + (uintptr_t)entryOffset);
}

static LCTVGuestMainFn LCTVResolveGuestMain(void *handle,
                                            const char *markerName,
                                            uint64_t *entryOffsetOut,
                                            NSString **errorOut) {
    dlerror();
    void *marker = dlsym(handle, markerName);
    const char *symbolError = dlerror();
    if (!marker || symbolError) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"marker lookup failed: %s", symbolError ?: "symbol missing"];
        return NULL;
    }

    Dl_info imageInfo = {0};
    if (dladdr(marker, &imageInfo) == 0 || !imageInfo.dli_fbase) {
        if (errorOut) *errorOut = @"dladdr could not resolve loaded guest image base";
        return NULL;
    }
    return LCTVMainForHeader((const struct mach_header_64 *)imageInfo.dli_fbase, entryOffsetOut, errorOut);
}

static const struct mach_header_64 *LCTVFindLoadedImageHeaderForPath(NSString *guestPath) {
    NSString *target = [[guestPath stringByStandardizingPath] stringByResolvingSymlinksInPath];
    const char *targetFS = target.fileSystemRepresentation;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *imageName = _dyld_get_image_name(i);
        const struct mach_header *rawHeader = _dyld_get_image_header(i);
        if (!imageName || !rawHeader) continue;
        NSString *candidate = [[[NSString stringWithUTF8String:imageName] stringByStandardizingPath] stringByResolvingSymlinksInPath];
        if ([candidate isEqualToString:target] || strcmp(imageName, targetFS) == 0) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)rawHeader;
            return header->magic == MH_MAGIC_64 ? header : NULL;
        }
    }
    return NULL;
}

static LCTVGuestMainFn LCTVResolveGuestMainForPath(NSString *guestPath,
                                                   const struct mach_header_64 **headerOut,
                                                   uint64_t *entryOffsetOut,
                                                   NSString **errorOut) {
    const struct mach_header_64 *header = LCTVFindLoadedImageHeaderForPath(guestPath);
    if (!header) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"loaded image not found in dyld list: %@", guestPath];
        return NULL;
    }
    LCTVGuestMainFn mainFn = LCTVMainForHeader(header, entryOffsetOut, errorOut);
    if (mainFn && headerOut) *headerOut = header;
    return mainFn;
}

static NSString *LCTVRunLCMainProbe(void) {
    NSString *guestPath = LCTVPatchedGuestPath();
    if (!guestPath) return @"FAIL MVP2B: Frameworks directory unavailable";
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        return [NSString stringWithFormat:@"FAIL MVP2B: patched guest missing at %@", guestPath];
    }

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        return [NSString stringWithFormat:@"FAIL MVP2B dlopen: %s", error ?: "unknown error"];
    }

    uint64_t entryOffset = 0;
    NSString *resolveError = nil;
    LCTVGuestMainFn guestMain = LCTVResolveGuestMain(handle, "LCTVGuestMarker", &entryOffset, &resolveError);
    if (!guestMain) {
        dlclose(handle);
        return [NSString stringWithFormat:@"FAIL MVP2B: %@", resolveError ?: @"entry point resolution failed"];
    }

    int guestReturn = guestMain(0, NULL);
    NSString *message = guestReturn == 4242
        ? [NSString stringWithFormat:@"PASS MVP2B: LC_MAIN executed (return=%d, entryoff=0x%llx)", guestReturn, (unsigned long long)entryOffset]
        : [NSString stringWithFormat:@"FAIL MVP2B: LC_MAIN returned %d, expected 4242 (entryoff=0x%llx)", guestReturn, (unsigned long long)entryOffset];
    dlclose(handle);
    return message;
}

static int LCTVBootUIKitGuestColdStart(int argc, char *argv[], NSInteger identityMode, NSString **errorOut) {
    NSString *guestPath = LCTVUIKitGuestPath();
    if (!guestPath) {
        if (errorOut) *errorOut = @"Frameworks directory unavailable";
        return INT_MIN;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"patched UIKit guest missing at %@", guestPath];
        return INT_MIN;
    }

    NSString *guestBundlePath = guestPath.stringByDeletingLastPathComponent;
    NSBundle *guestBundleBeforeHooks = [NSBundle bundleWithPath:guestBundlePath];
    NSString *guestBundleID = guestBundleBeforeHooks.bundleIdentifier ?: @"dev.livecontainertv.uikitguest.patched";
    NSString *guestProcessName = guestBundleBeforeHooks.infoDictionary[@"CFBundleExecutable"] ?: @"UIKitGuestTV";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    NSString *hostPreMainHome = nil;
    BOOL hostPreMainPreOK = YES;
    if (identityMode == LCTVIdentityProbeModeHostPreMain) {
        const char *hostHomeCString = getenv("HOME");
        if (!hostHomeCString) {
            if (errorOut) *errorOut = @"host HOME unavailable before MVP5P bootstrap";
            return INT_MIN;
        }
        NSString *hostHome = [NSString stringWithUTF8String:hostHomeCString];
        hostPreMainHome = [hostHome stringByAppendingPathComponent:@"Library/Caches/LiveContainerTV/Guests/UIKitGuestTVHostBootstrap/Data"];

        setenv("LCTV_HOST_PREMAIN_PROBE", "1", 1);
        setenv("LCTV_HOST_EXPECTED_BUNDLE_ID", guestBundleID.UTF8String, 1);
        setenv("LCTV_HOST_EXPECTED_EXEC_PATH", guestPath.fileSystemRepresentation, 1);
        setenv("LCTV_HOST_EXPECTED_HOME", hostPreMainHome.fileSystemRepresentation, 1);
        setenv("LCTV_HOST_EXPECTED_PROCESS", guestProcessName.UTF8String, 1);

        [defaults setObject:@"MVP5P STARTED: applying host identity before guest dlopen"
                      forKey:LCTVLastMVP3ResultKey];
        [defaults synchronize];

        NSString *preError = nil;
        hostPreMainPreOK = LCTVPrepareHostGuestIdentityBeforeLoad(guestBundlePath,
                                                                  guestPath,
                                                                  guestBundleID,
                                                                  guestProcessName,
                                                                  hostPreMainHome,
                                                                  &preError);
        if (preError.length) setenv("LCTV_HOST_PRELOAD_ERROR", preError.UTF8String, 1);
    }

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *error = dlerror();
        if (errorOut) *errorOut = [NSString stringWithFormat:@"dlopen failed: %s", error ?: "unknown error"];
        // In MVP5P the host identity is already mutated. Exit the one-shot
        // process instead of trying to start the host UIApplicationMain under it.
        return identityMode == LCTVIdentityProbeModeHostPreMain ? 1 : INT_MIN;
    }

    dlerror();
    typedef const char *(*GuestMarkerFn)(void);
    GuestMarkerFn markerFn = (GuestMarkerFn)dlsym(handle, "LCTVUIKitGuestMarker");
    const char *markerError = dlerror();
    if (!markerFn || markerError) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"UIKit guest marker lookup failed: %s", markerError ?: "symbol missing"];
        dlclose(handle);
        return identityMode == LCTVIdentityProbeModeHostPreMain ? 1 : INT_MIN;
    }
    const char *markerResult = markerFn();
    if (!markerResult || strcmp(markerResult, "UIKitGuestTV/tvOS") != 0) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"unexpected UIKit guest marker: %s", markerResult ?: "NULL"];
        dlclose(handle);
        return identityMode == LCTVIdentityProbeModeHostPreMain ? 1 : INT_MIN;
    }

    dlerror();
    typedef void (*SetIdentityModeFn)(int);
    SetIdentityModeFn setIdentityMode = (SetIdentityModeFn)dlsym(handle, "LCTVSetIdentityProbeMode");
    const char *modeError = dlerror();
    if (!setIdentityMode || modeError) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"identity mode setter lookup failed: %s", modeError ?: "symbol missing"];
        dlclose(handle);
        return identityMode == LCTVIdentityProbeModeHostPreMain ? 1 : INT_MIN;
    }

    const struct mach_header_64 *guestHeader = NULL;
    uint64_t entryOffset = 0;
    NSString *resolveError = nil;
    LCTVGuestMainFn guestMain = NULL;
    if (identityMode == LCTVIdentityProbeModeHostPreMain) {
        // This path deliberately does not depend on a synthetic exported marker
        // to resolve LC_MAIN. MVP5 real apps will not export LiveContainer symbols.
        guestMain = LCTVResolveGuestMainForPath(guestPath, &guestHeader, &entryOffset, &resolveError);
        setIdentityMode((int)LCTVIdentityProbeModeBaseline);
    } else {
        guestMain = LCTVResolveGuestMain(handle, "LCTVUIKitGuestMarker", &entryOffset, &resolveError);
        setIdentityMode((int)identityMode);
    }
    if (!guestMain) {
        if (errorOut) *errorOut = resolveError ?: @"entry point resolution failed";
        dlclose(handle);
        return identityMode == LCTVIdentityProbeModeHostPreMain ? 1 : INT_MIN;
    }

    if (identityMode == LCTVIdentityProbeModeHostPreMain) {
        NSString *postError = nil;
        BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(guestHeader, &postError);
        setenv("LCTV_HOST_PREMAIN_PRE_OK", hostPreMainPreOK ? "1" : "0", 1);
        setenv("LCTV_HOST_PREMAIN_POST_OK", postOK ? "1" : "0", 1);
        if (postError.length) setenv("LCTV_HOST_POSTLOAD_ERROR", postError.UTF8String, 1);
        // Continue even after a partial hook setup. The observation-only guest
        // renders a red screen with the exact identity snapshot.
    } else {
        [defaults setObject:[NSString stringWithFormat:@"%@ STARTED: jumping to guest LC_MAIN (entryoff=0x%llx)",
                             LCTVIdentityModeName(identityMode),
                             (unsigned long long)entryOffset]
                      forKey:LCTVLastMVP3ResultKey];
        [defaults synchronize];
    }

    int result = guestMain(argc, argv);
    dlclose(handle);
    return result;
}

static int LCTVBootExternalGuestColdStart(int argc, char *argv[], NSString **errorOut) {
    NSBundle *guestBundle = LCTVExternalGuestBundle();
    NSString *guestPath = LCTVExternalGuestExecutablePath();
    if (!guestBundle || !guestPath.length) {
        if (errorOut) *errorOut = @"MVP5ExternalGuest.framework is not staged in the host IPA";
        return INT_MIN;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"external guest executable missing at %@", guestPath];
        return INT_MIN;
    }

    NSString *bundleID = guestBundle.bundleIdentifier ?: @"mvp5.external.guest";
    NSString *processName = guestBundle.infoDictionary[@"CFBundleExecutable"] ?: guestPath.lastPathComponent;
    NSString *bundlePath = guestBundle.bundlePath;

    const char *hostHomeCString = getenv("HOME");
    if (!hostHomeCString) {
        if (errorOut) *errorOut = @"host HOME unavailable before external bootstrap";
        return INT_MIN;
    }
    NSString *hostHome = [NSString stringWithUTF8String:hostHomeCString];
    NSString *safeID = [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *guestHome = [hostHome stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:[NSString stringWithFormat:@"MVP5C STARTED: applying host identity before dlopen (%@)", processName]
                  forKey:LCTVLastMVP3ResultKey];
    [defaults synchronize];

    unsetenv("LCTV_HOST_PREMAIN_PROBE");
    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);
    setenv("LCTV_MVP5_EXTERNAL_PRE_OK", preOK ? "1" : "0", 1);
    if (preError.length) setenv("LCTV_MVP5_EXTERNAL_PRE_ERROR", preError.UTF8String, 1);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *error = dlerror();
        if (errorOut) *errorOut = [NSString stringWithFormat:@"external dlopen failed: %s", error ?: "unknown error"];
        // Host identity has already been changed. Terminate this one-shot launch
        // rather than starting the host UI under the guest identity.
        return 1;
    }

    const struct mach_header_64 *guestHeader = NULL;
    uint64_t entryOffset = 0;
    NSString *resolveError = nil;
    LCTVGuestMainFn guestMain = LCTVResolveGuestMainForPath(guestPath, &guestHeader, &entryOffset, &resolveError);
    if (!guestMain) {
        if (errorOut) *errorOut = resolveError ?: @"external LC_MAIN resolution failed";
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(guestHeader, &postError);
    setenv("LCTV_MVP5_EXTERNAL_POST_OK", postOK ? "1" : "0", 1);
    if (postError.length) setenv("LCTV_MVP5_EXTERNAL_POST_ERROR", postError.UTF8String, 1);

    if (argc > 0 && argv) argv[0] = (char *)guestPath.fileSystemRepresentation;
    int result = guestMain(argc, argv);
    dlclose(handle);
    return result;
}

static UIButton *LCTVButton(NSString *title, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:21.0];
    [button addTarget:target action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:650].active = YES;
    return button;
}

@interface LCTVViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation LCTVViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:46.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"One-build hardware suite — loader + isolated identity virtualization";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:22.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIButton *frameworkButton = LCTVButton(@"MVP0: normal framework", self, @selector(runFrameworkProbe:));
    UIButton *patchedButton = LCTVButton(@"MVP2A: patched tvOS executable", self, @selector(runPatchedProbe:));
    UIButton *entryButton = LCTVButton(@"MVP2B: execute LC_MAIN", self, @selector(runLCMainProbe:));
    UIButton *baselineButton = LCTVButton(@"MVP3: baseline UIKit guest", self, @selector(armBaseline:));
    UIButton *hostPreMainButton = LCTVButton(@"MVP5P: host pre-main identity", self, @selector(armHostPreMain:));
    UIButton *externalButton = LCTVButton(@"MVP5C: external tvOS app", self, @selector(armExternalGuest:));
    externalButton.enabled = LCTVExternalGuestBundle() != nil;

    UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[frameworkButton, patchedButton, entryButton, baselineButton, hostPreMainButton, externalButton]];
    left.axis = UILayoutConstraintAxisVertical;
    left.spacing = 12.0;
    left.alignment = UIStackViewAlignmentCenter;

    UIButton *nsBundleButton = LCTVButton(@"MVP4A: NSBundle.mainBundle", self, @selector(armNSBundle:));
    UIButton *cfBundleButton = LCTVButton(@"MVP4B: CFBundleGetMainBundle", self, @selector(armCFBundle:));
    UIButton *execButton = LCTVButton(@"MVP4C: _NSGetExecutablePath", self, @selector(armExecutablePath:));
    UIButton *homeButton = LCTVButton(@"MVP4D: HOME + NSHomeDirectory", self, @selector(armHome:));
    UIButton *processButton = LCTVButton(@"MVP4E: processName", self, @selector(armProcessName:));
    UIButton *allButton = LCTVButton(@"MVP4F: ALL identity hooks", self, @selector(armAll:));

    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[nsBundleButton, cfBundleButton, execButton, homeButton, processButton, allButton]];
    right.axis = UILayoutConstraintAxisVertical;
    right.spacing = 12.0;
    right.alignment = UIStackViewAlignmentCenter;

    UIStackView *columns = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    columns.axis = UILayoutConstraintAxisHorizontal;
    columns.spacing = 44.0;
    columns.alignment = UIStackViewAlignmentCenter;
    columns.distribution = UIStackViewDistributionFillEqually;
    [self.view addSubview:columns];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *lastResult = [NSUserDefaults.standardUserDefaults stringForKey:LCTVLastMVP3ResultKey];
    self.statusLabel.text = lastResult ?: @"Ready — arm one cold-start identity probe at a time.";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [columns.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [columns.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-10],
        [columns.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:70],
        [columns.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-70],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:80],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-80],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24]
    ]];
}

- (void)runFrameworkProbe:(id)sender { (void)sender; self.statusLabel.text = LCTVRunFrameworkProbe(); }
- (void)runPatchedProbe:(id)sender { (void)sender; self.statusLabel.text = LCTVRunPatchedExecutableProbe(); }
- (void)runLCMainProbe:(id)sender { (void)sender; self.statusLabel.text = LCTVRunLCMainProbe(); }

- (void)armMode:(LCTVIdentityProbeMode)mode {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:LCTVBootExternalGuestNextLaunchKey];
    [defaults setBool:YES forKey:LCTVBootUIKitGuestNextLaunchKey];
    [defaults setInteger:mode forKey:LCTVIdentityProbeModeNextLaunchKey];
    NSString *message = [NSString stringWithFormat:@"%@ ARMED: force-close LiveContainerTV, then reopen it. This mode is one-shot.", LCTVIdentityModeName(mode)];
    [defaults setObject:message forKey:LCTVLastMVP3ResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}

- (void)armBaseline:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeBaseline]; }
- (void)armNSBundle:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeNSBundle]; }
- (void)armCFBundle:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeCFBundle]; }
- (void)armExecutablePath:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeExecutablePath]; }
- (void)armHome:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeHome]; }
- (void)armProcessName:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeProcessName]; }
- (void)armAll:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeAll]; }
- (void)armHostPreMain:(id)sender { (void)sender; [self armMode:LCTVIdentityProbeModeHostPreMain]; }
- (void)armExternalGuest:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:LCTVBootUIKitGuestNextLaunchKey];
    [defaults removeObjectForKey:LCTVIdentityProbeModeNextLaunchKey];
    [defaults setBool:YES forKey:LCTVBootExternalGuestNextLaunchKey];
    NSString *message = @"MVP5C EXTERNAL ARMED: force-close LiveContainerTV, then reopen it. This mode is one-shot.";
    [defaults setObject:message forKey:LCTVLastMVP3ResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}
@end

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

        if ([defaults boolForKey:LCTVBootExternalGuestNextLaunchKey]) {
            [defaults removeObjectForKey:LCTVBootExternalGuestNextLaunchKey];
            [defaults setObject:@"MVP5C STARTED: cold-start loader entered before host UIApplicationMain"
                          forKey:LCTVLastMVP3ResultKey];
            [defaults synchronize];

            NSString *bootError = nil;
            int guestResult = LCTVBootExternalGuestColdStart(argc, argv, &bootError);
            if (guestResult != INT_MIN) return guestResult;

            NSString *failure = [NSString stringWithFormat:@"FAIL MVP5C external cold-start: %@", bootError ?: @"unknown error"];
            [defaults setObject:failure forKey:LCTVLastMVP3ResultKey];
            [defaults synchronize];
        }

        if ([defaults boolForKey:LCTVBootUIKitGuestNextLaunchKey]) {
            NSInteger mode = [defaults integerForKey:LCTVIdentityProbeModeNextLaunchKey];
            [defaults removeObjectForKey:LCTVBootUIKitGuestNextLaunchKey];
            [defaults removeObjectForKey:LCTVIdentityProbeModeNextLaunchKey];
            [defaults setObject:[NSString stringWithFormat:@"%@ STARTED: cold-start loader entered before host UIApplicationMain", LCTVIdentityModeName(mode)]
                          forKey:LCTVLastMVP3ResultKey];
            [defaults synchronize];

            NSString *bootError = nil;
            int guestResult = LCTVBootUIKitGuestColdStart(argc, argv, mode, &bootError);
            if (guestResult != INT_MIN) return guestResult;

            NSString *failure = [NSString stringWithFormat:@"FAIL %@ cold-start: %@", LCTVIdentityModeName(mode), bootError ?: @"unknown error"];
            [defaults setObject:failure forKey:LCTVLastMVP3ResultKey];
            [defaults synchronize];
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
    }
}
