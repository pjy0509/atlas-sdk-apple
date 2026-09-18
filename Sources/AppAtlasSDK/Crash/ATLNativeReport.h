#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the line-based file the C capture core wrote for a crash and turns
/// it into a `crash` payload. Every kind — a mach exception, a signal, an
/// uncaught NSException — lands in the same shape: one exception, every
/// thread, the crashed one flagged, native frames with their image UUIDs.
///
/// FROZEN with the writer (atl_crash_capture.c): the line vocabulary.
@interface ATLNativeReport : NSObject

/// The payload, or nil for a file that stopped before `end` (a crash that
/// interrupted its own report) or names no crash at all. `crashedAt` is
/// returned through `at`, in epoch seconds.
+ (nullable NSMutableDictionary<NSString *, id> *)readFile:(NSString *)path crashedAt:(NSTimeInterval *)at;

/// The mechanism string for a report kind: mach, signal or exception.
+ (NSString *)mechanismOfKind:(NSString *)kind;

/// The crash instant alone, from the file's head, without reading the rest:
/// what the launch-crash fast path needs before anything else happens.
/// Negative when the file is absent or unreadable.
+ (NSTimeInterval)peekCrashedAt:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
