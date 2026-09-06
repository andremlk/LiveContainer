#import <UIKit/UIKit.h>
#import <dlfcn.h>

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

static NSString *LCTVRunPatchedExecutableProbe(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) {
        return @"FAIL MVP2A: Frameworks directory unavailable";
    }

    NSString *guestPath = [[frameworksURL URLByAppendingPathComponent:@"TinyGuestTV.framework/TinyGuestTV"] path];
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
    subtitle.text = @"Hardware validation probes — MVP0 + MVP2A";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:28.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIButton *frameworkButton = LCTVButton(@"MVP0: load normal framework", self, @selector(runFrameworkProbe:));
    UIButton *patchedButton = LCTVButton(@"MVP2A: load patched tvOS executable", self, @selector(runPatchedProbe:));

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[frameworkButton, patchedButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 34.0;
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
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:70],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [buttons.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [buttons.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [frameworkButton.widthAnchor constraintGreaterThanOrEqualToConstant:560],
        [patchedButton.widthAnchor constraintGreaterThanOrEqualToConstant:560],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:90],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-90],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:55]
    ]];
}

- (void)runFrameworkProbe:(id)sender {
    self.statusLabel.text = LCTVRunFrameworkProbe();
}

- (void)runPatchedProbe:(id)sender {
    self.statusLabel.text = LCTVRunPatchedExecutableProbe();
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
