#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVSelectedGuestNextLaunchKey = @"LCTVSelectedGuestNextLaunch";
static NSString * const LCTVLastMVP7ResultKey = @"LCTVLastMVP7Result";

typedef int (*LCTVGuestMainFn)(int, char **);

static NSString *LCTVStringValue(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *LCTVDiscoverGuestCatalog(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return @[];

    NSError *listError = nil;
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:frameworksURL
                                                           includingPropertiesForKeys:nil
                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                error:&listError];
    if (!entries) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *guests = [NSMutableArray array];
    for (NSURL *entry in entries) {
        if (![entry.pathExtension.lowercaseString isEqualToString:@"framework"]) continue;

        NSBundle *bundle = [NSBundle bundleWithURL:entry];
        NSDictionary *info = bundle.infoDictionary;
        if (!bundle || ![info[@"LCTVPreparedGuest"] boolValue]) continue;

        NSString *executable = LCTVStringValue(info[@"CFBundleExecutable"]);
        if (!executable.length) continue;
        NSString *executablePath = [entry.path stringByAppendingPathComponent:executable];
        if (![NSFileManager.defaultManager fileExistsAtPath:executablePath]) continue;

        NSString *displayName = LCTVStringValue(info[@"CFBundleDisplayName"]);
        if (!displayName.length) displayName = LCTVStringValue(info[@"CFBundleName"]);
        if (!displayName.length) displayName = LCTVStringValue(info[@"LCTVOriginalBundleName"]);
        if (!displayName.length) displayName = executable;

        NSString *bundleID = bundle.bundleIdentifier ?: LCTVStringValue(info[@"CFBundleIdentifier"]);
        if (!bundleID.length) bundleID = [NSString stringWithFormat:@"unknown.%@", entry.lastPathComponent];

        NSString *version = LCTVStringValue(info[@"CFBundleShortVersionString"]);
        NSString *build = LCTVStringValue(info[@"CFBundleVersion"]);

        NSMutableDictionary<NSString *, NSString *> *descriptor = [@{
            @"framework": entry.lastPathComponent,
            @"frameworkPath": entry.path,
            @"displayName": displayName,
            @"bundleID": bundleID,
            @"executable": executable,
            @"executablePath": executablePath,
        } mutableCopy];
        if (version.length) descriptor[@"version"] = version;
        if (build.length) descriptor[@"build"] = build;
        [guests addObject:descriptor];
    }

    [guests sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, NSString *> *left,
                                                     NSDictionary<NSString *, NSString *> *right) {
        return [left[@"displayName"] localizedCaseInsensitiveCompare:right[@"displayName"]];
    }];
    return guests;
}

static NSDictionary<NSString *, NSString *> *LCTVDescriptorForFrameworkName(NSString *frameworkName) {
    if (!frameworkName.length) return nil;
    for (NSDictionary<NSString *, NSString *> *descriptor in LCTVDiscoverGuestCatalog()) {
        if ([descriptor[@"framework"] isEqualToString:frameworkName]) return descriptor;
    }
    return nil;
}

static NSBundle *LCTVGuestBundleForDescriptor(NSDictionary<NSString *, NSString *> *descriptor) {
    NSString *frameworkPath = descriptor[@"frameworkPath"];
    return frameworkPath.length ? [NSBundle bundleWithPath:frameworkPath] : nil;
}

