#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ATLCrashReporter;

/// MetricKit (iOS 14+, macOS 12+), as the complement, never the replacement:
/// the OS delivers, up to a day later, crash diagnostics for deaths the
/// in-process hooks could not see — a crash before Atlas.start, a kill by
/// signal — plus CPU and disk-write exceptions nothing in-process reports at
/// all. Crash diagnostics are used only for a window in which this SDK
/// reported no crash of its own; otherwise the same death would count twice.
///
/// Loaded by name at runtime, so the module links on iOS 12 without the
/// framework and without a weak-link flag every package manager spells
/// differently.
@interface ATLMetricKitBridge : NSObject

- (instancetype)initWithReporter:(ATLCrashReporter *)reporter;

/// Subscribes when the OS has MetricKit; a no-op otherwise.
- (void)subscribe;

/// The instants this SDK reported a crash for, kept for the window check.
+ (void)noteOwnCrashAt:(NSTimeInterval)epochSeconds;

/// Flattens an MXCallStackTree's JSON into wire frames per thread; exposed
/// for the gate, which has no MetricKit to call it with.
+ (NSArray<NSDictionary *> *)threadsFromCallStackTree:(NSData *)json;

@end

NS_ASSUME_NONNULL_END
