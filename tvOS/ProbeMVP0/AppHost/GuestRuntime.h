#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

// MVP5 host-side identity virtualization is split around dlopen so the pieces
// that do not require the loaded Mach-O image are already active while dyld
// runs guest initializers. This mirrors the ordering used by upstream
// LiveContainer more closely than the original post-dlopen prototype.
BOOL LCTVPrepareHostGuestIdentityBeforeLoad(NSString *guestBundlePath,
                                            NSString *guestExecutablePath,
                                            NSString *guestBundleIdentifier,
                                            NSString *guestProcessName,
                                            NSString *guestHomePath,
                                            NSString ** _Nullable errorOut);

// Rebinds imports that can only be located once the guest image is loaded.
BOOL LCTVFinishHostGuestIdentityAfterLoad(const struct mach_header_64 *guestHeader,
                                          NSString ** _Nullable errorOut);

// Convenience wrapper retained for the synthetic MVP5P probe and diagnostics.
BOOL LCTVApplyHostGuestIdentity(const struct mach_header_64 *guestHeader,
                                NSString *guestBundlePath,
                                NSString *guestExecutablePath,
                                NSString *guestBundleIdentifier,
                                NSString *guestProcessName,
                                NSString *guestHomePath,
                                NSString ** _Nullable errorOut);

NS_ASSUME_NONNULL_END
