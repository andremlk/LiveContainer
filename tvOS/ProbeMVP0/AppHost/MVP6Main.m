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
static NSString * const LCTVLastMVP6ResultKey = @"LCTVLastMVP6Result";

typedef int (*LCTVGuestMainFn)(int, char **);

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *LCTVGuestCatalog(void) {
    return @{
        @"sample": @{
            @"title": @"tvOS Sample Guide (control)",
            @"framework": @"MVP6SampleGuest.framework",
        },
        @"nuvio": @{
            @"title": @"NuvioTV 3.3.3",
            @"framework": @"MVP6NuvioGuest.framework",
        },
    };
}

static NSString *LCTVGuestFrameworkPath(NSString *guestID) {
    NSDictionary *descriptor = LCTVGuestCatalog()[guestID];
    NSString *frameworkName = descriptor[@"framework"];
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworkName.length || !frameworksURL) return nil;
    return [[frameworksURL URLByAppendingPathComponent:frameworkName] path];
}

static NSBundle *LCTVGuestBundle(NSString *guestID) {
    NSString *path = LCTVGuestFrameworkPath(guestID);
    return path.length ? [NSBundle bundleWithPath:path] : nil;
}

static NSString *LCTVGuestExecutablePath(NSString *guestID) {
    NSBundle *bundle = LCTVGuestBundle(guestID);
    NSString *executable = bundle.infoDictionary[@"CFBundleExecutable"];
    if (!bundle || !executable.length) return nil;
    return [bundle.bundlePath stringByAppendingPathComponent:executable];
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
    [defaults setObject:message forKey:LCTVLastMVP6ResultKey];
    [defaults synchronize];
}

static int LCTVBootGuestColdStart(int argc,
                                  char *argv[],
                                  NSString *guestID,
                                  NSUserDefaults *hostDefaults,
                                  NSString **errorOut) {
    NSDictionary *descriptor = LCTVGuestCatalog()[guestID];
    NSString *displayName = descriptor[@"title"] ?: guestID;
    NSBundle *guestBundle = LCTVGuestBundle(guestID);
    NSString *guestPath = LCTVGuestExecutablePath(guestID);

    if (!descriptor || !guestBundle || !guestPath.length) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest %@ is not staged in the host IPA", guestID];
        return INT_MIN;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest executable missing at %@", guestPath];
        return INT_MIN;
    }

    NSString *bundleID = guestBundle.bundleIdentifier ?: [NSString stringWithFormat:@"mvp6.%@.guest", guestID];
    NSString *processName = guestBundle.infoDictionary[@"CFBundleExecutable"] ?: guestPath.lastPathComponent;
    NSString *bundlePath = guestBundle.bundlePath;

    const char *hostHomeCString = getenv("HOME");
    if (!hostHomeCString) {
        if (errorOut) *errorOut = @"host HOME unavailable before guest bootstrap";
        return INT_MIN;
    }
    NSString *hostHome = [NSString stringWithUTF8String:hostHomeCString];
    NSString *safeID = [[bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                        stringByReplacingOccurrencesOfString:@":" withString:@"_"];
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
                    [NSString stringWithFormat:@"MVP6 %@ STARTED: applying guest identity before dlopen", displayName]);

    unsetenv("LCTV_HOST_PREMAIN_PROBE");
    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(bundlePath,
                                                         guestPath,
                                                         bundleID,
                                                         processName,
                                                         guestHome,
                                                         &preError);
    setenv("LCTV_MVP6_PRE_OK", preOK ? "1" : "0", 1);
    if (preError.length) setenv("LCTV_MVP6_PRE_ERROR", preError.UTF8String, 1);

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *error = dlerror();
        NSString *message = [NSString stringWithFormat:@"FAIL MVP6 %@ dlopen: %s", displayName, error ?: "unknown error"];
        LCTVStoreResult(hostDefaults, message);
        if (errorOut) *errorOut = message;
        return 1;
    }

    const struct mach_header_64 *guestHeader = NULL;
    uint64_t entryOffset = 0;
    NSString *resolveError = nil;
    LCTVGuestMainFn guestMain = LCTVResolveGuestMainForPath(guestPath, &guestHeader, &entryOffset, &resolveError);
    if (!guestMain) {
        NSString *message = [NSString stringWithFormat:@"FAIL MVP6 %@ LC_MAIN: %@", displayName, resolveError ?: @"unknown error"];
        LCTVStoreResult(hostDefaults, message);
        if (errorOut) *errorOut = message;
        dlclose(handle);
        return 1;
    }

    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(guestHeader, &postError);
    setenv("LCTV_MVP6_POST_OK", postOK ? "1" : "0", 1);
    if (postError.length) setenv("LCTV_MVP6_POST_ERROR", postError.UTF8String, 1);

    LCTVStoreResult(hostDefaults,
                    [NSString stringWithFormat:@"MVP6 %@: jumping to LC_MAIN (entryoff=0x%llx, pre=%@, post=%@)",
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

static UIButton *LCTVGuestButton(NSString *title, NSString *guestID, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    button.accessibilityIdentifier = guestID;
    button.enabled = LCTVGuestBundle(guestID) != nil;
    [button addTarget:target action:@selector(armGuest:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:760.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:78.0].active = YES;
    return button;
}

@interface LCTVMVP6ViewController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation LCTVMVP6ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"LiveContainerTV — MVP6";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:52.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Multi-Guest Library — choose an app, force-close LiveContainerTV, then reopen it";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:24.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIButton *sample = LCTVGuestButton(@"▶  tvOS Sample Guide — known-good control", @"sample", self);
    UIButton *nuvio = LCTVGuestButton(@"▶  NuvioTV 3.3.3 — real-world guest", @"nuvio", self);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[sample, nuvio]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 30.0;
    stack.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:stack];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *last = [NSUserDefaults.standardUserDefaults stringForKey:LCTVLastMVP6ResultKey];
    BOOL samplePresent = LCTVGuestBundle(@"sample") != nil;
    BOOL nuvioPresent = LCTVGuestBundle(@"nuvio") != nil;
    self.statusLabel.text = last ?: [NSString stringWithFormat:@"Ready. Staged guests: Sample=%@  Nuvio=%@",
                                     samplePresent ? @"YES" : @"NO",
                                     nuvioPresent ? @"YES" : @"NO"];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:20.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:60.0],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16.0],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-10.0],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:100.0],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-100.0],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-60.0],
    ]];
}

