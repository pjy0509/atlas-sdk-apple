#import <Foundation/Foundation.h>

#import "ATLCore.h"

NS_ASSUME_NONNULL_BEGIN

/// The entry point: one line in application:didFinishLaunching.
///
///     [Atlas startWithKey:@"sdk_…"];
///
/// Modules (links, crash, push) attach to the core this creates; none of
/// them touch the network or the disk on their own.
@interface Atlas : NSObject

+ (void)startWithKey:(NSString *)sdkKey;

/// The base URL override exists for self-hosted and staging servers.
+ (void)startWithKey:(NSString *)sdkKey baseUrl:(NSString *)baseUrl;

/// The running core, for modules; nil before start (they stay quiet).
+ (nullable ATLCore *)core;

@end

NS_ASSUME_NONNULL_END
