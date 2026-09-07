#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVSelectedSlotKey = @"LCTVMVP7ESelectedSlotNextLaunch";
static NSString * const LCTVResultKey = @"LCTVMVP7EResult";
static NSString * const LCTVWritableRelativeRoot = @"Library/Caches/LiveContainerTV/SplitLibrary";

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

static BOOL LCTVEnsureDirectory(NSString *path, NSString **errorOut) {
    NSError *error = nil;
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:path
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
    if (!ok && errorOut) *errorOut = error.localizedDescription;
    return ok;
}

static NSString *LCTVWritableRoot(void) {
    NSString *home = LCTVHostHome();
    if (!home.length) return nil;
    return [home stringByAppendingPathComponent:LCTVWritableRelativeRoot];
}

static BOOL LCTVIsPreparedSignedGuest(NSURL *url, NSDictionary **infoOut) {
    if (![url.pathExtension.lowercaseString isEqualToString:@"framework"]) return NO;
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    NSDictionary *info = bundle.infoDictionary;
    if (!bundle || ![info[@"LCTVPreparedGuest"] boolValue]) return NO;
    NSString *executable = LCTVString(info[@"CFBundleExecutable"]);
    if (!executable.length) return NO;
    NSString *executablePath = [url.path stringByAppendingPathComponent:executable];
    if (![NSFileManager.defaultManager fileExistsAtPath:executablePath]) return NO;
    if (infoOut) *infoOut = info;
    return YES;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *LCTVDiscoverSignedSlots(void) {
    NSURL *root = NSBundle.mainBundle.privateFrameworksURL;
    if (!root) return @[];

    NSError *error = nil;
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:&error];
    if (!entries) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *slots = [NSMutableArray array];
    for (NSURL *url in entries) {
        NSDictionary *info = nil;
        if (!LCTVIsPreparedSignedGuest(url, &info)) continue;

        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSString *executable = LCTVString(info[@"CFBundleExecutable"]);
        NSString *displayName = LCTVString(info[@"CFBundleDisplayName"]);
        if (!displayName.length) displayName = LCTVString(info[@"CFBundleName"]);
        if (!displayName.length) displayName = LCTVString(info[@"LCTVOriginalBundleName"]);
        if (!displayName.length) displayName = executable;

        NSString *bundleID = bundle.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]);
        if (!bundleID.length) bundleID = [NSString stringWithFormat:@"unknown.%@", url.lastPathComponent];

        NSMutableDictionary<NSString *, NSString *> *slot = [@{
            @"slot": url.lastPathComponent,
            @"signedBundlePath": url.path,
            @"signedExecutablePath": [url.path stringByAppendingPathComponent:executable],
            @"executable": executable,
            @"displayName": displayName,
            @"bundleID": bundleID,
        } mutableCopy];
        NSString *version = LCTVString(info[@"CFBundleShortVersionString"]);
        NSString *build = LCTVString(info[@"CFBundleVersion"]);
        if (version.length) slot[@"version"] = version;
        if (build.length) slot[@"build"] = build;
        [slots addObject:slot];
    }

    [slots sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, NSString *> *a,
                                                    NSDictionary<NSString *, NSString *> *b) {
        return [a[@"displayName"] localizedCaseInsensitiveCompare:b[@"displayName"]];
    }];
    return slots;
}

static NSString *LCTVWritableBundlePathForSlot(NSDictionary<NSString *, NSString *> *slot) {
    NSString *root = LCTVWritableRoot();
    NSString *slotName = slot[@"slot"];
    if (!root.length || !slotName.length) return nil;
    return [root stringByAppendingPathComponent:slotName];
}

static BOOL LCTVWritableMirrorNeedsRefresh(NSDictionary<NSString *, NSString *> *slot,
                                           NSString *destinationPath) {
    if (![NSFileManager.defaultManager fileExistsAtPath:destinationPath]) return YES;
    NSBundle *destination = [NSBundle bundleWithPath:destinationPath];
    NSDictionary *info = destination.infoDictionary;
    if (!destination || !info) return YES;

    NSString *bundleID = destination.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]) ?: @"";
    NSString *version = LCTVString(info[@"CFBundleShortVersionString"]) ?: @"";
    NSString *build = LCTVString(info[@"CFBundleVersion"]) ?: @"";
    return ![bundleID isEqualToString:slot[@"bundleID"] ?: @""] ||
           ![version isEqualToString:slot[@"version"] ?: @""] ||
           ![build isEqualToString:slot[@"build"] ?: @""];
}

