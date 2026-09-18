#import "ATLCrash.h"

#import "ATLCore.h"
#import "ATLCrashFiles.h"
#import "ATLCrashReport.h"
#import "ATLCrashReporter.h"
#import "ATLCrashScope.h"
#import "ATLHangWatchdog.h"
#import "ATLMetricKitBridge.h"
#import "ATLNativeReport.h"
#import "ATLRunState.h"
#import "Atlas.h"

#include <float.h>
#include <string.h>

#include "atl_crash_capture.h"

static NSString *const ATLEnabledKey = @"dev.appatlas.sdk.crash.enabled";
// The C core writes here; read and cleared at the next start.
static NSString *const ATLNativeReportFile = @"native-crash.txt";
// The scope as last written, for a native crash to carry at the next start.
static NSString *const ATLScopeFile = @"crash-scope.json";
static NSString *const ATLRunStateFile = @"run-state.json";
static const NSTimeInterval ATLSnapshotDebounce = 1.0;
static const NSTimeInterval ATLHangTimeout = 5.0;

// Context set before start is kept: an app may name its user first.
static ATLCrashScope *ATLScope = nil;
static ATLCrashReporter *ATLReporter = nil;
static ATLRunState *ATLRun = nil;
static ATLHangWatchdog *ATLWatchdog = nil;
static ATLMetricKitBridge *ATLMetricKit = nil;
static NSString *ATLScopePath = nil;
static dispatch_queue_t ATLSnapshots = nil;
static BOOL ATLSnapshotPending = NO;
static NSUncaughtExceptionHandler *ATLPreviousExceptionHandler = NULL;

/// The uncaught-exception path. Every Objective-C read happens here, on a
/// process that is still whole; the C core then stops the other threads and
/// writes. The runtime aborts afterwards, and the SIGABRT handler steps
/// aside because the report is already on disk.
static void ATLHandleUncaughtException(NSException *exception) {
    char name[256] = {0};
    char reason[4096] = {0};
    uintptr_t addresses[128];
    int count = 0;

    strlcpy(name, exception.name.UTF8String ?: "NSException", sizeof(name));
    strlcpy(reason, exception.reason.UTF8String ?: "", sizeof(reason));

    NSArray<NSNumber *> *raised = exception.callStackReturnAddresses;

    if (raised.count == 0) {
        // Raised without a stack (a bare +raise on some runtimes): this
        // thread's own, then.
        raised = [NSThread callStackReturnAddresses];
    }

    for (NSNumber *address in raised) {
        if (count == 128) break;
        addresses[count++] = (uintptr_t) address.unsignedLongLongValue;
    }

    atl_crash_write_exception(name, reason, addresses, count);

    if (ATLPreviousExceptionHandler != NULL) {
        ATLPreviousExceptionHandler(exception);
    }
}

@interface ATLCrash ()

+ (void)bootWithStateDirectory:(NSString *)directory;

@end

@implementation ATLCrash

+ (void)initialize {
    if (self == [ATLCrash class]) {
        ATLScope = [[ATLCrashScope alloc] init];
        ATLSnapshots = dispatch_queue_create("dev.appatlas.sdk.crash.snapshots", DISPATCH_QUEUE_SERIAL);
    }
}

+ (void)boot {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        ?: NSTemporaryDirectory();
    [self bootWithStateDirectory:[support stringByAppendingPathComponent:@"atlas/crash"]];
}

