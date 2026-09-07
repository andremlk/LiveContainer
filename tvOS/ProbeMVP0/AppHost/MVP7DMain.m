#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVModeKey = @"LCTVMVP7DModeNextLaunch";
static NSString * const LCTVResultKey = @"LCTVMVP7DResult";
static NSString * const LCTVExpectedNuvioBundleID = @"com.pyksel.nuviotvos";

typedef int (*LCTVGuestMainFn)(int, char **);

static NSString *LCTVString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static NSString *LCTVHostHome(void) {
    const char *home = getenv("HOME");
    return home ? [NSString stringWithUTF8String:home] : nil;
}

static void LCTVStoreResult(NSString *message) {
    if (!message.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:message forKey:LCTVResultKey];
    [defaults synchronize];
}

static NSDictionary<NSString *, NSString *> *LCTVFindSignedNuvio(void) {
    NSURL *root = NSBundle.mainBundle.privateFrameworksURL;
    if (!root) return nil;

    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    for (NSURL *url in entries) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"framework"]) continue;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSDictionary *info = bundle.infoDictionary;
        if (![info[@"LCTVPreparedGuest"] boolValue]) continue;

        NSString *bundleID = bundle.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]);
        NSString *displayName = LCTVString(info[@"CFBundleDisplayName"]);
        if (!displayName.length) displayName = LCTVString(info[@"CFBundleName"]);
        BOOL looksLikeNuvio = [bundleID isEqualToString:LCTVExpectedNuvioBundleID] ||
                              [displayName.lowercaseString containsString:@"nuvio"];
        if (!looksLikeNuvio) continue;

        NSString *exe = LCTVString(info[@"CFBundleExecutable"]);
        if (!exe.length) continue;
        NSString *exePath = [url.path stringByAppendingPathComponent:exe];
        if (![NSFileManager.defaultManager fileExistsAtPath:exePath]) continue;

        NSString *version = LCTVString(info[@"CFBundleShortVersionString"]) ?: @"";
        NSString *build = LCTVString(info[@"CFBundleVersion"]) ?: @"";
        if (!displayName.length) displayName = exe;
        if (!bundleID.length) bundleID = LCTVExpectedNuvioBundleID;

        return @{
            @"bundlePath": url.path,
            @"executablePath": exePath,
            @"executable": exe,
            @"displayName": displayName,
            @"bundleID": bundleID,
            @"version": version,
            @"build": build,
        };
    }
    return nil;
}

static NSString *LCTVWritableRoot(void) {
    NSString *home = LCTVHostHome();
    if (!home.length) return nil;
    return [home stringByAppendingPathComponent:@"Library/Caches/LiveContainerTV/SplitStore"];
}

static NSString *LCTVWritableNuvioBundlePath(void) {
    NSString *root = LCTVWritableRoot();
    return root.length ? [root stringByAppendingPathComponent:@"NuvioWritable.framework"] : nil;
}

static BOOL LCTVEnsureDirectory(NSString *path, NSString **errorOut) {
    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
    if (!ok && errorOut) *errorOut = error.localizedDescription;
    return ok;
}

static BOOL LCTVWritableCopyNeedsRefresh(NSDictionary<NSString *, NSString *> *source,
                                         NSString *destinationPath) {
    if (![NSFileManager.defaultManager fileExistsAtPath:destinationPath]) return YES;
    NSBundle *destination = [NSBundle bundleWithPath:destinationPath];
    NSDictionary *info = destination.infoDictionary;
    if (!destination || !info) return YES;

    NSString *idValue = destination.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]) ?: @"";
    NSString *version = LCTVString(info[@"CFBundleShortVersionString"]) ?: @"";
    NSString *build = LCTVString(info[@"CFBundleVersion"]) ?: @"";
    return ![idValue isEqualToString:source[@"bundleID"] ?: @""] ||
           ![version isEqualToString:source[@"version"] ?: @""] ||
           ![build isEqualToString:source[@"build"] ?: @""];
}

