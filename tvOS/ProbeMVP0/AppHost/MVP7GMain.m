#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVSelectedSlotKey = @"LCTVMVP7GSelectedSlotNextLaunch";
static NSString * const LCTVResultKey = @"LCTVMVP7GResult";
static NSString * const LCTVWritableRelativeRoot = @"Library/Caches/LiveContainerTV/ImportLibrary";

typedef int (*LCTVGuestMainFn)(int, char **);

static NSString *LCTVString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static NSString *LCTVHostHome(void) {
    const char *home = getenv("HOME");
    return home ? [NSString stringWithUTF8String:home] : nil;
}

static NSString *LCTVSafeID(NSString *bundleID) {
    NSString *safe = [bundleID ?: @"unknown.guest" stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safe = [safe stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return safe;
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

static NSString *LCTVSeedPath(NSDictionary *slot) {
    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    NSString *seedName = LCTVString(slot[@"seedName"]);
    if (!resourcePath.length || !seedName.length) return nil;
    return [[resourcePath stringByAppendingPathComponent:@"GuestSeeds"] stringByAppendingPathComponent:seedName];
}

static NSString *LCTVWritableBundlePath(NSDictionary *slot) {
    NSString *home = LCTVHostHome();
    NSString *bundleID = LCTVString(slot[@"bundleID"]);
    if (!home.length || !bundleID.length) return nil;
    NSString *root = [home stringByAppendingPathComponent:LCTVWritableRelativeRoot];
    return [root stringByAppendingPathComponent:[LCTVSafeID(bundleID) stringByAppendingString:@".app"]];
}

static BOOL LCTVResourceOnlyInvariant(NSString *path, NSString *executable) {
    if (!path.length) return NO;
    if (executable.length && [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:executable]]) return NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Frameworks"]]) return NO;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
    for (NSString *entry in entries) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"dylib"]) return NO;
    }
    return YES;
}

static NSArray<NSDictionary *> *LCTVDiscoverImportedSlots(void) {
    NSURL *root = NSBundle.mainBundle.privateFrameworksURL;
    if (!root) return @[];
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    NSMutableArray<NSDictionary *> *slots = [NSMutableArray array];
    for (NSURL *url in entries ?: @[]) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"framework"]) continue;
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSDictionary *info = bundle.infoDictionary;
        if (!bundle || ![info[@"LCTVCodeSlot"] boolValue]) continue;
        NSString *executable = LCTVString(info[@"LCTVGuestExecutable"]);
        if (!executable.length) executable = LCTVString(info[@"CFBundleExecutable"]);
        NSString *bundleID = LCTVString(info[@"LCTVGuestBundleIdentifier"]);
        NSString *seedName = LCTVString(info[@"LCTVResourceSeedName"]);
        NSString *displayName = LCTVString(info[@"LCTVGuestDisplayName"]);
        NSString *executablePath = executable.length ? [url.path stringByAppendingPathComponent:executable] : nil;
        NSString *fingerprint = LCTVString(info[@"LCTVImportFingerprint"]);
        if (!bundleID.length || !seedName.length || !executable.length || !executablePath.length ||
            ![NSFileManager.defaultManager fileExistsAtPath:executablePath]) continue;
        NSDictionary *slot = @{
            @"slotName": url.lastPathComponent,
            @"slotPath": url.path,
            @"executablePath": executablePath,
            @"executable": executable,
            @"bundleID": bundleID,
            @"displayName": displayName.length ? displayName : executable,
            @"seedName": seedName,
            @"version": LCTVString(info[@"LCTVGuestVersion"]) ?: @"",
            @"build": LCTVString(info[@"LCTVGuestBuild"]) ?: @"",
            @"fingerprint": fingerprint ?: @"",
            @"sourceSHA256": LCTVString(info[@"LCTVImportSourceSHA256"]) ?: @"",
        };
        if (![NSFileManager.defaultManager fileExistsAtPath:LCTVSeedPath(slot)]) continue;
        [slots addObject:slot];
    }
    [slots sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [LCTVString(a[@"displayName"]) localizedCaseInsensitiveCompare:LCTVString(b[@"displayName"])];
    }];
    return slots;
}

static BOOL LCTVWritableNeedsRefresh(NSDictionary *slot, NSString *destination) {
    if (![NSFileManager.defaultManager fileExistsAtPath:destination]) return YES;
    NSBundle *bundle = [NSBundle bundleWithPath:destination];
    NSDictionary *info = bundle.infoDictionary;
    if (!bundle || !info || ![info[@"LCTVResourceSeed"] boolValue]) return YES;
    NSString *fingerprint = LCTVString(info[@"LCTVImportFingerprint"]) ?: @"";
    NSString *wantedFingerprint = LCTVString(slot[@"fingerprint"]) ?: @"";
    if (wantedFingerprint.length) return ![fingerprint isEqualToString:wantedFingerprint];
    NSString *bundleID = bundle.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]) ?: @"";
    NSString *version = LCTVString(info[@"CFBundleShortVersionString"]) ?: @"";
    NSString *build = LCTVString(info[@"CFBundleVersion"]) ?: @"";
    return ![bundleID isEqualToString:LCTVString(slot[@"bundleID"]) ?: @""] ||
           ![version isEqualToString:LCTVString(slot[@"version"]) ?: @""] ||
           ![build isEqualToString:LCTVString(slot[@"build"]) ?: @""];
}

