#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <stdint.h>

static NSString *LCTVRunFrameworkProbe(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) {
        return @"FAIL MVP0: Frameworks directory unavailable";
    }

    NSString *payloadPath = [[frameworksURL URLByAppendingPathComponent:@"GuestPayload.framework/GuestPayload"] path];
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
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) {
        return nil;
    }
    return [[frameworksURL URLByAppendingPathComponent:@"TinyGuestTV.framework/TinyGuestTV"] path];
}

static NSString *LCTVRunPatchedExecutableProbe(void) {
    NSString *guestPath = LCTVPatchedGuestPath();
    if (!guestPath) {
        return @"FAIL MVP2A: Frameworks directory unavailable";
    }
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
        if (errorOut) {
            *errorOut = @"loaded image does not have an ARM64 Mach-O 64 header";
        }
        return NO;
    }
    if (header->filetype != MH_DYLIB) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"loaded image is not MH_DYLIB (filetype=%u)", header->filetype];
        }
        return NO;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > end) {
            if (errorOut) {
                *errorOut = @"load-command table truncated";
            }
            return NO;
        }

        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > end) {
            if (errorOut) {
                *errorOut = @"invalid Mach-O load-command size";
            }
            return NO;
        }

        if (command->cmd == LC_MAIN) {
            if (command->cmdsize < sizeof(struct entry_point_command)) {
                if (errorOut) {
                    *errorOut = @"LC_MAIN is smaller than entry_point_command";
                }
                return NO;
            }
            const struct entry_point_command *entry = (const struct entry_point_command *)command;
            if (entryOffsetOut) {
                *entryOffsetOut = entry->entryoff;
            }
            return YES;
        }
        cursor += command->cmdsize;
    }

    if (errorOut) {
        *errorOut = @"LC_MAIN not found in loaded guest";
    }
    return NO;
}

static NSString *LCTVRunLCMainProbe(void) {
    NSString *guestPath = LCTVPatchedGuestPath();
    if (!guestPath) {
        return @"FAIL MVP2B: Frameworks directory unavailable";
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:guestPath]) {
        return [NSString stringWithFormat:@"FAIL MVP2B: patched guest missing at %@", guestPath];
    }

    dlerror();
    void *handle = dlopen(guestPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        return [NSString stringWithFormat:@"FAIL MVP2B dlopen: %s", error ?: "unknown error"];
    }

    dlerror();
    void *marker = dlsym(handle, "LCTVGuestMarker");
    const char *symbolError = dlerror();
    if (!marker || symbolError) {
        NSString *message = [NSString stringWithFormat:@"FAIL MVP2B marker lookup: %s", symbolError ?: "symbol missing"];
        dlclose(handle);
        return message;
    }

    Dl_info imageInfo = {0};
    if (dladdr(marker, &imageInfo) == 0 || !imageInfo.dli_fbase) {
        dlclose(handle);
        return @"FAIL MVP2B: dladdr could not resolve loaded guest image base";
    }

    const struct mach_header_64 *header = (const struct mach_header_64 *)imageInfo.dli_fbase;
    uint64_t entryOffset = 0;
    NSString *parseError = nil;
    if (!LCTVFindLCMainEntryOffset(header, &entryOffset, &parseError)) {
        dlclose(handle);
        return [NSString stringWithFormat:@"FAIL MVP2B Mach-O parse: %@", parseError ?: @"unknown error"];
    }

    if (entryOffset > UINTPTR_MAX - (uintptr_t)header) {
        dlclose(handle);
        return @"FAIL MVP2B: LC_MAIN entry offset overflows address space";
    }

    typedef int (*GuestMainFn)(int, char **);
    GuestMainFn guestMain = (GuestMainFn)((uintptr_t)header + (uintptr_t)entryOffset);
    int guestReturn = guestMain(0, NULL);

    NSString *message;
    if (guestReturn == 4242) {
        message = [NSString stringWithFormat:@"PASS MVP2B: LC_MAIN executed (return=%d, entryoff=0x%llx)",
                   guestReturn, (unsigned long long)entryOffset];
    } else {
        message = [NSString stringWithFormat:@"FAIL MVP2B: LC_MAIN returned %d, expected 4242 (entryoff=0x%llx)",
                   guestReturn, (unsigned long long)entryOffset];
    }

    dlclose(handle);
    return message;
}

static UIButton *LCTVButton(NSString *title, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    [button addTarget:target action:action forControlEvents:UIControlEventPrimaryActionTriggered];
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
    title.font = [UIFont boldSystemFontOfSize:54.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Hardware validation probes — MVP0 + MVP2A + MVP2B";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:28.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIButton *frameworkButton = LCTVButton(@"MVP0: load normal framework", self, @selector(runFrameworkProbe:));
    UIButton *patchedButton = LCTVButton(@"MVP2A: load patched tvOS executable", self, @selector(runPatchedProbe:));
    UIButton *entryButton = LCTVButton(@"MVP2B: execute preserved LC_MAIN", self, @selector(runLCMainProbe:));

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[frameworkButton, patchedButton, entryButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 28.0;
    buttons.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:buttons];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Ready";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:23.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:60],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16],
        [buttons.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [buttons.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-10],
        [frameworkButton.widthAnchor constraintGreaterThanOrEqualToConstant:620],
        [patchedButton.widthAnchor constraintGreaterThanOrEqualToConstant:620],
        [entryButton.widthAnchor constraintGreaterThanOrEqualToConstant:620],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:45]
    ]];
}

- (void)runFrameworkProbe:(id)sender {
    self.statusLabel.text = LCTVRunFrameworkProbe();
}

- (void)runPatchedProbe:(id)sender {
    self.statusLabel.text = LCTVRunPatchedExecutableProbe();
}

- (void)runLCMainProbe:(id)sender {
    self.statusLabel.text = LCTVRunLCMainProbe();
}
@end

@interface LCTVAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVAppDelegate.class));
    }
}
