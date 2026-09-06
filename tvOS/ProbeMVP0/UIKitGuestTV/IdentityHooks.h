#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, LCTVIdentityProbeMode) {
    LCTVIdentityProbeModeBaseline = 0,
    LCTVIdentityProbeModeNSBundle = 1,
    LCTVIdentityProbeModeCFBundle = 2,
    LCTVIdentityProbeModeExecutablePath = 3,
    LCTVIdentityProbeModeHome = 4,
    LCTVIdentityProbeModeProcessName = 5,
    LCTVIdentityProbeModeAll = 6,
};

__attribute__((visibility("default")))
void LCTVSetIdentityProbeMode(int mode);

void LCTVPrepareIdentityBeforeUIApplicationMain(void);
BOOL LCTVApplyIdentityAtDidFinishLaunching(void);
BOOL LCTVIdentityProbePassed(void);
NSString *LCTVIdentityProbeTitle(void);
NSString *LCTVIdentityProbeStatus(void);
NSString *LCTVIdentityProbeExpectation(void);
NSString *LCTVIdentitySnapshot(void);
