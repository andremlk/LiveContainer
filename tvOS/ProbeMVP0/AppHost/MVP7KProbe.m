#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <libkern/OSCacheControl.h>
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

static const NSInteger LCTVJITKPanelTag = 0x7B01;
static const NSInteger LCTVJITKLabelTag = 0x7B02;
static NSString * const LCTVJITKDefaultsKey = @"LCTVMVP7KJITDiagnostics";
static char LCTVJITKTimerAssociationKey;

static NSString *LCTVJITKCSFlags(void) {
    int flags = 0;
    errno = 0;
    int rc = csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
    int savedErrno = errno;
    if (rc != 0) {
        return [NSString stringWithFormat:@"csops rc=%d errno=%d (%s)", rc, savedErrno, strerror(savedErrno)];
    }
    return [NSString stringWithFormat:@"csflags=0x%08x CS_DEBUGGED=%@", flags,
            (flags & CS_DEBUGGED) ? @"YES" : @"NO"];
}

static size_t LCTVJITKPageSize(void) {
    long raw = sysconf(_SC_PAGESIZE);
    return raw > 0 ? (size_t)raw : 16384u;
}

static NSString *LCTVJITKRunCodeAt(void *memory, size_t pageSize, NSString *label) {
#if !defined(__arm64__)
    (void)memory; (void)pageSize; (void)label;
    return @"unsupported architecture";
#else
    const uint32_t code[] = { 0x52800540u, 0xD65F03C0u }; // mov w0,#42 ; ret
    memcpy(memory, code, sizeof(code));
    sys_icache_invalidate(memory, sizeof(code));

    errno = 0;
    if (mprotect(memory, pageSize, PROT_READ | PROT_EXEC) != 0) {
        int savedErrno = errno;
        return [NSString stringWithFormat:@"%@ mprotect(RX)=FAIL errno=%d (%s)",
                label, savedErrno, strerror(savedErrno)];
    }

    int (*probe)(void) = (int (*)(void))memory;
    int value = probe();
    return [NSString stringWithFormat:@"%@ mprotect(RX)=PASS exec=%@(%d)",
            label, value == 42 ? @"PASS" : @"FAIL", value];
#endif
}

static NSString *LCTVJITKProbeRWToRX(void) {
    size_t pageSize = LCTVJITKPageSize();
    errno = 0;
    void *memory = mmap(NULL, pageSize,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON,
                        -1, 0);
    if (memory == MAP_FAILED) {
        int savedErrno = errno;
        return [NSString stringWithFormat:@"RW->RX mmap=FAIL errno=%d (%s)", savedErrno, strerror(savedErrno)];
    }
    NSString *result = LCTVJITKRunCodeAt(memory, pageSize, @"RW->RX");
    munmap(memory, pageSize);
    return result;
}

static NSString *LCTVJITKProbeMAPJITAllocation(void) {
#ifdef MAP_JIT
    size_t pageSize = LCTVJITKPageSize();
    errno = 0;
    void *memory = mmap(NULL, pageSize,
                        PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_PRIVATE | MAP_ANON | MAP_JIT,
                        -1, 0);
    if (memory == MAP_FAILED) {
        int savedErrno = errno;
        return [NSString stringWithFormat:@"MAP_JIT RWX=FAIL errno=%d (%s)", savedErrno, strerror(savedErrno)];
    }
    munmap(memory, pageSize);
    return @"MAP_JIT RWX=PASS";
#else
    return @"MAP_JIT=UNAVAILABLE at compile time";
#endif
}

static NSString *LCTVJITKProbeMAPJITRWToRX(void) {
#ifdef MAP_JIT
    size_t pageSize = LCTVJITKPageSize();
    errno = 0;
    void *memory = mmap(NULL, pageSize,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON | MAP_JIT,
                        -1, 0);
    if (memory == MAP_FAILED) {
        int savedErrno = errno;
        return [NSString stringWithFormat:@"MAP_JIT RW->RX mmap=FAIL errno=%d (%s)", savedErrno, strerror(savedErrno)];
    }
    NSString *result = LCTVJITKRunCodeAt(memory, pageSize, @"MAP_JIT RW->RX");
    munmap(memory, pageSize);
    return result;
#else
    return @"MAP_JIT RW->RX=UNAVAILABLE";
#endif
}

