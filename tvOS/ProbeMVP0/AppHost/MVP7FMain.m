#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "GuestRuntime.h"

static NSString * const LCTVBootKey = @"LCTVMVP7FBootNextLaunch";
static NSString * const LCTVResultKey = @"LCTVMVP7FResult";
static NSString * const LCTVWritableRelativeRoot = @"Library/Caches/LiveContainerTV/MinimalSplit";

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

static NSDictionary<NSString *, NSString *> *LCTVFindCodeSlot(void) {
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
        if (![info[@"LCTVCodeSlot"] boolValue]) continue;
        NSString *executable = LCTVString(info[@"LCTVGuestExecutable"]);
        if (!executable.length) executable = LCTVString(info[@"CFBundleExecutable"]);
        NSString *guestID = LCTVString(info[@"LCTVGuestBundleIdentifier"]);
        NSString *displayName = LCTVString(info[@"LCTVGuestDisplayName"]);
        NSString *seedName = LCTVString(info[@"LCTVResourceSeedName"]);
        NSString *exePath = [url.path stringByAppendingPathComponent:executable ?: @""];
        if (!executable.length || !guestID.length || !seedName.length ||
            ![NSFileManager.defaultManager fileExistsAtPath:exePath]) continue;
        return @{
            @"slotPath": url.path,
            @"executablePath": exePath,
            @"executable": executable,
            @"bundleID": guestID,
            @"displayName": displayName.length ? displayName : executable,
            @"seedName": seedName,
            @"version": LCTVString(info[@"LCTVGuestVersion"]) ?: @"",
            @"build": LCTVString(info[@"LCTVGuestBuild"]) ?: @"",
        };
    }
    return nil;
}

static NSString *LCTVSeedPath(NSDictionary<NSString *, NSString *> *slot) {
    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    NSString *seedName = slot[@"seedName"];
    if (!resourcePath.length || !seedName.length) return nil;
    return [[resourcePath stringByAppendingPathComponent:@"GuestSeeds"] stringByAppendingPathComponent:seedName];
}

static NSString *LCTVWritableBundlePath(NSDictionary<NSString *, NSString *> *slot) {
    NSString *home = LCTVHostHome();
    if (!home.length) return nil;
    NSString *root = [home stringByAppendingPathComponent:LCTVWritableRelativeRoot];
    NSString *safeID = [[slot[@"bundleID"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return [root stringByAppendingPathComponent:[safeID stringByAppendingString:@".app"]];
}

static BOOL LCTVResourceOnlyInvariant(NSString *path, NSString *executable) {
    return path.length &&
           ![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:executable ?: @""]] &&
           ![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Frameworks"]];
}

static BOOL LCTVWritableNeedsRefresh(NSDictionary<NSString *, NSString *> *slot, NSString *destination) {
    if (![NSFileManager.defaultManager fileExistsAtPath:destination]) return YES;
    NSBundle *bundle = [NSBundle bundleWithPath:destination];
    NSDictionary *info = bundle.infoDictionary;
    if (!bundle || !info || ![info[@"LCTVResourceSeed"] boolValue]) return YES;
    NSString *bundleID = bundle.bundleIdentifier ?: LCTVString(info[@"CFBundleIdentifier"]) ?: @"";
    NSString *version = LCTVString(info[@"CFBundleShortVersionString"]) ?: @"";
    NSString *build = LCTVString(info[@"CFBundleVersion"]) ?: @"";
    return ![bundleID isEqualToString:slot[@"bundleID"] ?: @""] ||
           ![version isEqualToString:slot[@"version"] ?: @""] ||
           ![build isEqualToString:slot[@"build"] ?: @""];
}

static BOOL LCTVEnsureWritableResources(NSDictionary<NSString *, NSString *> *slot, NSString **errorOut) {
    NSString *seed = LCTVSeedPath(slot);
    NSString *destination = LCTVWritableBundlePath(slot);
    if (!seed.length || !destination.length) {
        if (errorOut) *errorOut = @"resource seed/writable destination unavailable";
        return NO;
    }
    if (!LCTVResourceOnlyInvariant(seed, slot[@"executable"])) {
        if (errorOut) *errorOut = @"resource seed unexpectedly contains executable code";
        return NO;
    }
    NSString *root = destination.stringByDeletingLastPathComponent;
    if (!LCTVEnsureDirectory(root, errorOut)) return NO;
    if (!LCTVWritableNeedsRefresh(slot, destination)) {
        if (!LCTVResourceOnlyInvariant(destination, slot[@"executable"])) {
            if (errorOut) *errorOut = @"existing writable resource bundle contains code";
            return NO;
        }
        return YES;
    }

    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![NSFileManager.defaultManager removeItemAtPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"remove old resources failed: %@", error.localizedDescription];
        return NO;
    }
    error = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:seed toPath:destination error:&error]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"copy resource seed failed: %@", error.localizedDescription];
        return NO;
    }
    if (!LCTVResourceOnlyInvariant(destination, slot[@"executable"])) {
        if (errorOut) *errorOut = @"writable copy unexpectedly contains executable code";
        return NO;
    }
    return YES;
}