+ (void)bootWithStateDirectory:(NSString *)directory {
    ATLCore *core = [Atlas core];

    @synchronized (self) {
        if (ATLReporter != nil || core == nil) {
            return;
        }

        // A SwiftUI preview is not an app run; nothing here should count.
        if ([ATLRunState isPreview]) {
            return;
        }

        ATLReporter = [[ATLCrashReporter alloc] initWithCore:core scope:ATLScope];
    }

    ATLCrashReporter *reporter = ATLReporter;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [defaults objectForKey:ATLEnabledKey] == nil || [defaults boolForKey:ATLEnabledKey];
    reporter.enabled = enabled;

    ATLCrashEnsureDirectory(directory);
    NSString *nativePath = [directory stringByAppendingPathComponent:ATLNativeReportFile];
    NSString *runStatePath = [directory stringByAppendingPathComponent:ATLRunStateFile];
    ATLScopePath = [directory stringByAppendingPathComponent:ATLScopeFile];

    if (!enabled) {
        // Off: nothing collected, and nothing a re-enable could send late.
        for (NSString *stale in @[nativePath, runStatePath, ATLScopePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:stale error:NULL];
        }

        return;
    }

    ATLRunState *run = [[ATLRunState alloc] initWithPath:runStatePath sessionId:reporter.sessionId startedAt:reporter.startedAt];
    ATLRun = run;
    NSDictionary *previousRun = run.previous;
    NSDictionary *scopeSnapshot = [ATLCrashScope readFrom:ATLScopePath];

    // How far into the previous run it died, when a report is waiting: a
    // launch crash makes this start send before anything else happens.
    NSTimeInterval previousTimeToCrash = -1;
    NSTimeInterval crashedAt = [ATLNativeReport peekCrashedAt:nativePath];
    NSTimeInterval previousStart = [previousRun[@"startedAt"] doubleValue];

    if (crashedAt > 0) {
        reporter.crashedLastRun = YES;
        previousTimeToCrash = previousStart > 0 ? MAX(crashedAt - previousStart, 0) : DBL_MAX;
    }

    [reporter installWithPreviousTimeToCrash:previousTimeToCrash];

    // The native hooks: mach first, signals behind them, NSException on top.
    // Under a debugger the C core refuses both, and says so once.
    unsigned hooks = atl_crash_install(nativePath.fileSystemRepresentation, ATL_CRASH_MACH | ATL_CRASH_SIGNALS);

    if (hooks == 0 && atl_crash_debugger_attached()) {
        NSLog(@"[Atlas] crash: native hooks not installed under the debugger; everything else runs");
    }

    ATLPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&ATLHandleUncaughtException);

    [self observeLifecycle];

    // The hang watchdog: never where a frozen main thread is not a hang.
    if (![ATLRunState isSimulator] && ![ATLRunState isExtension] && !atl_crash_debugger_attached()) {
        ATLWatchdog = [[ATLHangWatchdog alloc] initWithTimeout:ATLHangTimeout onHang:^(NSArray *frames, NSTimeInterval stuckFor) {
            [run setHanging:YES frames:frames];
            [run persist];
            [reporter reportHangWithFrames:frames stuckFor:stuckFor];
        } onRecover:^{
            [run setHanging:NO frames:nil];
            [run persist];
        }];
        [ATLWatchdog start];
    }

    ATLMetricKit = [[ATLMetricKitBridge alloc] initWithReporter:reporter];
    [ATLMetricKit subscribe];

    // The previous run's death, off the main thread: a native report, or a
    // kill inferred from how that run's state was left.
    NSThread *deaths = [[NSThread alloc] initWithBlock:^{
        NSTimeInterval reported = [reporter reportPendingNativeAt:nativePath scopeSnapshot:scopeSnapshot previousRun:previousRun];

        if (reported < 0) {
            [self reportInferredKillFrom:run previousRun:previousRun reporter:reporter];
        }

        // This run's state and scope start fresh on disk.
        [run persist];
        [ATLScope persistTo:ATLScopePath];
    }];
    deaths.name = @"atlas-crash-exits";
    [deaths start];
}

