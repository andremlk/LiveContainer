#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#import <mach-o/dyld.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <limits.h>
#import <stdlib.h>

static NSString * const LCTVLastMVP3ResultKey = @"LCTVLastMVP3Result";
static NSString * const LCTVLastMVP3IdentityKey = @"LCTVLastMVP3Identity";
static NSString * const LCTVExpectedGuestBundleID = @"dev.livecontainertv.uikitguest.patched";

static NSBundle *gLCTVVirtualMainBundle = nil;
static IMP gLCTVOriginalMainBundleIMP = NULL;
static NSString *gLCTVMVP4AStatus = nil;

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

static NSString *LCTVGuestFrameworkPath(void) {
    Dl_info imageInfo = {0};
    if (dladdr((const void *)&LCTVUIKitGuestMarker, &imageInfo) == 0 || !imageInfo.dli_fname) {
        return nil;
    }
    NSString *imagePath = [NSString stringWithUTF8String:imageInfo.dli_fname];
    return imagePath.stringByDeletingLastPathComponent;
}

static NSBundle *LCTVMainBundleOverride(id self, SEL _cmd) {
    if (gLCTVVirtualMainBundle) {
        return gLCTVVirtualMainBundle;
    }
    if (gLCTVOriginalMainBundleIMP) {
        NSBundle *(*original)(id, SEL) = (NSBundle *(*)(id, SEL))gLCTVOriginalMainBundleIMP;
        return original(self, _cmd);
    }
    return nil;
}

static BOOL LCTVInstallMainBundleOverride(NSString **errorOut) {
    NSString *frameworkPath = LCTVGuestFrameworkPath();
    if (!frameworkPath) {
        if (errorOut) {
            *errorOut = @"dladdr could not locate UIKitGuestTV.framework";
        }
        return NO;
    }

    NSBundle *guestBundle = [NSBundle bundleWithPath:frameworkPath];
    if (!guestBundle) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"NSBundle could not open guest framework at %@", frameworkPath];
        }
        return NO;
    }

    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    if (!method) {
        if (errorOut) {
            *errorOut = @"+[NSBundle mainBundle] method not found";
        }
        return NO;
    }

    gLCTVVirtualMainBundle = guestBundle;
    if (!gLCTVOriginalMainBundleIMP) {
        gLCTVOriginalMainBundleIMP = method_setImplementation(method, (IMP)LCTVMainBundleOverride);
    } else {
        method_setImplementation(method, (IMP)LCTVMainBundleOverride);
    }

    NSBundle *observed = NSBundle.mainBundle;
    if (observed != guestBundle || ![observed.bundleIdentifier isEqualToString:LCTVExpectedGuestBundleID]) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"override installed but observed bundle is %@ at %@",
                         observed.bundleIdentifier ?: @"(nil)", observed.bundlePath ?: @"(nil)"];
        }
        return NO;
    }
    return YES;
}

static NSString *LCTVCFMainBundleIdentifier(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) {
        return @"(nil)";
    }
    CFStringRef identifier = CFBundleGetIdentifier(bundle);
    return identifier ? [(__bridge NSString *)identifier copy] : @"(nil)";
}

static NSString *LCTVCFMainBundlePath(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) {
        return @"(nil)";
    }
    CFURLRef url = CFBundleCopyBundleURL(bundle);
    if (!url) {
        return @"(nil)";
    }
    NSString *path = [(__bridge NSURL *)url path] ?: @"(nil)";
    CFRelease(url);
    return path;
}

static NSString *LCTVIdentitySnapshot(void) {
    NSBundle *mainBundle = NSBundle.mainBundle;
    NSString *bundleID = mainBundle.bundleIdentifier ?: @"(nil)";
    NSString *bundlePath = mainBundle.bundlePath ?: @"(nil)";
    NSString *cfBundleID = LCTVCFMainBundleIdentifier();
    NSString *cfBundlePath = LCTVCFMainBundlePath();
    NSString *executablePath = LCTVCurrentExecutablePath();
    const char *homeEnv = getenv("HOME");
    NSString *home = homeEnv ? ([NSString stringWithUTF8String:homeEnv] ?: @"(invalid UTF-8)") : @"(unset)";
    NSString *nsHome = NSHomeDirectory() ?: @"(nil)";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"(nil)";

    return [NSString stringWithFormat:
            @"NSBundle.mainBundle.bundleID=%@\n"
             "NSBundle.mainBundle.bundlePath=%@\n"
             "CFBundleGetMainBundle.bundleID=%@\n"
             "CFBundleGetMainBundle.bundlePath=%@\n"
             "_NSGetExecutablePath=%@\n"
             "HOME=%@\n"
             "NSHomeDirectory=%@\n"
             "processName=%@",
            bundleID,
            bundlePath,
            cfBundleID,
            cfBundlePath,
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

    BOOL bundleVirtualized = [NSBundle.mainBundle.bundleIdentifier isEqualToString:LCTVExpectedGuestBundleID];
    self.view.backgroundColor = bundleVirtualized ? UIColor.systemGreenColor : UIColor.systemRedColor;

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = bundleVirtualized ? @"MVP4A PASS" : @"MVP4A FAIL";
    title.textColor = UIColor.blackColor;
    title.font = [UIFont boldSystemFontOfSize:68.0];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *identity = LCTVIdentitySnapshot();
    detail.text = [NSString stringWithFormat:
                   @"Guest UIApplicationMain + AppDelegate are running\n"
                    "NSBundle virtualization: %@\n\n"
                    "MVP4A identity snapshot:\n%@\n\n"
                    "Expected: NSBundle points to UIKitGuestTV.framework. CFBundle, executable path, HOME and process name are intentionally not hooked yet.\n\n"
                    "Force-close LiveContainerTV and reopen it to return to the host probes.",
                   gLCTVMVP4AStatus ?: @"(no status)",
                   identity];
    detail.textColor = UIColor.blackColor;
    detail.font = [UIFont monospacedSystemFontOfSize:19.0 weight:UIFontWeightRegular];
    detail.textAlignment = NSTextAlignmentLeft;
    detail.numberOfLines = 0;
    [self.view addSubview:detail];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:45],
        [detail.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:26],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:70],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-70],
        [detail.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-35]
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

    NSString *overrideError = nil;
    BOOL overrideOK = LCTVInstallMainBundleOverride(&overrideError);
    gLCTVMVP4AStatus = overrideOK ? @"PASS: +[NSBundle mainBundle] now returns UIKitGuestTV.framework"
                                 : [NSString stringWithFormat:@"FAIL: %@", overrideError ?: @"unknown override error"];

    NSString *identity = LCTVIdentitySnapshot();
    NSString *result = overrideOK ? @"PASS MVP4A: NSBundle mainBundle virtualized"
                                  : @"FAIL MVP4A: NSBundle mainBundle override failed";

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
