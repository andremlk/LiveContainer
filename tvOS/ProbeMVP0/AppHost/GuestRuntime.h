#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

// Applies the identity virtualization that was validated independently in MVP4,
// but from the LiveContainerTV host against an arbitrary loaded guest image.
// This is the bridge required for MVP5: real guest executables do not contain
// LiveContainerTV's synthetic IdentityHooks code.
BOOL LCTVApplyHostGuestIdentity(const struct mach_header_64 *guestHeader,
                                NSString *guestBundlePath,
                                NSString *guestExecutablePath,
                                NSString *guestBundleIdentifier,
                                NSString *guestProcessName,
                                NSString *guestHomePath,
                                NSString ** _Nullable errorOut);

NS_ASSUME_NONNULL_END
