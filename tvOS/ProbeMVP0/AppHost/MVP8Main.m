#import <Foundation/Foundation.h>
#import "MVP8Trace.h"

// Compile the proven MVP7H loader unchanged, but rename its process entry point.
// This keeps MVP7J/MVP7H frozen while MVP8 adds an outer tracing shell.
#define main LCTVMVP7HOriginalMain
#include "MVP7HMain.m"
#undef main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *armed = [defaults stringForKey:@"LCTVMVP7HSelectedSlotNextLaunch"];
        if (armed.length) {
            LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_ENTER armed=%@", armed]);
        } else {
            LCTVMVP8TraceEvent(@"HOST_MAIN_ENTER no-guest-armed");
        }

        int result = LCTVMVP7HOriginalMain(argc, argv);
        LCTVMVP8TraceEvent([NSString stringWithFormat:@"HOST_MAIN_RETURN result=%d", result]);
        return result;
    }
}
