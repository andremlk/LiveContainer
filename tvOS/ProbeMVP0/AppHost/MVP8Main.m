#import <Foundation/Foundation.h>
#import <sys/types.h>
#import <unistd.h>
#import "MVP8Trace.h"

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static BOOL LCTVMVP8IsDebugged(void) {
    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & CS_DEBUGGED) != 0;
}

// Compile the proven MVP7H loader unchanged, but rename its process entry point.
// This keeps the MVP7J/MVP7H baseline frozen while MVP8 adds an outer tracing/JIT gate.
#define main LCTVMVP7HOriginalMain
#include "MVP7HMain.m"
#undef main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *armed = [defaults stringForKey:@"LCTVMVP7HSelectedSlotNextLaunch"];
        BOOL debugged = LCTVMVP8IsDebugged();

        LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_ENTER debugged=%@ armed=%@",
                            debugged ? @"YES" : @"NO",
                            armed.length ? armed : @"none"]);

        // An armed guest is consumed from process main, before the host UIKit UI exists.
        // Therefore attaching after a normal manual reopen is too late.  Refuse that unsafe
        // path and require `lctv jit launch`, which DVT-starts the process suspended and
        // debugserver-attaches before this main executes.
        if (armed.length && !debugged) {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"JIT_GATE_BLOCKED guest=%@", armed]);
            [defaults removeObjectForKey:@"LCTVMVP7HSelectedSlotNextLaunch"];
            [defaults setObject:@"MVP8 JIT REQUIRED: guest launch blocked before dlopen. Arm it again, then run: lctv jit launch"
                       forKey:@"LCTVMVP7HResult"];
            [defaults synchronize];
        } else if (armed.length) {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"JIT_GATE_PASS guest=%@", armed]);
        } else {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_UI_BOOT debugged=%@", debugged ? @"YES" : @"NO"]);
        }

        int result = LCTVMVP7HOriginalMain(argc, argv);
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_RETURN result=%d", result]);
        return result;
    }
}
