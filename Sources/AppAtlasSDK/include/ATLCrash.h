#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The crash module: native crashes (mach exceptions, signals, uncaught
/// NSExceptions and Swift runtime traps), main-thread hangs, and the deaths
/// nothing in-process can see (out-of-memory and watchdog kills, inferred at
/// the next start; MetricKit on iOS 14+ / macOS 12+ fills what the handlers
/// missed) on their own; handled errors and context when the app offers them.
/// Nothing to wire beyond Atlas.start:
///
///     [Atlas startWithKey:@"sdk_…"];
///     [ATLCrash setUserId:@"u-123"];
///     [ATLCrash setKey:@"screen" value:@"checkout"];
///     [ATLCrash leaveBreadcrumb:@"cart" message:@"add"];
///     [ATLCrash log:@"cart total recomputed"];
///     [ATLCrash recordError:error];
///
/// Under a debugger the native hooks stay uninstalled — LLDB and a mach
/// exception server cannot share a port — and everything else still runs.
NS_SWIFT_NAME(AtlasCrash)
@interface ATLCrash : NSObject

/// Called by Atlas through NSClassFromString; not application API.
+ (void)boot;

/// Your own id for the signed-in user; nil clears it. Never required.
+ (void)setUserId:(nullable NSString *)userId;

/// Up to 64 keys ride every report; a nil value removes the key.
+ (void)setKey:(NSString *)name value:(nullable NSString *)value;

/// The last 100 are kept and attached to the next report.
+ (void)leaveBreadcrumb:(NSString *)category message:(NSString *)message;

/// A line in the rolling log: the newest 64 KB ride the next report.
+ (void)log:(NSString *)line;

/// A caught error worth knowing about; grouped apart from crashes, never
/// fatal. The stack is where this is called from. Quiet before Atlas.start.
+ (void)recordError:(NSError *)error NS_SWIFT_NAME(recordError(_:));

/// A caught exception: its own stack, when it has one, else the caller's.
+ (void)recordException:(NSException *)exception NS_SWIFT_NAME(recordException(_:));

/// Consent: off, nothing is collected or sent, and the choice outlives the
/// process. On by default. Takes effect at once for reports; sessions and
/// the native hooks follow from the next start.
+ (void)setEnabled:(BOOL)enabled;

/// Whether the previous run ended in a crash, a hang kill or an
/// out-of-memory kill this SDK recorded.
+ (BOOL)crashedLastRun;

@end

NS_ASSUME_NONNULL_END