static BOOL LCTVFindLCMainEntryOffset(const struct mach_header_64 *header,
                                      uint64_t *entryOffsetOut,
                                      NSString **errorOut) {
    if (!header || header->magic != MH_MAGIC_64) {
        if (errorOut) *errorOut = @"loaded image is not ARM64 Mach-O 64";
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
        if (errorOut) *errorOut = parseError ?: @"LC_MAIN parse failed";
        return NULL;
    }
    if (entryOffset > UINTPTR_MAX - (uintptr_t)header) {
        if (errorOut) *errorOut = @"LC_MAIN entry offset overflows address space";
        return NULL;
    }
    if (entryOffsetOut) *entryOffsetOut = entryOffset;
    return (LCTVGuestMainFn)((uintptr_t)header + (uintptr_t)entryOffset);
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

static void LCTVStoreResult(NSUserDefaults *defaults, NSString *message) {
    if (!defaults || !message.length) return;
    [defaults setObject:message forKey:LCTVLastMVP7ResultKey];
    [defaults synchronize];
}

static int LCTVBootGuestColdStart(int argc,
                                  char *argv[],
                                  NSDictionary<NSString *, NSString *> *descriptor,
                                  NSUserDefaults *hostDefaults,
                                  NSString **errorOut) {
    NSString *displayName = descriptor[@"displayName"] ?: descriptor[@"framework"] ?: @"guest";
    NSBundle *guestBundle = LCTVGuestBundleForDescriptor(descriptor);
    NSString *guestPath = descriptor[@"executablePath"];

    if (!descriptor || !guestBundle || !guestPath.length) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest %@ is not staged in the host IPA", displayName];
        return INT_MIN;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest executable missing at %@", guestPath];
        return INT_MIN;
    }

    NSString *bundleID = descriptor[@"bundleID"] ?: guestBundle.bundleIdentifier ?: [NSString stringWithFormat:@"mvp7.%@.guest", descriptor[@"framework"] ?: @"unknown"];
    NSString *processName = descriptor[@"executable"] ?: guestPath.lastPathComponent;
    NSString *bundlePath = guestBundle.bundlePath;

    const char *hostHomeCString = getenv("HOME");
    if (!hostHomeCString) {
        if (errorOut) *errorOut = @"host HOME unavailable before guest bootstrap";
        return INT_MIN;
    }
    NSString *hostHome = [NSString stringWithUTF8String:hostHomeCString];
    NSString *safeID = [[bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    // Preserve the MVP6 data location so upgrading to MVP7 keeps existing guest state.
    NSString *guestHome = [hostHome stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];

    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:guestHome
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&mkdirError]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"unable to create guest HOME: %@", mkdirError.localizedDescription];
        return INT_MIN;
    }

    LCTVStoreResult(hostDefaults,
                    [NSString stringWithFormat:@"MVP7 %@ STARTED: applying guest identity before dlopen", displayName]);

    unsetenv("LCTV_HOST_PREMAIN_PROBE");
    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);
    setenv("LCTV_MVP7_PRE_OK", preOK ? "1" : "0", 1);
    if (preError.length) setenv("LCTV_MVP7_PRE_ERROR", preError.UTF8String, 1);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *error = dlerror();
        NSString *message = [NSString stringWithFormat:@"FAIL MVP7 %@ dlopen: %s", displayName, error ?: "unknown error"];
        LCTVStoreResult(hostDefaults, message);
        if (errorOut) *errorOut = message;
        return 1;
    }

    const struct mach_header_64 *guestHeader = NULL;
    uint64_t entryOffset = 0;
    NSString *resolveError = nil;
    LCTVGuestMainFn guestMain = LCTVResolveGuestMainForPath(guestPath, &guestHeader, &entryOffset, &resolveError);
    if (!guestMain) {
        NSString *message = [NSString stringWithFormat:@"FAIL MVP7 %@ LC_MAIN: %@", displayName, resolveError ?: @"unknown error"];
        LCTVStoreResult(hostDefaults, message);
        if (errorOut) *errorOut = message;
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(guestHeader, &postError);
    setenv("LCTV_MVP7_POST_OK", postOK ? "1" : "0", 1);
    if (postError.length) setenv("LCTV_MVP7_POST_ERROR", postError.UTF8String, 1);

    LCTVStoreResult(hostDefaults,
                    [NSString stringWithFormat:@"MVP7 %@: jumping to LC_MAIN (entryoff=0x%llx, pre=%@, post=%@)",
                     displayName,
                     (unsigned long long)entryOffset,
                     preOK ? @"PASS" : @"PARTIAL",
                     postOK ? @"PASS" : @"PARTIAL"]);

    static char guestArgv0[PATH_MAX];
    if (argc > 0 && argv && guestPath.length) {
        strlcpy(guestArgv0, guestPath.fileSystemRepresentation, sizeof(guestArgv0));
        argv[0] = guestArgv0;
    }

    int result = guestMain(argc, argv);
    dlclose(handle);
    return result;
}