static NSString *LCTVJITKRunDiagnostics(void) {
    NSString *cs = LCTVJITKCSFlags();
    size_t pageSize = LCTVJITKPageSize();
    NSString *plain = LCTVJITKProbeRWToRX();
    NSString *mapJITAlloc = LCTVJITKProbeMAPJITAllocation();
    NSString *mapJITExec = LCTVJITKProbeMAPJITRWToRX();
    return [NSString stringWithFormat:@"%@\npage=%zu\n%@\n%@\n%@",
            cs, pageSize, plain, mapJITAlloc, mapJITExec];
}

static UILabel *LCTVJITKLabelForRoot(UIViewController *root) {
    UIView *panel = [root.view viewWithTag:LCTVJITKPanelTag];
    return (UILabel *)[panel viewWithTag:LCTVJITKLabelTag];
}

static void LCTVJITKRefreshPanel(UIViewController *root) {
    UILabel *label = LCTVJITKLabelForRoot(root);
    if (!label) return;
    NSString *result = [NSUserDefaults.standardUserDefaults stringForKey:LCTVJITKDefaultsKey];
    if (!result.length) {
        result = [NSString stringWithFormat:@"%@\npage=%zu\nnot run", LCTVJITKCSFlags(), LCTVJITKPageSize()];
    }
    label.text = [NSString stringWithFormat:@"MVP7K JIT diagnostics\n%@", result];
}

static void LCTVJITKInstallPanelIfNeeded(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    UIViewController *root = window.rootViewController;
    if (!root) return;
    if (![NSStringFromClass(root.class) isEqualToString:@"LCTVMVP7HViewController"]) return;

    if ([root.view viewWithTag:LCTVJITKPanelTag]) {
        LCTVJITKRefreshPanel(root);
        return;
    }

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.tag = LCTVJITKPanelTag;
    panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
    panel.layer.cornerRadius = 14.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = UIColor.systemPurpleColor.CGColor;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.tag = LCTVJITKLabelTag;
    label.textColor = UIColor.systemPurpleColor;
    label.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentLeft;
    label.numberOfLines = 0;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Run full JIT diagnostics" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];

    __weak UIViewController *weakRoot = root;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        (void)action;
        NSString *result = LCTVJITKRunDiagnostics();
        [NSUserDefaults.standardUserDefaults setObject:result forKey:LCTVJITKDefaultsKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        UIViewController *strongRoot = weakRoot;
        if (strongRoot) LCTVJITKRefreshPanel(strongRoot);
        NSLog(@"[LiveContainerTV MVP7K] %@", [result stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    }] forControlEvents:UIControlEventPrimaryActionTriggered];

    [panel addSubview:label];
    [panel addSubview:button];
    [root.view addSubview:panel];

    UILayoutGuide *safe = root.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18.0],
        [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [panel.widthAnchor constraintEqualToConstant:570.0],
        [label.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12.0],
        [label.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14.0],
        [button.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8.0],
        [button.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12.0],
        [button.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12.0],
        [button.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:46.0],
    ]];

    LCTVJITKRefreshPanel(root);

    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        UIViewController *strongRoot = weakRoot;
        if (!strongRoot || strongRoot.view.window == nil) {
            [timer invalidate];
            return;
        }
        LCTVJITKRefreshPanel(strongRoot);
    }];
    objc_setAssociatedObject(root, &LCTVJITKTimerAssociationKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor))
static void LCTVJITKProbeConstructor(void) {
    @autoreleasepool {
        NSLog(@"[LiveContainerTV MVP7K] startup %@ page=%zu", LCTVJITKCSFlags(), LCTVJITKPageSize());
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                LCTVJITKInstallPanelIfNeeded();
                            });
                        }];
        });
    }
}