static BOOL LCTVEnsureWritableMirror(NSDictionary<NSString *, NSString *> *slot,
                                     NSString **errorOut) {
    NSString *root = LCTVWritableRoot();
    NSString *destination = LCTVWritableBundlePathForSlot(slot);
    if (!root.length || !destination.length) {
        if (errorOut) *errorOut = @"host HOME unavailable for split library";
        return NO;
    }
    if (!LCTVEnsureDirectory(root, errorOut)) return NO;
    if (!LCTVWritableMirrorNeedsRefresh(slot, destination)) return YES;

    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![NSFileManager.defaultManager removeItemAtPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"remove old mirror %@ failed: %@", slot[@"slot"], error.localizedDescription];
        return NO;
    }

    error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:slot[@"signedBundlePath"]
                                              toPath:destination
                                               error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"copy %@ into split library failed: %@", slot[@"displayName"], error.localizedDescription];
        return NO;
    }
    return YES;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *LCTVBuildSplitCatalog(NSString **errorOut) {
    NSArray<NSDictionary<NSString *, NSString *> *> *signedSlots = LCTVDiscoverSignedSlots();
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *catalog = [NSMutableArray array];

    for (NSDictionary<NSString *, NSString *> *slot in signedSlots) {
        NSString *mirrorError = nil;
        if (!LCTVEnsureWritableMirror(slot, &mirrorError)) {
            if (errorOut) *errorOut = [NSString stringWithFormat:@"%@ mirror failed: %@", slot[@"displayName"], mirrorError ?: @"unknown"];
            continue;
        }
        NSMutableDictionary<NSString *, NSString *> *entry = [slot mutableCopy];
        entry[@"writableBundlePath"] = LCTVWritableBundlePathForSlot(slot);
        [catalog addObject:entry];
    }
    return catalog;
}

