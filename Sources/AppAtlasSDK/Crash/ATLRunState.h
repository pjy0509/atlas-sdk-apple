#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What this run knows about itself, kept on disk so the next run can tell
/// how this one ended. The OS gives an iOS process no exit record; a death
/// without a crash report, from the foreground, on the same boot and build,
/// with no debugger and no clean exit, is a kill — out of memory, or the
/// watchdog when the main thread was hung at the time. Every exclusion is
/// required (the server repo's docs/sdk-cautions.md §1.3): one missing ships
/// a false positive.
@interface ATLRunState : NSObject

- (instancetype)initWithPath:(NSString *)path sessionId:(NSString *)sessionId startedAt:(NSTimeInterval)startedAt;

/// The previous run's state, read once before this run's is written; nil
/// when there was none (first run, or a clean uninstall).
@property (nonatomic, readonly, nullable) NSDictionary<NSString *, id> *previous;

/// When the previous run last wrote its state: the closest thing to when it
/// died, for a death nothing timestamped. Zero without a previous run.
@property (nonatomic, readonly) NSTimeInterval previousEndedAt;

/// Whether the previous run, per its own record, ended in a kill we should
/// report: `nil`, or `OutOfMemory` / `WatchdogTermination`.
- (nullable NSString *)previousKillType;

/// The hang the watchdog saw last in the previous run, when it was hung as
/// it died: the frames to report the watchdog kill with.
- (nullable NSArray *)previousHangFrames;

/// Lifecycle facts, updated from the app's notifications.
- (void)setActive:(BOOL)active;
- (void)setForeground:(BOOL)foreground;
- (void)setHanging:(BOOL)hanging frames:(nullable NSArray *)frames;
- (void)noteCleanExit;

/// Persists now, atomically. Off the main thread where it can be.
- (void)persist;

/// Device and app facts at this instant, for a report's `context`.
+ (NSMutableDictionary<NSString *, id> *)facts;

/// Environment probes, read once.
+ (BOOL)isSimulator;
+ (BOOL)isExtension;
+ (BOOL)isPreview;
+ (BOOL)isPrewarmed;
+ (BOOL)isTestFlight;
+ (NSString *)executableUUID;

/// kern.boottime, rounded to the second: a launch-to-launch jitter of
/// microseconds would otherwise make every run look like a reboot.
+ (NSTimeInterval)bootTime;

@end

NS_ASSUME_NONNULL_END