static BOOL LCTVEnsureWritableResources(NSDictionary *slot, NSString **errorOut) {
    NSString *seed = LCTVSeedPath(slot);
    NSString *destination = LCTVWritableBundlePath(slot);
    NSString *executable = LCTVString(slot[@"executable"]);
    if (!seed.length || !destination.length) {
        if (errorOut) *errorOut = @"resource seed/writable destination unavailable";
        return NO;
    }
    if (!LCTVResourceOnlyInvariant(seed, executable)) {
        if (errorOut) *errorOut = @"imported resource seed contains executable code";
        return NO;
    }
    NSString *root = destination.stringByDeletingLastPathComponent;
    if (!LCTVEnsureDirectory(root, errorOut)) return NO;
    if (!LCTVWritableNeedsRefresh(slot, destination)) {
        if (!LCTVResourceOnlyInvariant(destination, executable)) {
            if (errorOut) *errorOut = @"existing writable import contains code";
            return NO;
        }
        return YES;
    }
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![NSFileManager.defaultManager removeItemAtPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"remove old writable resources failed: %@", error.localizedDescription];
        return NO;
    }
    error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:seed toPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"copy imported resources failed: %@", error.localizedDescription];
        return NO;
    }
    if (!LCTVResourceOnlyInvariant(destination, executable)) {
        if (errorOut) *errorOut = @"writable import unexpectedly contains executable code";
        return NO;
    }
    return YES;
}

static NSUInteger LCTVNestedFrameworkCount(NSString *slotPath) {
    NSString *frameworks = [slotPath stringByAppendingPathComponent:@"Frameworks"];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:nil];
    NSUInteger count = 0;
    for (NSString *entry in entries ?: @[]) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"framework"]) count++;
    }
    return count;
}

static NSArray<NSDictionary *> *LCTVBuildImportCatalog(void) {
    NSMutableArray<NSDictionary *> *catalog = [NSMutableArray array];
    for (NSDictionary *slot in LCTVDiscoverImportedSlots()) {
        NSString *error = nil;
        BOOL storeOK = LCTVEnsureWritableResources(slot, &error);
        NSMutableDictionary *entry = [slot mutableCopy];
        entry[@"storeOK"] = @(storeOK);
        entry[@"storeError"] = error ?: @"";
        entry[@"writableBundlePath"] = LCTVWritableBundlePath(slot) ?: @"";
        entry[@"frameworkCount"] = @(LCTVNestedFrameworkCount(LCTVString(slot[@"slotPath"])));
        [catalog addObject:entry];
    }
    return catalog;
}

static NSDictionary *LCTVDescriptorForSlotName(NSString *slotName) {
    for (NSDictionary *entry in LCTVBuildImportCatalog()) {
        if ([LCTVString(entry[@"slotName"]) isEqualToString:slotName]) return entry;
    }
    return nil;
}

