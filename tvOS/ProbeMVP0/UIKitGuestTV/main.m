#import <UIKit/UIKit.h>
#import <TargetConditionals.h>

static NSString * const LCTVLastMVP3ResultKey = @"LCTVLastMVP3Result";

__attribute__((visibility("default")))
const char *LCTVUIKitGuestMarker(void) {
#if TARGET_OS_TV
    return "UIKitGuestTV/tvOS";
#else
    return "UIKitGuestTV/not-tvOS";
#endif
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
    title.font = [UIFont boldSystemFontOfSize:72.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";
    detail.text = [NSString stringWithFormat:@"Guest UIApplicationMain + AppDelegate are running\nmain bundle (virtualization not added yet): %@\n\nForce-close LiveContainerTV and reopen it to return to the host probe UI.", bundleID];
    detail.textColor = UIColor.blackColor;
    detail.font = [UIFont monospacedSystemFontOfSize:26.0 weight:UIFontWeightRegular];
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;
    [self.view addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-90],
        [detail.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:45],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:100],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-100]
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

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";
    NSString *result = [NSString stringWithFormat:@"PASS MVP3: guest UIApplicationMain reached didFinishLaunching (mainBundle=%@)", bundleID];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:result forKey:LCTVLastMVP3ResultKey];
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
