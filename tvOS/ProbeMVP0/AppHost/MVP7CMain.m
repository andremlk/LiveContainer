#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVModeKey = @"LCTVMVP7CModeNextLaunch";
static NSString * const LCTVResultKey = @"LCTVMVP7CResult";

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

static NSDictionary<NSString *, NSString *> *LCTVSourceGuest(void) {
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
        NSString *exe = LCTVString(info[@"CFBundleExecutable"]);
        if (!exe.length) continue;
        NSString *exePath = [url.path stringByAppendingPathComponent:exe];
        if (![NSFileManager.defaultManager fileExistsAtPath:exePath]) continue;
        NSString *name = LCTVString(info[@"CFBundleDisplayName"]);
        if (!name.length) name = LCTVString(info[@"CFBundleName"]);
        if (!name.length) name = exe;
        NSString *bundleID = bundle.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]);
        if (!bundleID.length) bundleID = @"mvp7c.unknown.guest";
        return @{
            @"bundlePath": url.path,
            @"executablePath": exePath,
            @"executable": exe,
            @"displayName": name,
            @"bundleID": bundleID,
        };
    }
    return nil;
}

static NSString *LCTVMatrixRoot(void) {
    NSString *home = LCTVHostHome();
    if (!home.length) return nil;
    return [home stringByAppendingPathComponent:@"Library/Caches/LiveContainerTV/MVP7C"];
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

static BOOL LCTVFilesEqual(NSString *left, NSString *right) {
    NSData *a = [NSData dataWithContentsOfFile:left options:NSDataReadingMappedIfSafe error:nil];
    NSData *b = [NSData dataWithContentsOfFile:right options:NSDataReadingMappedIfSafe error:nil];
    return a && b && [a isEqualToData:b];
}

static BOOL LCTVRemoveIfExists(NSString *path, NSString **errorOut) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:path error:nil]) {
        return YES;
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
        if (errorOut) *errorOut = error.localizedDescription;
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *LCTVPrepareMode(NSString *mode, NSString **errorOut) {
    NSDictionary<NSString *, NSString *> *source = LCTVSourceGuest();
    if (!source) {
        if (errorOut) *errorOut = @"prepared Sample Guide seed not found in signed app bundle";
        return nil;
    }

    NSString *root = LCTVMatrixRoot();
    if (!root.length || !LCTVEnsureDirectory(root, errorOut)) return nil;

    NSString *sourceBundle = source[@"bundlePath"];
    NSString *sourceExe = source[@"executablePath"];
    NSString *exeName = source[@"executable"];
    NSString *bundlePath = sourceBundle;
    NSString *guestPath = sourceExe;
    NSString *logical = @"signed app bundle";
    BOOL bytesEqual = YES;

    if ([mode isEqualToString:@"symlink"]) {
        NSString *link = [root stringByAppendingPathComponent:@"SymlinkGuest.framework"];
        if (!LCTVRemoveIfExists(link, errorOut)) return nil;
        NSError *linkError = nil;
        if (![NSFileManager.defaultManager createSymbolicLinkAtPath:link
                                                withDestinationPath:sourceBundle
                                                             error:&linkError]) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"symlink creation failed: %@", linkError.localizedDescription];
            return nil;
        }
        bundlePath = link;
        guestPath = [link stringByAppendingPathComponent:exeName];
        logical = @"writable-store symlink -> signed bundle";
        bytesEqual = LCTVFilesEqual(sourceExe, guestPath);
    } else if ([mode isEqualToString:@"copy"] || [mode isEqualToString:@"hybrid"]) {
        NSString *copy = [root stringByAppendingPathComponent:@"CopiedGuest.framework"];
        if (!LCTVRemoveIfExists(copy, errorOut)) return nil;
        NSError *copyError = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:sourceBundle toPath:copy error:&copyError]) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"copy failed: %@", copyError.localizedDescription];
            return nil;
        }
        NSString *copyExe = [copy stringByAppendingPathComponent:exeName];
        bytesEqual = LCTVFilesEqual(sourceExe, copyExe);
        bundlePath = copy;
        if ([mode isEqualToString:@"copy"]) {
            guestPath = copyExe;
            logical = @"physical writable-store copy";
        } else {
            guestPath = sourceExe;
            logical = @"writable bundle identity + signed source executable";
        }
    } else if (![mode isEqualToString:@"direct"]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"unknown mode %@", mode ?: @"(nil)"];
        return nil;
    }

    return @{
        @"mode": mode,
        @"label": logical,
        @"bundlePath": bundlePath,
        @"executablePath": guestPath,
        @"sourceExecutablePath": sourceExe,
        @"displayName": source[@"displayName"],
        @"bundleID": source[@"bundleID"],
        @"executable": exeName,
        @"bytesEqual": @(bytesEqual),
        @"resolvedExecutablePath": [guestPath stringByResolvingSymlinksInPath],
    };
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