static BOOL LCTVEnsureWritableNuvio(NSDictionary<NSString *, NSString *> *source,
                                    NSString **errorOut) {
    NSString *root = LCTVWritableRoot();
    NSString *destination = LCTVWritableNuvioBundlePath();
    if (!root.length || !destination.length) {
        if (errorOut) *errorOut = @"host HOME unavailable for split store";
        return NO;
    }
    if (!LCTVEnsureDirectory(root, errorOut)) return NO;
    if (!LCTVWritableCopyNeedsRefresh(source, destination)) return YES;

    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![NSFileManager.defaultManager removeItemAtPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"remove old writable Nuvio failed: %@", error.localizedDescription];
        return NO;
    }

    error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:source[@"bundlePath"]
                                              toPath:destination
                                               error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"copy Nuvio into split store failed: %@", error.localizedDescription];
        return NO;
    }
    return YES;
}

static NSUInteger LCTVNestedFrameworkCount(NSString *bundlePath) {
    NSString *frameworks = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:nil];
    NSUInteger count = 0;
    for (NSString *entry in entries) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"framework"]) count++;
    }
    return count;
}

static BOOL LCTVFindLCMainEntryOffset(const struct mach_header_64 *header,
                                      uint64_t *entryOffsetOut,
                                      NSString **errorOut) {
    if (!header || header->magic != MH_MAGIC_64) {
        if (errorOut) *errorOut = @"loaded image is not Mach-O 64";
        return NO;
    }
    if (header->filetype != MH_DYLIB) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"loaded image filetype=%u, expected MH_DYLIB", header->filetype];
        return NO;
    }
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > end) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > end) break;
        if (lc->cmd == LC_MAIN && lc->cmdsize >= sizeof(struct entry_point_command)) {
            const struct entry_point_command *entry = (const struct entry_point_command *)lc;
            if (entryOffsetOut) *entryOffsetOut = entry->entryoff;
            return YES;
        }
        cursor += lc->cmdsize;
    }
    if (errorOut) *errorOut = @"LC_MAIN not found";
    return NO;
}

static const struct mach_header_64 *LCTVLoadedHeaderForPath(NSString *path) {
    NSString *target = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *imageName = _dyld_get_image_name(i);
        const struct mach_header *raw = _dyld_get_image_header(i);
        if (!imageName || !raw) continue;
        NSString *candidate = [[[NSString stringWithUTF8String:imageName] stringByStandardizingPath] stringByResolvingSymlinksInPath];
        if ([candidate isEqualToString:target]) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)raw;
            return header->magic == MH_MAGIC_64 ? header : NULL;
        }
    }
    return NULL;
}

