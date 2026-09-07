#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#import "IdentityHooks.h"
#import "HostPreMainProbe.h"

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

static BOOL LCTVCurrentProbePassed(void) {
    return LCTVHostPreMainProbeEnabled() ? LCTVHostPreMainProbePassed() : LCTVIdentityProbePassed();
}

static NSString *LCTVCurrentProbeTitle(void) {
    return LCTVHostPreMainProbeEnabled() ? LCTVHostPreMainProbeTitle() : LCTVIdentityProbeTitle();
}

static NSString *LCTVCurrentProbeStatus(void) {
    return LCTVHostPreMainProbeEnabled() ? LCTVHostPreMainProbeStatus() : LCTVIdentityProbeStatus();
}

static NSString *LCTVCurrentProbeSnapshot(void) {
    return LCTVHostPreMainProbeEnabled() ? LCTVHostPreMainProbeSnapshot() : LCTVIdentitySnapshot();
}

static NSString *LCTVCurrentProbeExpectation(void) {
    return LCTVHostPreMainProbeEnabled() ? LCTVHostPreMainProbeExpectation() : LCTVIdentityProbeExpectation();
}

@interface LCTVUIKitGuestViewController : UIViewController
@end

@implementation LCTVUIKitGuestViewController
- (void)viewDidLoad {
    [super viewDidLoad];

    BOOL passed = LCTVCurrentProbePassed();
    self.view.backgroundColor = passed ? UIColor.systemGreenColor : UIColor.systemRedColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = LCTVCurrentProbeTitle();
    title.textColor = UIColor.blackColor;
    title.font = [UIFont boldSystemFontOfSize:64.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.text = [NSString stringWithFormat:
                   @"Guest UIApplicationMain + AppDelegate are running\n"
                    "Result: %@\n\n"
                    "Hook status:\n%@\n\n"
                    "Identity snapshot:\n%@\n\n"
                    "Expected for this isolated probe:\n%@\n\n"
                    "Force-close LiveContainerTV and reopen it to return to the host probe menu.",
                   passed ? @"PASS" : @"FAIL",
                   LCTVCurrentProbeStatus(),
                   LCTVCurrentProbeSnapshot(),
                   LCTVCurrentProbeExpectation()];
    detail.textColor = UIColor.blackColor;
    detail.font = [UIFont monospacedSystemFontOfSize:17.0 weight:UIFontWeightRegular];
    detail.textAlignment = NSTextAlignmentLeft;
    detail.numberOfLines = 0;
    detail.adjustsFontSizeToFitWidth = YES;
    detail.minimumScaleFactor = 0.72;
    [self.view addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:34],
        [detail.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:20],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:60],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-60],
        [detail.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-28]
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

    BOOL hostPreMain = LCTVHostPreMainProbeEnabled();
    BOOL passed = hostPreMain ? LCTVHostPreMainProbePassed() : LCTVApplyIdentityAtDidFinishLaunching();
    NSString *identity = LCTVCurrentProbeSnapshot();
    NSString *result = [NSString stringWithFormat:@"%@: %@", LCTVCurrentProbeTitle(), passed ? @"PASS" : @"FAIL"];

    // The normal MVP3/4 probes persist their result in the host defaults. In the
    // MVP5 host-pre-main probe, NSBundle/HOME have already been virtualized before
    // this point, so intentionally avoid touching standardUserDefaults here.
    if (!hostPreMain) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setObject:result forKey:LCTVLastMVP3ResultKey];
        [defaults setObject:identity forKey:LCTVLastMVP3IdentityKey];
        [defaults synchronize];
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[LCTVUIKitGuestViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // In host-pre-main mode the host has already installed all identity
        // virtualization. The guest remains in baseline mode, so this function
        // intentionally performs no guest-side hooks.
        LCTVPrepareIdentityBeforeUIApplicationMain();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LCTVUIKitGuestAppDelegate.class));
    }
}
