#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL LCTVRebindGuestImport(const char *symbolName,
                           void *replacement,
                           void * _Nullable * _Nullable originalOut,
                           NSUInteger * _Nullable reboundCountOut,
                           NSString * _Nullable * _Nullable errorOut);

NS_ASSUME_NONNULL_END
