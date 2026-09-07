#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <sys/types.h>
#import <unistd.h>
#import <errno.h>
#import <stdint.h>
#import <string.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static const NSInteger LCTVJITPanelTag = 0x7A01;
static const NSInteger LCTVJITLabelTag = 0x7A02;
static NSString * const LCTVJITProbeDefaultsKey = @"LCTVMVP7JJITProbeResult";

static BOOL LCTVJITIsDebugged(void) {
    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return NO;
    }
    return (flags & CS_DEBUGGED) != 0;
}

static NSString *LCTVJITDebugState(void) {
    return LCTVJITIsDebugged() ? @"CS_DEBUGGED=YES" : @"CS_DEBUGGED=NO";
}

static NSString *LCTVJITRunExecutableMemoryProbe(void) {
#if !defined(__arm64__)
    return @"UNSUPPORTED (not arm64)";
#else
    if (!LCTVJITIsDebugged()) {
        return @"SKIP (enable JIT/debug attach first)";
    }

    long rawPageSize = sysconf(_SC_PAGESIZE);
    size_t pageSize = rawPageSize > 0 ? (size_t)rawPageSize : 16384u;
    void *memory = mmap(NULL, pageSize, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) {
        return [NSString stringWithFormat:@"FAIL mmap errno=%d (%s)", errno, strerror(errno)];
    }

    // arm64: mov w0, #42 ; ret
    const uint32_t code[] = { 0x52800540u, 0xD65F03C0u };
    memcpy(memory, code, sizeof(code));
    __builtin___clear_cache((char *)memory, (char *)memory + sizeof(code));

    if (mprotect(memory, pageSize, PROT_READ | PROT_EXEC) != 0) {
        int savedErrno = errno;
        munmap(memory, pageSize);
        return [NSString stringWithFormat:@"FAIL mprotect RX errno=%d (%s)", savedErrno, strerror(savedErrno)];
    }

    int (*probe)(void) = (int (*)(void))memory;
    int value = probe();
    munmap(memory, pageSize);
    return value == 42
        ? @"PASS executable-memory return=42"
        : [NSString stringWithFormat:@"FAIL executable-memory return=%d", value];
#endif
}

static UILabel *LCTVJITLabelForRoot(UIViewController *root) {
    UIView *panel = [root.view viewWithTag:LCTVJITPanelTag];
    return (UILabel *)[panel viewWithTag:LCTVJITLabelTag];
}

static void LCTVJITRefreshPanel(UIViewController *root) {
    UILabel *label = LCTVJITLabelForRoot(root);
    if (!label) return;
    NSString *probe = [NSUserDefaults.standardUserDefaults stringForKey:LCTVJITProbeDefaultsKey] ?: @"not run";
    label.text = [NSString stringWithFormat:@"MVP7J JIT  •  %@\nexec probe: %@", LCTVJITDebugState(), probe];
}

static void LCTVJITInstallPanelIfNeeded(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    UIViewController *root = window.rootViewController;
    if (!root) return;

    // This probe must never bleed into a launched guest UI.
    if (![NSStringFromClass(root.class) isEqualToString:@"LCTVMVP7HViewController"]) return;
    if ([root.view viewWithTag:LCTVJITPanelTag]) {
        LCTVJITRefreshPanel(root);
        return;
    }

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.tag = LCTVJITPanelTag;
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    panel.layer.cornerRadius = 14.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = UIColor.systemBlueColor.CGColor;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.tag = LCTVJITLabelTag;
    label.textColor = UIColor.systemBlueColor;
    label.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Run JIT memory probe" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    __weak UIViewController *weakRoot = root;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        (void)action;
        NSString *result = LCTVJITRunExecutableMemoryProbe();
        [NSUserDefaults.standardUserDefaults setObject:result forKey:LCTVJITProbeDefaultsKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        UIViewController *strongRoot = weakRoot;
        if (strongRoot) LCTVJITRefreshPanel(strongRoot);
        NSLog(@"[LiveContainerTV MVP7J] %@ / %@", LCTVJITDebugState(), result);
    }] forControlEvents:UIControlEventPrimaryActionTriggered];

    [panel addSubview:label];
    [panel addSubview:button];
    [root.view addSubview:panel];

    UILayoutGuide *safe = root.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18.0],
        [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [panel.widthAnchor constraintEqualToConstant:390.0],
        [label.topAnchor constraintEqualToAnchor:panel.topAnchor constant:10.0],
        [label.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12.0],
        [button.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:5.0],
        [button.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12.0],
        [button.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12.0],
        [button.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];

    LCTVJITRefreshPanel(root);

    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        UIViewController *strongRoot = weakRoot;
        if (!strongRoot || strongRoot.view.window == nil) {
            [timer invalidate];
            return;
        }
        LCTVJITRefreshPanel(strongRoot);
    }];
    objc_setAssociatedObject(root, @selector(LCTVJITRefreshPanel), timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor))
static void LCTVJITProbeConstructor(void) {
    @autoreleasepool {
        NSLog(@"[LiveContainerTV MVP7J] startup %@", LCTVJITDebugState());
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                LCTVJITInstallPanelIfNeeded();
                            });
                        }];
        });
    }
}