static BOOL LCTVFindLCMainEntryOffset(const struct mach_header_64 *header, uint64_t *entryOffsetOut, NSString **errorOut) {
    if (!header || header->magic != MH_MAGIC_64 || header->filetype != MH_DYLIB) {
        if (errorOut) *errorOut = @"loaded image is not an MH_DYLIB arm64 image";
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
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
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

static int LCTVBootImportedGuest(int argc, char *argv[], NSDictionary *slot) {
    if (!slot) {
        LCTVStoreResult(@"MVP7G FAIL: selected imported slot not found");
        return INT_MIN;
    }
    NSString *displayName = LCTVString(slot[@"displayName"]) ?: @"guest";
    NSString *setupError = nil;
    if (!LCTVEnsureWritableResources(slot, &setupError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ RESOURCE PREP FAIL: %@", displayName, setupError ?: @"unknown"]);
        return INT_MIN;
    }
    NSString *bundlePath = LCTVWritableBundlePath(slot);
    NSString *guestPath = LCTVString(slot[@"executablePath"]);
    NSString *bundleID = LCTVString(slot[@"bundleID"]);
    NSString *processName = LCTVString(slot[@"executable"]);
    if (!bundlePath.length || !guestPath.length || !bundleID.length || !processName.length) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ FAIL: import descriptor incomplete", displayName]);
        return INT_MIN;
    }
    NSBundle *resourceBundle = [NSBundle bundleWithPath:bundlePath];
    if (!resourceBundle) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ FAIL: writable resource NSBundle rejected", displayName]);
        return INT_MIN;
    }

    NSString *home = LCTVHostHome();
    NSString *guestHome = [home stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", LCTVSafeID(bundleID)]];
    NSString *mkdirError = nil;
    if (!LCTVEnsureDirectory(guestHome, &mkdirError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ FAIL guest HOME: %@", displayName, mkdirError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath, guestPath, bundleID, processName, guestHome, &preError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ START imported resources + signed code pre=%@", displayName, preOK ? @"PASS" : @"PARTIAL"]);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *raw = dlerror();
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ DLOPEN FAIL signed code: %s", displayName, raw ?: "unknown"]);
        return 1;
    }
    const struct mach_header_64 *header = LCTVLoadedHeaderForPath(guestPath);
    if (!header) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ FAIL: loaded signed image not found", displayName]);
        dlclose(handle);
        return 1;
    }
    uint64_t entryoff = 0;
    NSString *mainError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryoff, &mainError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ LC_MAIN FAIL: %@", displayName, mainError ?: @"unknown"]);
        dlclose(handle);
        return 1;
    }
    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(header, &postError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7G %@ PASS importer pre=%@ post=%@ frameworks=%lu entryoff=0x%llx",
                     displayName,
                     preOK ? @"PASS" : @"PARTIAL",
                     postOK ? @"PASS" : @"PARTIAL",
                     (unsigned long)LCTVNestedFrameworkCount(LCTVString(slot[@"slotPath"])),
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

@interface LCTVMVP7GViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSArray<NSDictionary *> *catalog;
@end

@implementation LCTVMVP7GViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.catalog = LCTVBuildImportCatalog();

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7G";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:48.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Generic IPA Import Library — minimal signed code + writable resources";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:22.0];
    subtitle.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 20.0;

    for (NSDictionary *entry in self.catalog) {
        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        card.layer.cornerRadius = 14.0;

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        NSString *displayName = LCTVString(entry[@"displayName"]) ?: @"Unknown guest";
        [button setTitle:[NSString stringWithFormat:@"▶  %@", displayName] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:28.0];
        button.accessibilityIdentifier = LCTVString(entry[@"slotName"]);
        [button addTarget:self action:@selector(armGuest:) forControlEvents:UIControlEventPrimaryActionTriggered];

        UILabel *details = [[UILabel alloc] init];
        details.translatesAutoresizingMaskIntoConstraints = NO;
        BOOL storeOK = [entry[@"storeOK"] boolValue];
        details.text = [NSString stringWithFormat:@"%@  •  v%@ (%@)  •  signed main + %@ frameworks  •  writable code=NO  •  import=%@",
                        LCTVString(entry[@"bundleID"]) ?: @"unknown",
                        LCTVString(entry[@"version"]) ?: @"",
                        LCTVString(entry[@"build"]) ?: @"",
                        entry[@"frameworkCount"] ?: @0,
                        storeOK ? @"PASS" : @"FAIL"];
        details.textColor = storeOK ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
        details.font = [UIFont monospacedSystemFontOfSize:16.0 weight:UIFontWeightRegular];
        details.textAlignment = NSTextAlignmentCenter;
        details.numberOfLines = 0;

        [card addSubview:button];
        [card addSubview:details];
        [NSLayoutConstraint activateConstraints:@[
            [card.widthAnchor constraintEqualToConstant:1080.0],
            [button.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
            [button.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24.0],
            [button.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24.0],
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:64.0],
            [details.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:4.0],
            [details.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24.0],
            [details.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24.0],
            [details.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        ]];
        [stack addArrangedSubview:card];
    }

    if (self.catalog.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No imported code slots/resource seeds were discovered.";
        empty.textColor = UIColor.systemOrangeColor;
        empty.font = [UIFont monospacedSystemFontOfSize:20.0 weight:UIFontWeightRegular];
        [stack addArrangedSubview:empty];
    }

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:LCTVResultKey] ?:
        [NSString stringWithFormat:@"Ready. %lu guest(s) imported through the generic MVP7G pipeline.", (unsigned long)self.catalog.count];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:17.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:stack];
    [self.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:46.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:30.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-36.0],
    ]];
}

- (void)armGuest:(UIButton *)sender {
    NSString *slotName = sender.accessibilityIdentifier;
    if (!slotName.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:slotName forKey:LCTVSelectedSlotKey];
    NSString *message = [NSString stringWithFormat:@"MVP7G ARMED %@. Force-close LiveContainerTV, then reopen it.", sender.currentTitle ?: slotName];
    [defaults setObject:message forKey:LCTVResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}
@end

@interface LCTVMVP7GAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation LCTVMVP7GAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7GViewController alloc] init];
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
            int result = LCTVBootImportedGuest(argc, argv, LCTVDescriptorForSlotName(slotName));
            if (result != INT_MIN) return result;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7GAppDelegate.class));
    }
}