+ (void)reportInferredKillFrom:(ATLRunState *)run
                   previousRun:(NSDictionary *)previousRun
                      reporter:(ATLCrashReporter *)reporter {
    NSString *kind = [run previousKillType];

    if (kind == nil) {
        return;
    }

    // When it died is unknown; when it last wrote its state is the closest.
    NSTimeInterval at = run.previousEndedAt > 0 ? run.previousEndedAt : [[NSDate date] timeIntervalSince1970];
    NSString *sessionId = [previousRun[@"sessionId"] isKindOfClass:[NSString class]] ? previousRun[@"sessionId"] : nil;
    NSMutableDictionary *context = [NSMutableDictionary dictionary];

    if ([previousRun[@"facts"] isKindOfClass:[NSDictionary class]]) {
        [context addEntriesFromDictionary:previousRun[@"facts"]];
    }

    NSTimeInterval started = [previousRun[@"startedAt"] doubleValue];

    if (started > 0) {
        context[@"startedAt"] = [ATLCore iso:started];
        context[@"timeToCrashMs"] = @((long long) (MAX(at - started, 0) * 1000.0));
    }

    NSString *message = [kind isEqualToString:@"WatchdogTermination"]
        ? @"The system ended the app while its main thread was unresponsive"
        : @"The system ended the app in the foreground without a crash: out of memory";

    [reporter reportExitAt:at sessionId:sessionId mechanism:ATLMechanismExitInfo type:kind message:message
                    frames:[kind isEqualToString:@"WatchdogTermination"] ? [run previousHangFrames] : nil
                   threads:nil context:context sessionStatus:@"abnormal"];
    reporter.crashedLastRun = YES;
}

/// The app's own lifecycle, by notification name so the module links
/// without UIKit or AppKit; the names are the strings the constants hold.
+ (void)observeLifecycle {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSDictionary<NSString *, void (^)(void)> *reactions = @{
        @"UIApplicationDidBecomeActiveNotification": ^{ [ATLRun setActive:YES]; [ATLRun setForeground:YES]; },
        @"UIApplicationWillResignActiveNotification": ^{ [ATLRun setActive:NO]; },
        @"UIApplicationDidEnterBackgroundNotification": ^{ [ATLRun setForeground:NO]; },
        @"UIApplicationWillEnterForegroundNotification": ^{ [ATLRun setForeground:YES]; },
        @"UIApplicationWillTerminateNotification": ^{ [ATLRun noteCleanExit]; },
        @"NSApplicationDidBecomeActiveNotification": ^{ [ATLRun setActive:YES]; [ATLRun setForeground:YES]; },
        @"NSApplicationWillResignActiveNotification": ^{ [ATLRun setActive:NO]; },
        @"NSApplicationWillTerminateNotification": ^{ [ATLRun noteCleanExit]; },
    };

    for (NSString *name in reactions) {
        void (^react)(void) = reactions[name];

        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            react();

            // Termination is the one that cannot wait for a debounce.
            if ([name hasSuffix:@"WillTerminateNotification"]) {
                [ATLRun persist];
            } else {
                [self snapshotSoon];
            }
        }];
    }
}

// --- the scope ---------------------------------------------------------------------------

+ (void)setUserId:(NSString *)userId {
    [ATLScope setUserId:userId];
    [self snapshotSoon];
}

+ (void)setKey:(NSString *)name value:(NSString *)value {
    [ATLScope setKey:name value:value];
    [self snapshotSoon];
}

+ (void)leaveBreadcrumb:(NSString *)category message:(NSString *)message {
    [ATLScope leaveBreadcrumb:category message:message level:nil at:[[NSDate date] timeIntervalSince1970]];
    [self snapshotSoon];
}

+ (void)log:(NSString *)line {
    [ATLScope log:line at:[[NSDate date] timeIntervalSince1970]];
    [self snapshotSoon];
}

/// The scope and run state reach disk within a second of a change,
/// coalesced: a native crash is read at the next start, from a process that
/// is gone, and these files are what it remembers by. Never on the caller's
/// thread.
+ (void)snapshotSoon {
    @synchronized (self) {
        if (ATLScopePath == nil || ATLRun == nil || ATLSnapshotPending) {
            return;
        }

        ATLSnapshotPending = YES;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (ATLSnapshotDebounce * NSEC_PER_SEC)), ATLSnapshots, ^{
        @synchronized (self) {
            ATLSnapshotPending = NO;
        }

        [ATLScope persistTo:ATLScopePath];
        [ATLRun persist];
    });
}

// --- reports ---------------------------------------------------------------------------------

+ (void)recordError:(NSError *)error {
    [ATLReporter recordError:error];
}

+ (void)recordException:(NSException *)exception {
    [ATLReporter recordException:exception];
}

+ (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:ATLEnabledKey];
    ATLReporter.enabled = enabled;
}

+ (BOOL)crashedLastRun {
    return ATLReporter.crashedLastRun;
}

@end
