#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ATLCore;
@class ATLCrashScope;

/// The platform-free half of the crash module: one session per process,
/// handled errors, and the reports that arrive at the next start — a native
/// crash the C core wrote, a kill the run state inferred, a diagnostic
/// MetricKit delivered. Nothing here runs on the crash path itself; the
/// network is not trusted at the moment of a crash, and neither is the heap.
@interface ATLCrashReporter : NSObject

- (instancetype)initWithCore:(ATLCore *)core scope:(ATLCrashScope *)scope;

@property (nonatomic, readonly) NSString *sessionId;
@property (nonatomic, readonly) NSTimeInterval startedAt;
@property (nonatomic, readonly) NSString *startedAtIso;
/// Off, nothing is written or sent.
@property (nonatomic) BOOL enabled;
/// Set by whoever finds the previous run's death: a native report, a kill.
@property (nonatomic) BOOL crashedLastRun;

/// Opens the session. `previousTimeToCrash` is how far into the previous
/// run it died, or a negative value when it did not: a crash inside the
/// launch window makes this start flush before anything else happens.
- (void)installWithPreviousTimeToCrash:(NSTimeInterval)previousTimeToCrash;

/// A handled error: reported, grouped apart from crashes, never fatal.
- (void)recordError:(NSError *)error;
- (void)recordException:(NSException *)exception;

/// A native crash the C core wrote to `path` in an earlier run, with the
/// scope and run state that process last persisted. The file is removed.
/// Returns the crash instant, or a negative value when there was no report.
- (NSTimeInterval)reportPendingNativeAt:(NSString *)path
                          scopeSnapshot:(nullable NSDictionary *)scope
                            previousRun:(nullable NSDictionary *)previousRun;

/// A death with no report of its own: an out-of-memory or watchdog kill
/// inferred from the run state, a MetricKit crash diagnostic. `threads` and
/// `context` may be nil; `sessionStatus` is `crashed` or `abnormal`.
- (void)reportExitAt:(NSTimeInterval)at
           sessionId:(nullable NSString *)sessionId
           mechanism:(NSString *)mechanism
                type:(NSString *)type
             message:(NSString *)message
              frames:(nullable NSArray *)frames
             threads:(nullable NSArray *)threads
             context:(nullable NSDictionary *)context
       sessionStatus:(NSString *)sessionStatus;

/// The watchdog's finding: reported as `anr`, fatal to the session's
/// crash-free count only if the OS then kills the app (the run state says).
- (void)reportHangWithFrames:(NSArray *)frames stuckFor:(NSTimeInterval)seconds;

/// A non-fatal diagnostic the OS delivered (CPU or disk-write exception).
- (void)reportDiagnosticAt:(NSTimeInterval)at
                 mechanism:(NSString *)mechanism
                      type:(NSString *)type
                   message:(NSString *)message
                    frames:(nullable NSArray *)frames
                   threads:(nullable NSArray *)threads
                   context:(nullable NSDictionary *)context;

/// This run's facts plus its start and age, for a report's `context`.
- (NSMutableDictionary<NSString *, id> *)contextAt:(NSTimeInterval)at;

@end

NS_ASSUME_NONNULL_END
