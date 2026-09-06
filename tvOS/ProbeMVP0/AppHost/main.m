#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSString *LCTVRunLoaderProbe(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) {
        return @"FAIL: Frameworks directory unavailable";
    }

    NSString *payloadPath = [[frameworksURL URLByAppendingPathComponent:@"GuestPayload.framework/GuestPayload"] path];
    dlerror();
    void *handle = dlopen(payloadPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        return [NSString stringWithFormat:@"FAIL dlopen: %s", error ?: "unknown error"];
    }

    dlerror();
    typedef const char *(*GuestEntryFn)(void);
    GuestEntryFn guestEntry = (GuestEntryFn)dlsym(handle, "LCTVGuestEntry");
    const char *symbolError = dlerror();
    if (!guestEntry || symbolError) {
        NSString *message = [NSString stringWithFormat:@"FAIL dlsym: %s", symbolError ?: "symbol missing"];
        dlclose(handle);
        return message;
    }

    const char *result = guestEntry();
    NSString *message = result ? [NSString stringWithUTF8String:result] : @"FAIL: guest returned NULL";
    dlclose(handle);
    return message;
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
    subtitle.text = @"MVP 0 — signed dyld/dlopen probe";
    subtitle.textColor = UIColor.lightGrayColor;
    subtitle.font = [UIFont systemFontOfSize:28.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subtitle];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Run loader probe" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:32.0];
    button.contentEdgeInsets = UIEdgeInsetsMake(20, 36, 20, 36);
    [button addTarget:self action:@selector(runProbe:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:button];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Ready";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:24.0 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:100],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [button.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:80],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-80],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:50]
    ]];
}

- (void)runProbe:(id)sender {
    self.statusLabel.text = LCTVRunLoaderProbe();
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
