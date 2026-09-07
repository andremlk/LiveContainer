#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void LCTVMVP8TraceEvent(NSString *event);
FOUNDATION_EXPORT NSArray<NSString *> *LCTVMVP8TraceHistory(void);
FOUNDATION_EXPORT void LCTVMVP8TraceClear(void);

NS_ASSUME_NONNULL_END