static NSUInteger LCTVNestedFrameworkCount(NSString *slotPath) {
    NSString *frameworks = [slotPath stringByAppendingPathComponent:@"Frameworks"];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:nil];
    NSUInteger count = 0;
    for (NSString *entry in entries) {
        if ([entry.pathExtension.lowercaseString isEqualToString:@"framework"]) count++;
    }
    return count;
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

static int LCTVBootMinimalSplit(int argc, char *argv[]) {
    NSDictionary<NSString *, NSString *> *slot = LCTVFindCodeSlot();
    if (!slot) {
        LCTVStoreResult(@"MVP7F FAIL: minimal signed code slot not found");
        return INT_MIN;
    }

    NSString *setupError = nil;
    if (!LCTVEnsureWritableResources(slot, &setupError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7F RESOURCE PREP FAIL: %@", setupError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *bundlePath = LCTVWritableBundlePath(slot);
    NSBundle *resourceBundle = [NSBundle bundleWithPath:bundlePath];
    if (!resourceBundle) {
        LCTVStoreResult(@"MVP7F RESOURCE BUNDLE FAIL: NSBundle rejected resource-only writable app");
        return INT_MIN;
    }

    NSString *home = LCTVHostHome();
    NSString *safeID = [[slot[@"bundleID"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *guestHome = [home stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Caches/LiveContainerTV/Guests/%@/Data", safeID]];
    NSString *mkdirError = nil;
    if (!LCTVEnsureDirectory(guestHome, &mkdirError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7F FAIL guest HOME: %@", mkdirError ?: @"unknown"]);
        return INT_MIN;
    }

    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         slot[@"executablePath"],
                                                         slot[@"bundleID"],
                                                         slot[@"executable"],
                                                         guestHome,
                                                         &preError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7F %@ START resource-only writable + minimal signed code pre=%@",
                     slot[@"displayName"], preOK ? @"PASS" : @"PARTIAL"]);

    dlerror();
    void *handle = dlopen([slot[@"executablePath"] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *raw = dlerror();
        LCTVStoreResult([NSString stringWithFormat:@"MVP7F DLOPEN FAIL signed minimal code: %s", raw ?: "unknown"]);
        return 1;
    }
    const struct mach_header_64 *header = LCTVLoadedHeaderForPath(slot[@"executablePath"]);
    if (!header) {
        LCTVStoreResult(@"MVP7F FAIL: loaded signed image not found");
        dlclose(handle);
        return 1;
    }

    uint64_t entryoff = 0;
    NSString *mainError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryoff, &mainError)) {
        LCTVStoreResult([NSString stringWithFormat:@"MVP7F LC_MAIN FAIL: %@", mainError ?: @"unknown"]);
        dlclose(handle);
        return 1;
    }
    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(header, &postError);
    LCTVStoreResult([NSString stringWithFormat:@"MVP7F PASS minimal split pre=%@ post=%@ frameworks=%lu entryoff=0x%llx",
                     preOK ? @"PASS" : @"PARTIAL",
                     postOK ? @"PASS" : @"PARTIAL",
                     (unsigned long)LCTVNestedFrameworkCount(slot[@"slotPath"]),
                     (unsigned long long)entryoff]);

    static char argv0[PATH_MAX];
    if (argc > 0 && argv) {
        strlcpy(argv0, [slot[@"executablePath"] fileSystemRepresentation], sizeof(argv0));
        argv[0] = argv0;
    }
    LCTVGuestMainFn guestMain = (LCTVGuestMainFn)((uintptr_t)header + (uintptr_t)entryoff);
    int result = guestMain(argc, argv);
    dlclose(handle);
    return result;
}

@interface LCTVMVP7FViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation LCTVMVP7FViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    NSDictionary<NSString *, NSString *> *slot = LCTVFindCodeSlot();
    NSString *setupError = nil;
    BOOL storeOK = slot && LCTVEnsureWritableResources(slot, &setupError);
    NSString *writable = slot ? LCTVWritableBundlePath(slot) : nil;
    BOOL resourceOnly = slot && storeOK && LCTVResourceOnlyInvariant(writable, slot[@"executable"]);
    NSUInteger frameworks = slot ? LCTVNestedFrameworkCount(slot[@"slotPath"]) : 0;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP7F";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:50.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Minimal Signed Slot — resources writable, executable code signed";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:23.0];
    subtitle.textAlignment = NSTextAlignmentCenter;

    UILabel *diagnostics = [[UILabel alloc] init];
    diagnostics.translatesAutoresizingMaskIntoConstraints = NO;
    diagnostics.text = slot ?
      [NSString stringWithFormat:@"%@ %@ (%@)  •  signed main + %lu frameworks  •  writable exe=NO frameworks=NO  •  store=%@",
       slot[@"displayName"], slot[@"version"], slot[@"build"], (unsigned long)frameworks, (storeOK && resourceOnly) ? @"PASS" : @"FAIL"] :
      @"Minimal signed code slot not found.";
    diagnostics.textColor = (storeOK && resourceOnly) ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    diagnostics.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    diagnostics.textAlignment = NSTextAlignmentCenter;
    diagnostics.numberOfLines = 0;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"▶  Launch Nuvio — minimal split" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    [button addTarget:self action:@selector(arm:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:900.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:74.0].active = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:LCTVResultKey] ?: @"Ready. This build removes the guest executable and Frameworks from the writable resource bundle.";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:18.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    [self.view addSubview:title];
    [self.view addSubview:subtitle];
    [self.view addSubview:diagnostics];
    [self.view addSubview:button];
    [self.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
      [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:54.0],
      [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
      [diagnostics.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [diagnostics.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:22.0],
      [diagnostics.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:80.0],
      [diagnostics.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-80.0],
      [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [button.topAnchor constraintEqualToAnchor:diagnostics.bottomAnchor constant:38.0],
      [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
      [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90.0],
      [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90.0],
      [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-42.0],
    ]];
}

- (void)arm:(UIButton *)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:LCTVBootKey];
    NSString *message = @"MVP7F ARMED. Force-close LiveContainerTV, then reopen it.";
    [defaults setObject:message forKey:LCTVResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}
@end

@interface LCTVMVP7FAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation LCTVMVP7FAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP7FViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:LCTVBootKey]) {
            [defaults removeObjectForKey:LCTVBootKey];
            [defaults synchronize];
            int result = LCTVBootMinimalSplit(argc, argv);
            if (result != INT_MIN) return result;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP7FAppDelegate.class));
    }
}