static NSDictionary<NSString *, NSString *> *LCTVDescriptorForSlot(NSString *slotName) {
    if (!slotName.length) return nil;
    NSString *error = nil;
    for (NSDictionary<NSString *, NSString *> *entry in LCTVBuildSplitCatalog(&error)) {
        if ([entry[@"slot"] isEqualToString:slotName]) return entry;
    }
    return nil;
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

static int LCTVBootSplitGuest(int argc,
                              char *argv[],
                              NSDictionary<NSString *, NSString *> *descriptor) {
    if (!descriptor) {
        LCTVStoreResult(@"MVP7E FAIL: selected signed code slot was not discovered");
        return INT_MIN;
    }

    NSString *displayName = descriptor[@"displayName"] ?: descriptor[@"slot"] ?: @"guest";
    NSString *bundlePath = descriptor[@"writableBundlePath"];
    NSString *guestPath = descriptor[@"signedExecutablePath"]; // Executable code always remains in the signed app bundle.
    NSString *bundleID = descriptor[@"bundleID"];
    NSString *processName = descriptor[@"executable"];

    if (!bundlePath.length || !guestPath.length || !bundleID.length || !processName.length) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ FAIL: split descriptor incomplete", displayName]);
        return INT_MIN;
    }

    NSString *home = LCTVHostHome();
    if (!home.length) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ FAIL: HOME unavailable", displayName]);
        return INT_MIN;
    }
    NSString *safeID = [[bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *guestHome = [home stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];
    NSString *mkdirError = nil;
    if (!LCTVEnsureDirectory(guestHome, &mkdirError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ FAIL guest HOME: %@", displayName, mkdirError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ START: writable identity + signed code pre=%@",
                     displayName,
                     preOK ? @"PASS" : @"PARTIAL"]);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *raw = dlerror();
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ DLOPEN FAIL signed code: %s", displayName, raw ?: "unknown"]);
        return 1;
    }

    const struct mach_header_64 *header = LCTVLoadedHeaderForPath(guestPath);
    if (!header) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ FAIL: loaded signed image not found", displayName]);
        dlclose(handle);
        return 1;
    }

    uint64_t entryoff = 0;
    NSString *mainError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryoff, &mainError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ LC_MAIN FAIL: %@", displayName, mainError ?: @"unknown"]);
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(header, &postError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7E %@ PASS split-store pre=%@ post=%@ entryoff=0x%llx",
                     displayName,
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

static UIView *LCTVGuestCard(NSDictionary<NSString *, NSString *> *descriptor, id target) {
    NSString *displayName = descriptor[@"displayName"] ?: @"Unknown guest";
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:[NSString stringWithFormat:@"▶  %@", displayName] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    button.accessibilityIdentifier = descriptor[@"slot"];
    [button addTarget:target action:@selector(armGuest:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:820.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:72.0].active = YES;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([descriptor[@"bundleID"] length]) [parts addObject:descriptor[@"bundleID"]];
    NSString *version = descriptor[@"version"];
    NSString *build = descriptor[@"build"];
    if (version.length && build.length) [parts addObject:[NSString stringWithFormat:@"v%@ (%@)", version, build]];
    else if (version.length) [parts addObject:[NSString stringWithFormat:@"v%@", version]];
    NSUInteger nested = LCTVNestedFrameworkCount(descriptor[@"signedBundlePath"]);
    [parts addObject:[NSString stringWithFormat:@"signed code + %lu framework%@", (unsigned long)nested, nested == 1 ? @"" : @"s"]];
    [parts addObject:@"writable identity/resources"];

    UILabel *metadata = [[UILabel alloc] init];
    metadata.translatesAutoresizingMaskIntoConstraints = NO;
    metadata.text = [parts componentsJoinedByString:@"  •  "];
    metadata.textColor = UIColor.lightGrayColor;
    metadata.font = [UIFont monospacedSystemFontOfSize:17.0 weight:UIFontWeightRegular];
    metadata.textAlignment = NSTextAlignmentCenter;
    metadata.numberOfLines = 1;

    UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[button, metadata]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 2.0;
    card.alignment = UIStackViewAlignmentCenter;
    return card;
}

@interface LCTVMVP7EViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSArray<NSDictionary<NSString *, NSString *> *> *catalog;
@end

@implementation LCTVMVP7EViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    NSString *catalogError = nil;
    self.catalog = LCTVBuildSplitCatalog(&catalogError);

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7E";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:50.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Multi-App Split Library — writable identity/resources + signed executable slots";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:23.0];
    subtitle.textAlignment = NSTextAlignmentCenter;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24.0;
    stack.alignment = UIStackViewAlignmentCenter;
    [scroll addSubview:stack];

    if (self.catalog.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = catalogError.length ? [NSString stringWithFormat:@"No usable split guests: %@", catalogError] : @"No signed prepared guest slots were discovered.";
        empty.textColor = UIColor.systemOrangeColor;
        empty.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightSemibold];
        empty.numberOfLines = 0;
        empty.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:empty];
    } else {
        for (NSDictionary<NSString *, NSString *> *descriptor in self.catalog) {
            [stack addArrangedSubview:LCTVGuestCard(descriptor, self)];
        }
    }

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:LCTVResultKey];
    self.statusLabel.text = last ?: [NSString stringWithFormat:@"Ready. %lu signed code slot%@ mirrored into writable split library.",
                                     (unsigned long)self.catalog.count,
                                     self.catalog.count == 1 ? @"" : @"s"];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:scroll];
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:44.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:28.0],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:70.0],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-70.0],
        [scroll.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-22.0],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-40.0],
    ]];
}

- (void)armGuest:(UIButton *)sender {
    NSString *slotName = sender.accessibilityIdentifier;
    NSDictionary<NSString *, NSString *> *descriptor = LCTVDescriptorForSlot(slotName);
    if (!descriptor) {
        self.statusLabel.text = [NSString stringWithFormat:@"Signed slot %@ is no longer available.", slotName ?: @"unknown"];
        return;
    }

    NSString *displayName = descriptor[@"displayName"] ?: slotName;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:slotName forKey:LCTVSelectedSlotKey];
    NSString *message = [NSString stringWithFormat:@"%@ ARMED: writable identity/resources + signed code. Force-close LiveContainerTV, then reopen it.", displayName];
    [defaults setObject:message forKey:LCTVResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}

@end

@interface LCTVMVP7EAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVMVP7EAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7EViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *slotName = [defaults stringForKey:LCTVSelectedSlotKey];
        if (slotName.length) {
            [defaults removeObjectForKey:LCTVSelectedSlotKey];
            [defaults synchronize];
            NSDictionary<NSString *, NSString *> *descriptor = LCTVDescriptorForSlot(slotName);
            int result = LCTVBootSplitGuest(argc, argv, descriptor);
            if (result != INT_MIN) return result;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7EAppDelegate.class));
    }
}