static UIView *LCTVGuestCard(NSDictionary<NSString *, NSString *> *descriptor, id target) {
    NSString *displayName = descriptor[@"displayName"] ?: @"Unknown Guest";
    NSString *frameworkName = descriptor[@"framework"];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:[NSString stringWithFormat:@"▶  %@", displayName] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    button.accessibilityIdentifier = frameworkName;
    [button addTarget:target action:@selector(armGuest:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:760.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:72.0].active = YES;

    NSMutableArray<NSString *> *metadataParts = [NSMutableArray array];
    NSString *bundleID = descriptor[@"bundleID"];
    NSString *version = descriptor[@"version"];
    NSString *build = descriptor[@"build"];
    if (bundleID.length) [metadataParts addObject:bundleID];
    if (version.length && build.length) {
        [metadataParts addObject:[NSString stringWithFormat:@"v%@ (%@)", version, build]];
    } else if (version.length) {
        [metadataParts addObject:[NSString stringWithFormat:@"v%@", version]];
    } else if (build.length) {
        [metadataParts addObject:[NSString stringWithFormat:@"build %@", build]];
    }

    UILabel *metadata = [[UILabel alloc] init];
    metadata.translatesAutoresizingMaskIntoConstraints = NO;
    metadata.text = [metadataParts componentsJoinedByString:@"  •  "];
    metadata.textColor = UIColor.lightGrayColor;
    metadata.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    metadata.textAlignment = NSTextAlignmentCenter;
    metadata.numberOfLines = 1;

    UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[button, metadata]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 2.0;
    card.alignment = UIStackViewAlignmentCenter;
    return card;
}

@interface LCTVMVP7ViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSArray<NSDictionary<NSString *, NSString *> *> *catalog;
@end

@implementation LCTVMVP7ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.catalog = LCTVDiscoverGuestCatalog();

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:52.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Dynamic Guest Library — discovered from prepared bundles, no hard-coded app catalog";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:24.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24.0;
    stack.alignment = UIStackViewAlignmentCenter;
    [scroll addSubview:stack];

    if (self.catalog.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No prepared guests were discovered.";
        empty.textColor = UIColor.systemOrangeColor;
        empty.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightSemibold];
        [stack addArrangedSubview:empty];
    } else {
        for (NSDictionary<NSString *, NSString *> *descriptor in self.catalog) {
            [stack addArrangedSubview:LCTVGuestCard(descriptor, self)];
        }
    }

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:LCTVLastMVP7ResultKey];
    self.statusLabel.text = last ?: [NSString stringWithFormat:@"Ready. Discovered %lu prepared guest%@.",
                                     (unsigned long)self.catalog.count,
                                     self.catalog.count == 1 ? @"" : @"s"];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:19.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:46.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],

        [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:24.0],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:80.0],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-80.0],
        [scroll.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-24.0],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:100.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-100.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-42.0],
    ]];
}

- (void)armGuest:(UIButton *)sender {
    NSString *frameworkName = sender.accessibilityIdentifier;
    NSDictionary<NSString *, NSString *> *descriptor = LCTVDescriptorForFrameworkName(frameworkName);
    if (!descriptor) {
        self.statusLabel.text = [NSString stringWithFormat:@"Guest bundle %@ is no longer available.", frameworkName ?: @"unknown"];
        return;
    }

    NSString *displayName = descriptor[@"displayName"] ?: frameworkName;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:frameworkName forKey:LCTVSelectedGuestNextLaunchKey];
    NSString *message = [NSString stringWithFormat:@"%@ ARMED. Force-close LiveContainerTV, then reopen it. One guest runs per process.", displayName];
    [defaults setObject:message forKey:LCTVLastMVP7ResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}

@end

@interface LCTVMVP7AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVMVP7AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *frameworkName = [defaults stringForKey:LCTVSelectedGuestNextLaunchKey];

        if (frameworkName.length) {
            [defaults removeObjectForKey:LCTVSelectedGuestNextLaunchKey];
            NSDictionary<NSString *, NSString *> *descriptor = LCTVDescriptorForFrameworkName(frameworkName);
            NSString *displayName = descriptor[@"displayName"] ?: frameworkName;
            LCTVStoreResult(defaults,
                            [NSString stringWithFormat:@"MVP7 %@ STARTED: loader entered before host UIApplicationMain", displayName]);

            if (descriptor) {
                NSString *bootError = nil;
                int guestResult = LCTVBootGuestColdStart(argc, argv, descriptor, defaults, &bootError);
                if (guestResult != INT_MIN) return guestResult;

                NSString *failure = [NSString stringWithFormat:@"FAIL MVP7 %@ cold-start: %@", displayName, bootError ?: @"unknown error"];
                LCTVStoreResult(defaults, failure);
            } else {
                LCTVStoreResult(defaults,
                                [NSString stringWithFormat:@"FAIL MVP7: selected guest bundle %@ was not discovered", frameworkName]);
            }
        }

        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7AppDelegate.class));
    }
}
