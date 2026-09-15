#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The device and app facts every module shares, snapshotted once at start
/// and carried in each envelope's header as `device` and `app` blocks. All
/// non-identifying — the standard crash-SDK set, nothing that names a device
/// or a person.
@interface ATLDeviceContext : NSObject

+ (NSDictionary<NSString *, id> *)snapshot;

@end

NS_ASSUME_NONNULL_END