static int LCTVBootMode(int argc, char *argv[], NSString *mode) {
    NSString *prepareError = nil;
    NSDictionary<NSString *, id> *descriptor = LCTVPrepareMode(mode, &prepareError);
    if (!descriptor) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ PREP FAIL: %@", mode, prepareError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *bundlePath = descriptor[@"bundlePath"];
    NSString *guestPath = descriptor[@"executablePath"];
    NSString *bundleID = descriptor[@"bundleID"];
    NSString *processName = descriptor[@"executable"];
    NSString *label = descriptor[@"label"];
    BOOL bytesEqual = [descriptor[@"bytesEqual"] boolValue];

    NSString *home = LCTVHostHome();
    if (!home.length) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ FAIL: HOME unavailable", mode]);
        return INT_MIN;
    }
    NSString *safeID = [[bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *guestHome = [home stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];
    NSString *mkdirError = nil;
    if (!LCTVEnsureDirectory(guestHome, &mkdirError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ FAIL guest HOME: %@", mode, mkdirError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);

    LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ START %@ bytesEqual=%@ pre=%@", mode, label, bytesEqual ? @"YES" : @"NO", preOK ? @"PASS" : @"PARTIAL"]);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *raw = dlerror();
        NSString *message = [NSString stringWithFormat:@"MVP7C %@ DLOPEN FAIL [%@] bytesEqual=%@: %s", mode, label, bytesEqual ? @"YES" : @"NO", raw ?: "unknown"];
        LCTVStoreResult(message);
        return 1;
    }

    const struct mach_header_64 *header = LCTVLoadedHeaderForPath(guestPath);
    if (!header) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ FAIL: loaded image not found", mode]);
        dlclose(handle);
        return 1;
    }

    uint64_t entryoff = 0;
    NSString *mainError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryoff, &mainError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ LC_MAIN FAIL: %@", mode, mainError ?: @"unknown"]);
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(header, &postError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7C %@ PASS dlopen+LC_MAIN bytesEqual=%@ pre=%@ post=%@ entryoff=0x%llx",
                     mode,
                     bytesEqual ? @"YES" : @"NO",
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

@interface LCTVMVP7CViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation LCTVMVP7CViewController

- (UIButton *)button:(NSString *)title mode:(NSString *)mode {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:27.0];
    button.accessibilityIdentifier = mode;
    [button addTarget:self action:@selector(arm:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:900.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:68.0].active = YES;
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7C";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:50.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Code-sign / Location Matrix — Sample Guide control";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:23.0];
    subtitle.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self button:@"A — Signed app-bundle executable (control)" mode:@"direct"],
        [self button:@"B — Writable-store symlink → signed bundle" mode:@"symlink"],
        [self button:@"C — Physical copy in writable store" mode:@"copy"],
        [self button:@"D — Writable bundle identity + signed executable" mode:@"hybrid"],
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20.0;
    stack.alignment = UIStackViewAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:LCTVResultKey] ?: @"Choose one matrix case. Each case runs on the next cold launch.";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:stack];
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:32.0],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-38.0],
    ]];
}

- (void)arm:(UIButton *)sender {
    NSString *mode = sender.accessibilityIdentifier;
    if (!mode.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:mode forKey:LCTVModeKey];
    NSString *message = [NSString stringWithFormat:@"MVP7C %@ ARMED. Force-close LiveContainerTV, then reopen it.", mode.uppercaseString];
    [defaults setObject:message forKey:LCTVResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}

@end

@interface LCTVMVP7CAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVMVP7CAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7CViewController alloc] init];
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
            int result = LCTVBootMode(argc, argv, mode);
            if (result != INT_MIN) return result;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7CAppDelegate.class));
    }
}
