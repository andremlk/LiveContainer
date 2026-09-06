#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdlib.h>

static NSString * const LCTVLastMVP3ResultKey = @"LCTVLastMVP3Result";
static NSString * const LCTVLastMVP3IdentityKey = @"LCTVLastMVP3Identity";

__attribute__((visibility("default")))
const char *LCTVUIKitGuestMarker(void) {
#if TARGET_OS_TV
    return "UIKitGuestTV/tvOS";
#else
    return "UIKitGuestTV/not-tvOS";
#endif
}

static NSString *LCTVCurrentExecutablePath(void) {
    char path[PATH_MAX] = {0};
    uint32_t size = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        return [NSString stringWithUTF8String:path] ?: @"(invalid UTF-8)";
    }
    return [NSString stringWithFormat:@"(buffer too small; required=%u)", size];
}

static NSString *LCTVIdentitySnapshot(void) {
    NSBundle *mainBundle = NSBundle.mainBundle;
    NSString *bundleID = mainBundle.bundleIdentifier ?: @"(nil)";
    NSString *bundlePath = mainBundle.bundlePath ?: @"(nil)";
    NSString *executablePath = LCTVCurrentExecutablePath();
    const char *homeEnv = getenv("HOME");
    NSString *home = homeEnv ? ([NSString stringWithUTF8String:homeEnv] ?: @"(invalid UTF-8)") : @"(unset)";
    NSString *nsHome = NSHomeDirectory() ?: @"(nil)";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"(nil)";

    return [NSString stringWithFormat:
            @"bundleID=%@\n"
             "bundlePath=%@\n"
             "_NSGetExecutablePath=%@\n"
             "HOME=%@\n"
             "NSHomeDirectory=%@\n"
             "processName=%@",
            bundleID,
            bundlePath,
            executablePath,
            home,
            nsHome,
            processName];
}

@interface LCTVUIKitGuestViewController : UIViewController
@end

@implementation LCTVUIKitGuestViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGreenColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"MVP3 PASS";
    title.textColor = UIColor.blackColor;
    title.font = [UIFont boldSystemFontOfSize:68.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *identity = [NSUserDefaults.standardUserDefaults stringForKey:LCTVLastMVP3IdentityKey] ?: LCTVIdentitySnapshot();
    detail.text = [NSString stringWithFormat:
                   @"Guest UIApplicationMain + AppDelegate are running\n\n"
                    "MVP4 baseline identity (virtualization NOT applied):\n%@\n\n"
                    "Force-close LiveContainerTV and reopen it to return to the host probes.",
                   identity];
    detail.textColor = UIColor.blackColor;
    detail.font = [UIFont monospacedSystemFontOfSize:21.0 weight:UIFontWeightRegular];
    detail.textAlignment = NSTextAlignmentLeft;
    detail.numberOfLines = 0;
    [self.view addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:55],
        [detail.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:34],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:80],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-80],
        [detail.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-45]
    ]];
}
@end

@interface LCTVUIKitGuestAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LCTVUIKitGuestAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    NSString *identity = LCTVIdentitySnapshot();
    NSString *result = @"PASS MVP3: guest UIApplicationMain reached didFinishLaunching";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:result forKey:LCTVLastMVP3ResultKey];
    [defaults setObject:identity forKey:LCTVLastMVP3IdentityKey];
    [defaults synchronize];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVUIKitGuestViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVUIKitGuestAppDelegate.class));
    }
}