static int LCTVBootNuvio(int argc, char *argv[], NSString *mode) {
    NSDictionary<NSString *, NSString *> *source = LCTVFindSignedNuvio();
    if (!source) {
        LCTVStoreResult(@"MVP7D FAIL: signed Nuvio seed not found in app bundle");
        return INT_MIN;
    }

    NSString *copyError = nil;
    if (!LCTVEnsureWritableNuvio(source, &copyError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D FAIL split-store setup: %@", copyError ?: @"unknown"]);
        return INT_MIN;
    }

    BOOL split = [mode isEqualToString:@"split"];
    if (!split && ![mode isEqualToString:@"direct"]) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D FAIL unknown mode %@", mode ?: @"(nil)"]);
        return INT_MIN;
    }

    NSString *bundlePath = split ? LCTVWritableNuvioBundlePath() : source[@"bundlePath"];
    NSString *guestPath = source[@"executablePath"]; // Always signed app-bundle code.
    NSString *bundleID = source[@"bundleID"];
    NSString *processName = source[@"executable"];
    NSString *displayName = source[@"displayName"];

    NSString *home = LCTVHostHome();
    if (!home.length) {
        LCTVStoreResult(@"MVP7D FAIL: HOME unavailable");
        return INT_MIN;
    }
    NSString *safeID = [[bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *guestHome = [home stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];
    NSString *mkdirError = nil;
    if (!LCTVEnsureDirectory(guestHome, &mkdirError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D FAIL guest HOME: %@", mkdirError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);

    NSString *location = split ? @"WRITABLE BUNDLE + SIGNED CODE" : @"SIGNED BUNDLE CONTROL";
    LCTVStoreResult([NSString stringWithFormat:@"MVP7D %@ START %@ pre=%@", displayName, location, preOK ? @"PASS" : @"PARTIAL"]);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *raw = dlerror();
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D %@ DLOPEN FAIL [%@]: %s", displayName, location, raw ?: "unknown"]);
        return 1;
    }

    const struct mach_header_64 *header = LCTVLoadedHeaderForPath(guestPath);
    if (!header) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D %@ FAIL: loaded signed image not found", displayName]);
        dlclose(handle);
        return 1;
    }

    uint64_t entryoff = 0;
    NSString *mainError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryoff, &mainError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7D %@ LC_MAIN FAIL: %@", displayName, mainError ?: @"unknown"]);
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(header, &postError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7D %@ PASS %@ pre=%@ post=%@ entryoff=0x%llx",
                     displayName,
                     location,
                     preOK ? @"PASS" : @"PARTIAL",
                     postOK ? @"PASS" : @"PARTIAL",
                     (unsigned long long)entryoff]);

    static char argv0[PATH_MAX];
    if (argc > 0 && argv) {
        strlcpy(argv0, guestPath.fileSystemRepresentation, sizeof(argv0));
        argv[0] = argv0;
    }

    LCTVGuestMainFn guestMain = (LCTVGuestMainFn)((uintptr_t)header + (uintptr_t)entryoff);
    int result = guestMain(argc, argv);
    dlclose(handle);
    return result;
}

@interface LCTVMVP7DViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation LCTVMVP7DViewController

- (UIButton *)button:(NSString *)title mode:(NSString *)mode {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:29.0];
    button.accessibilityIdentifier = mode;
    [button addTarget:self action:@selector(arm:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:900.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:72.0].active = YES;
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    NSDictionary<NSString *, NSString *> *source = LCTVFindSignedNuvio();
    NSString *setupError = nil;
    BOOL storeOK = source && LCTVEnsureWritableNuvio(source, &setupError);
    NSUInteger signedFrameworks = source ? LCTVNestedFrameworkCount(source[@"bundlePath"]) : 0;
    NSUInteger writableFrameworks = storeOK ? LCTVNestedFrameworkCount(LCTVWritableNuvioBundlePath()) : 0;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7D";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:50.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Nuvio Split Store — writable bundle/resources + signed executable code";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:23.0];
    subtitle.textAlignment = NSTextAlignmentCenter;

    NSString *version = source[@"version"] ?: @"?";
    NSString *build = source[@"build"] ?: @"?";
    UILabel *diagnostics = [[UILabel alloc] init];
    diagnostics.translatesAutoresizingMaskIntoConstraints = NO;
    diagnostics.text = source ?
        [NSString stringWithFormat:@"Nuvio %@ (%@)  •  signed nested frameworks: %lu  •  writable copy frameworks: %lu  •  store=%@",
         version, build, (unsigned long)signedFrameworks, (unsigned long)writableFrameworks, storeOK ? @"PASS" : @"FAIL"] :
        @"Signed Nuvio guest not found.";
    diagnostics.textColor = storeOK ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    diagnostics.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    diagnostics.textAlignment = NSTextAlignmentCenter;
    diagnostics.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self button:@"A — Launch Nuvio from signed bundle (control)" mode:@"direct"],
        [self button:@"B — Launch Nuvio split-store (writable identity + signed code)" mode:@"split"],
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 22.0;
    stack.alignment = UIStackViewAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:LCTVResultKey];
    self.statusLabel.text = last ?: (storeOK ? @"Ready. Run control first, then split-store." : [NSString stringWithFormat:@"Split-store setup failed: %@", setupError ?: @"unknown"]);
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:diagnostics];
    [self.view addSubview:stack];
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [diagnostics.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [diagnostics.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:20.0],
        [diagnostics.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
        [diagnostics.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:diagnostics.bottomAnchor constant:34.0],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-38.0],
    ]];
}

- (void)arm:(UIButton *)sender {
    NSString *mode = sender.accessibilityIdentifier;
    if (!mode.length) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:LCTVModeKey];
    NSString *message = [NSString stringWithFormat:@"MVP7D %@ ARMED. Force-close LiveContainerTV, then reopen it.", mode.uppercaseString];
    [NSUserDefaults.standardUserDefaults setObject:message forKey:LCTVResultKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    self.statusLabel.text = message;
}

@end

@interface LCTVMVP7DAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVMVP7DAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7DViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *mode = [defaults stringForKey:LCTVModeKey];
        if (mode.length) {
            [defaults removeObjectForKey:LCTVModeKey];
            [defaults synchronize];
            int result = LCTVBootNuvio(argc, argv, mode);
            if (result != INT_MIN) return result;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7DAppDelegate.class));
    }
}
