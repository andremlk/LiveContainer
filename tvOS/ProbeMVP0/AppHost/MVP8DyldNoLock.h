#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads the guest while temporarily bypassing dyld's recursive API lock only
/// for the calling thread. The libdyld vtable is restored before this returns.
FOUNDATION_EXPORT void * _Nullable LCTVMVP8FDlopenNoLock(const char *path,
                                                         int mode,
                                                         NSString * _Nullable * _Nullable errorOut);

NS_ASSUME_NONNULL_END
