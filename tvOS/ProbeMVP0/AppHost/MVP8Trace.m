#import "MVP8Trace.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>

static NSString * const LCTVMVP8HistoryKey = @"LCTVMVP8TraceHistory";
static NSString * const LCTVMVP8LastObservedKey = @"LCTVMVP8LastObservedLegacyResult";
static NSString * const LCTVMVP8LegacyResultKey = @"LCTVMVP7HResult";
static const NSInteger LCTVMVP8PanelTag = 0x8001;
static const NSInteger LCTVMVP8LabelTag = 0x8002;
static char LCTVMVP8TimerAssociationKey;
static dispatch_queue_t LCTVMVP8Queue;

static NSString *LCTVMVP8Stamp(void) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mach_timebase_info(&info); });
    uint64_t now = mach_continuous_time();
    double seconds = ((double)now * (double)info.numer / (double)info.denom) / 1e9;
    return [NSString stringWithFormat:@"T+%.3fs", seconds];
}

static void LCTVMVP8AppendLocked(NSString *event) {
    if (!event.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *existing = [defaults arrayForKey:LCTVMVP8HistoryKey] ?: @[];
    NSMutableArray<NSString *> *history = [NSMutableArray arrayWithCapacity:MIN(existing.count + 1, 80)];
    NSUInteger start = existing.count > 79 ? existing.count - 79 : 0;
    for (NSUInteger i = start; i < existing.count; i++) {
        id value = existing[i];
        if ([value isKindOfClass:NSString.class]) [history addObject:value];
    }
    [history addObject:[NSString stringWithFormat:@"%@  %@", LCTVMVP8Stamp(), event]];
    [defaults setObject:history forKey:LCTVMVP8HistoryKey];
    [defaults synchronize];
    NSLog(@"[LiveContainerTV MVP8] %@", event);
}

void LCTVMVP8TraceEvent(NSString *event) {
    if (!event.length) return;
    dispatch_queue_t queue = LCTVMVP8Queue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_sync(queue, ^{ LCTVMVP8AppendLocked(event); });
}

NSArray<NSString *> *LCTVMVP8TraceHistory(void) {
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:LCTVMVP8HistoryKey] ?: @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id value in raw) if ([value isKindOfClass:NSString.class]) [result addObject:value];
    return result;
}

void LCTVMVP8TraceClear(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:LCTVMVP8HistoryKey];
    [defaults removeObjectForKey:LCTVMVP8LastObservedKey];
    [defaults synchronize];
}

static void LCTVMVP8PollLegacyResult(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *current = [defaults stringForKey:LCTVMVP8LegacyResultKey];
    if (!current.length) return;
    NSString *last = [defaults stringForKey:LCTVMVP8LastObservedKey];
    if ([current isEqualToString:last]) return;
    [defaults setObject:current forKey:LCTVMVP8LastObservedKey];
    [defaults synchronize];
    LCTVMVP8AppendLocked([NSString stringWithFormat:@"LEGACY_STAGE: %@", current]);
}

static NSString *LCTVMVP8PanelText(void) {
    NSArray<NSString *> *history = LCTVMVP8TraceHistory();
    NSUInteger start = history.count > 8 ? history.count - 8 : 0;
    NSArray<NSString *> *tail = [history subarrayWithRange:NSMakeRange(start, history.count - start)];
    NSString *body = tail.count ? [tail componentsJoinedByString:@"\n"] : @"No trace events yet.";
    return [NSString stringWithFormat:@"MVP8 ENTRY TRACE\n%@", body];
}

static void LCTVMVP8RefreshPanel(UIViewController *root) {
    UIView *panel = [root.view viewWithTag:LCTVMVP8PanelTag];
    UILabel *label = (UILabel *)[panel viewWithTag:LCTVMVP8LabelTag];
    if (label) label.text = LCTVMVP8PanelText();
}

static void LCTVMVP8InstallPanelIfNeeded(void) {
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

    if ([root.view viewWithTag:LCTVMVP8PanelTag]) {
        LCTVMVP8RefreshPanel(root);
        return;
    }

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.tag = LCTVMVP8PanelTag;
    panel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.96];
    panel.layer.cornerRadius = 14.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = UIColor.systemTealColor.CGColor;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.tag = LCTVMVP8LabelTag;
    label.textColor = UIColor.systemTealColor;
    label.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentLeft;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear setTitle:@"Clear MVP8 trace" forState:UIControlStateNormal];
    __weak UIViewController *weakRoot = root;
    [clear addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        (void)action;
        LCTVMVP8TraceClear();
        LCTVMVP8TraceEvent(@"TRACE_RESET");
        UIViewController *strongRoot = weakRoot;
        if (strongRoot) LCTVMVP8RefreshPanel(strongRoot);
    }] forControlEvents:UIControlEventPrimaryActionTriggered];

    [panel addSubview:label];
    [panel addSubview:clear];
    [root.view addSubview:panel];

    UILayoutGuide *safe = root.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18.0],
        [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [panel.widthAnchor constraintEqualToConstant:690.0],
        [label.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12.0],
        [label.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14.0],
        [clear.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8.0],
        [clear.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12.0],
        [clear.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12.0],
        [clear.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10.0],
        [clear.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];

    LCTVMVP8RefreshPanel(root);
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull timer) {
        UIViewController *strongRoot = weakRoot;
        if (!strongRoot || strongRoot.view.window == nil) {
            [timer invalidate];
            return;
        }
        LCTVMVP8RefreshPanel(strongRoot);
    }];
    objc_setAssociatedObject(root, &LCTVMVP8TimerAssociationKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor))
static void LCTVMVP8TraceConstructor(void) {
    @autoreleasepool {
        LCTVMVP8Queue = dispatch_queue_create("dev.andre.livecontainertv.mvp8.trace", DISPATCH_QUEUE_SERIAL);
        dispatch_async(LCTVMVP8Queue, ^{
            LCTVMVP8AppendLocked(@"PROCESS_CONSTRUCTOR");
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, LCTVMVP8Queue);
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 0),
                                      50 * NSEC_PER_MSEC,
                                      10 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{ LCTVMVP8PollLegacyResult(); });
            dispatch_resume(timer);
            // Keep the source alive for the life of the process.
            objc_setAssociatedObject(NSUserDefaults.standardUserDefaults,
                                     @selector(LCTVMVP8TraceHistory),
                                     timer,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{ LCTVMVP8InstallPanelIfNeeded(); });
                        }];
        });
    }
}
