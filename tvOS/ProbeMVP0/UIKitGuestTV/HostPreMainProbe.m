#import "HostPreMainProbe.h"

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <stdlib.h>

static NSString *LCTVEnv(NSString *name) {
    const char *value = getenv(name.UTF8String);
    return value ? ([NSString stringWithUTF8String:value] ?: @"(invalid UTF-8)") : nil;
}

static NSString *LCTVExecutablePath(void) {
    char path[PATH_MAX] = {0};
    uint32_t size = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0) {
        return [NSString stringWithUTF8String:path] ?: @"(invalid UTF-8)";
    }
    return [NSString stringWithFormat:@"(buffer too small; required=%u)", size];
}

static NSString *LCTVCFBundleID(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return @"(nil)";
    CFStringRef identifier = CFBundleGetIdentifier(bundle);
    return identifier ? [(__bridge NSString *)identifier copy] : @"(nil)";
}

static NSString *LCTVCFBundlePath(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return @"(nil)";
    CFURLRef url = CFBundleCopyBundleURL(bundle);
    if (!url) return @"(nil)";
    NSString *path = [(__bridge NSURL *)url path] ?: @"(nil)";
    CFRelease(url);
    return path;
}

BOOL LCTVHostPreMainProbeEnabled(void) {
    return [LCTVEnv(@"LCTV_HOST_PREMAIN_PROBE") isEqualToString:@"1"];
}

BOOL LCTVHostPreMainProbePassed(void) {
    NSString *expectedBundle = LCTVEnv(@"LCTV_HOST_EXPECTED_BUNDLE_ID");
    NSString *expectedExec = LCTVEnv(@"LCTV_HOST_EXPECTED_EXEC_PATH");
    NSString *expectedHome = LCTVEnv(@"LCTV_HOST_EXPECTED_HOME");
    NSString *expectedProcess = LCTVEnv(@"LCTV_HOST_EXPECTED_PROCESS");
    if (!expectedBundle || !expectedExec || !expectedHome || !expectedProcess) return NO;

    NSString *home = LCTVEnv(@"HOME");
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:expectedBundle] &&
           [LCTVCFBundleID() isEqualToString:expectedBundle] &&
           [LCTVExecutablePath() isEqualToString:expectedExec] &&
           [home isEqualToString:expectedHome] &&
           [NSHomeDirectory() isEqualToString:expectedHome] &&
           [NSProcessInfo.processInfo.processName isEqualToString:expectedProcess];
}

NSString *LCTVHostPreMainProbeTitle(void) {
    return LCTVHostPreMainProbePassed() ? @"MVP5P HOST PREMAIN PASS" : @"MVP5P HOST PREMAIN FAIL";
}

NSString *LCTVHostPreMainProbeStatus(void) {
    return LCTVEnv(@"LCTV_HOST_RUNTIME_STATUS") ?: @"(host runtime status missing)";
}

NSString *LCTVHostPreMainProbeExpectation(void) {
    return @"The host must virtualize NSBundle + CFBundle + executable path + HOME + NSHomeDirectory + processName before the guest enters LC_MAIN. The guest installs no identity hooks in this mode.";
}

NSString *LCTVHostPreMainProbeSnapshot(void) {
    NSString *home = LCTVEnv(@"HOME") ?: @"(unset)";
    return [NSString stringWithFormat:
            @"NSBundle.mainBundle.bundleID=%@\n"
             "NSBundle.mainBundle.bundlePath=%@\n"
             "CFBundleGetMainBundle.bundleID=%@\n"
             "CFBundleGetMainBundle.bundlePath=%@\n"
             "_NSGetExecutablePath=%@\n"
             "HOME=%@\n"
             "NSHomeDirectory=%@\n"
             "processName=%@",
            NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
            NSBundle.mainBundle.bundlePath ?: @"(nil)",
            LCTVCFBundleID(),
            LCTVCFBundlePath(),
            LCTVExecutablePath(),
            home,
            NSHomeDirectory() ?: @"(nil)",
            NSProcessInfo.processInfo.processName ?: @"(nil)"];
}