- (void)armGuest:(UIButton *)sender {
    NSString *guestID = sender.accessibilityIdentifier;
    NSDictionary *descriptor = LCTVGuestCatalog()[guestID];
    if (!descriptor || !LCTVGuestBundle(guestID)) {
        self.statusLabel.text = [NSString stringWithFormat:@"Guest %@ is not staged in this build.", guestID ?: @"unknown"];
        return;
    }

    NSString *displayName = descriptor[@"title"] ?: guestID;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:guestID forKey:LCTVSelectedGuestNextLaunchKey];
    NSString *message = [NSString stringWithFormat:@"%@ ARMED. Force-close LiveContainerTV, then reopen it. One guest runs per process.", displayName];
    [defaults setObject:message forKey:LCTVLastMVP6ResultKey];
    [defaults synchronize];
    self.statusLabel.text = message;
}

@end

@interface LCTVMVP6AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVMVP6AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVMVP6ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *guestID = [defaults stringForKey:LCTVSelectedGuestNextLaunchKey];

        if (guestID.length) {
            [defaults removeObjectForKey:LCTVSelectedGuestNextLaunchKey];
            NSDictionary *descriptor = LCTVGuestCatalog()[guestID];
            NSString *displayName = descriptor[@"title"] ?: guestID;
            LCTVStoreResult(defaults,
                            [NSString stringWithFormat:@"MVP6 %@ STARTED: loader entered before host UIApplicationMain", displayName]);

            NSString *bootError = nil;
            int guestResult = LCTVBootGuestColdStart(argc, argv, guestID, defaults, &bootError);
            if (guestResult != INT_MIN) return guestResult;

            NSString *failure = [NSString stringWithFormat:@"FAIL MVP6 %@ cold-start: %@", displayName, bootError ?: @"unknown error"];
            LCTVStoreResult(defaults, failure);
        }

        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVMVP6AppDelegate.class));
    }
}
