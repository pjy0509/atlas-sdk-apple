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

#include <TargetConditionals.h>
#include <float.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>

#include "atl_crash_capture.h"

// Info.plist keys: the start nobody has to write, and AppKit's one switch.
static NSString *const ATLPlistKey = @"AtlasSDKKey";
static NSString *const ATLPlistBaseURL = @"AtlasBaseURL";
#if TARGET_OS_OSX
static NSString *const ATLPlistCrashOnNSException = @"AtlasCrashOnNSException";
static NSString *const ATLMechanismAppKitReported = @"nsApplicationReportException";
#endif

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
// Set before the start when the caller wants the state somewhere of its own.
static NSString *ATLStateDirectory = nil;
static dispatch_queue_t ATLSnapshots = nil;
static BOOL ATLSnapshotPending = NO;
static NSUncaughtExceptionHandler *ATLPreviousExceptionHandler = NULL;
static dispatch_source_t ATLMemoryPressure = nil;

#if TARGET_OS_OSX
static IMP ATLOriginalReportException = NULL;

static void ATLReportException(id self, SEL _cmd, NSException *exception);
#endif

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
+ (NSString *)stateDirectory;
+ (void)setStateDirectory:(NSString *)directory;
+ (void)leaveAutoBreadcrumb:(NSString *)category message:(NSString *)message;

@end

/// The start nobody has to write. dyld runs this before main, after
/// Foundation is up: the C capture core goes in at once (a crash in the
/// app's own initializers is already caught), and an `AtlasSDKKey` in the
/// Info.plist starts the rest on the main queue's first turn. An app that
/// also calls Atlas.start loses nothing; a second start is a no-op. Nothing
/// happens in a SwiftUI preview, under XCTest, or once the app has opted out.
__attribute__((constructor)) static void ATLCrashPreload(void) {
    @autoreleasepool {
        if ([ATLRunState isPreview] || [ATLRunState isTesting]) {
            return;
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        if ([defaults objectForKey:ATLEnabledKey] != nil && ![defaults boolForKey:ATLEnabledKey]) {
            return;
        }

        NSString *directory = [ATLCrash stateDirectory];
        ATLCrashEnsureDirectory(directory);
        atl_crash_install([directory stringByAppendingPathComponent:ATLNativeReportFile].fileSystemRepresentation,
                          ATL_CRASH_MACH | ATL_CRASH_SIGNALS);

        NSBundle *bundle = [NSBundle mainBundle];
        NSString *key = [bundle objectForInfoDictionaryKey:ATLPlistKey];
        NSString *baseUrl = [bundle objectForInfoDictionaryKey:ATLPlistBaseURL];

        if ([key isKindOfClass:[NSString class]] && key.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([baseUrl isKindOfClass:[NSString class]] && baseUrl.length > 0) {
                    [Atlas startWithKey:key baseUrl:baseUrl];
                } else {
                    [Atlas startWithKey:key];
                }
            });
        }
    }
}

@implementation ATLCrash

+ (void)initialize {
    if (self == [ATLCrash class]) {
        ATLScope = [[ATLCrashScope alloc] init];
        ATLSnapshots = dispatch_queue_create("dev.appatlas.sdk.crash.snapshots", DISPATCH_QUEUE_SERIAL);
    }
}

/// Where the crash state lives. Set before Atlas.start, it decides where
/// this run writes; the gate is the only caller, since an app has no reason
/// to move it.
+ (void)setStateDirectory:(NSString *)directory {
    @synchronized (self) {
        ATLStateDirectory = [directory copy];
    }
}

+ (NSString *)stateDirectory {
    @synchronized (self) {
        if (ATLStateDirectory != nil) {
            return ATLStateDirectory;
        }
    }

    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        ?: NSTemporaryDirectory();

    return [support stringByAppendingPathComponent:@"atlas/crash"];
}

+ (void)boot {
    [self bootWithStateDirectory:[self stateDirectory]];
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
    [self observeMemoryPressure];
    [self hookAppKit];

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
        // A main thread that is not on screen is not one a user waits on,
        // and a suspended app is not hung.
        ATLWatchdog.isLive = ^BOOL{ return run.isForeground; };
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
        : [run previousMemoryPressure] != nil
            ? [NSString stringWithFormat:@"The system ended the app in the foreground without a crash: out of memory (memory pressure %@)", [run previousMemoryPressure]]
            : @"The system ended the app in the foreground without a crash: out of memory";

    [reporter reportExitAt:at sessionId:sessionId mechanism:ATLMechanismExitInfo type:kind message:message
                    frames:[kind isEqualToString:@"WatchdogTermination"] ? [run previousHangFrames] : nil
                   threads:nil context:context sessionStatus:@"abnormal"];
    reporter.crashedLastRun = YES;
}

/// The app's own lifecycle and the events around it, by notification name
/// so the module links without UIKit or AppKit; the names are the strings
/// the constants hold. Each one moves the run state, leaves a breadcrumb,
/// or both. All of it is notification-shaped: nothing is swizzled, and no
/// event here needs a permission.
+ (void)observeLifecycle {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSDictionary<NSString *, void (^)(NSNotification *)> *reactions = @{
        // iOS, tvOS, visionOS
        @"UIApplicationDidBecomeActiveNotification": ^(NSNotification *note) {
            [ATLRun setActive:YES]; [ATLRun setForeground:YES]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"active"];
        },
        @"UIApplicationWillResignActiveNotification": ^(NSNotification *note) {
            [ATLRun setActive:NO]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"inactive"];
        },
        @"UIApplicationDidEnterBackgroundNotification": ^(NSNotification *note) {
            [ATLRun setForeground:NO]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"background"];
        },
        @"UIApplicationWillEnterForegroundNotification": ^(NSNotification *note) {
            [ATLRun setForeground:YES]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"foreground"];
        },
        @"UIApplicationWillTerminateNotification": ^(NSNotification *note) {
            [ATLRun noteCleanExit]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"terminate"];
        },
        @"UIApplicationDidReceiveMemoryWarningNotification": ^(NSNotification *note) {
            [ATLRun setMemoryPressure:@"warning"]; [self leaveAutoBreadcrumb:@"app.memory" message:@"memory warning"];
        },
        @"UIDeviceOrientationDidChangeNotification": ^(NSNotification *note) {
            [self leaveAutoBreadcrumb:@"device.orientation" message:[self orientationOf:note.object]];
        },
        @"UIKeyboardDidShowNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.keyboard" message:@"shown"]; },
        @"UIKeyboardDidHideNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.keyboard" message:@"hidden"]; },
        @"UIApplicationUserDidTakeScreenshotNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"device" message:@"screenshot"]; },
        @"UISceneDidActivateNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.scene" message:@"activated"]; },
        @"UISceneWillDeactivateNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.scene" message:@"deactivated"]; },
        @"UISceneDidDisconnectNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.scene" message:@"disconnected"]; },
        @"UIWindowDidBecomeKeyNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.window" message:@"key"]; },
        // Both platforms
        @"NSProcessInfoThermalStateDidChangeNotification": ^(NSNotification *note) {
            [self leaveAutoBreadcrumb:@"device.thermal" message:[ATLRunState facts][@"thermalState"] ?: @"changed"];
        },
        @"NSProcessInfoPowerStateDidChangeNotification": ^(NSNotification *note) {
            if (@available(iOS 9.0, macOS 12.0, *)) {
                [self leaveAutoBreadcrumb:@"device.power"
                                  message:[NSProcessInfo processInfo].isLowPowerModeEnabled ? @"low power on" : @"low power off"];
            }
        },
        @"NSSystemTimeZoneDidChangeNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"system" message:@"time zone changed"]; },
        @"NSSystemClockDidChangeNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"system" message:@"clock changed"]; },
        // macOS
        @"NSApplicationDidBecomeActiveNotification": ^(NSNotification *note) {
            [ATLRun setActive:YES]; [ATLRun setForeground:YES]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"active"];
        },
        @"NSApplicationWillResignActiveNotification": ^(NSNotification *note) {
            [ATLRun setActive:NO]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"inactive"];
        },
        @"NSApplicationDidHideNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"hidden"]; },
        @"NSApplicationDidUnhideNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"unhidden"]; },
        @"NSApplicationWillTerminateNotification": ^(NSNotification *note) {
            [ATLRun noteCleanExit]; [self leaveAutoBreadcrumb:@"app.lifecycle" message:@"terminate"];
        },
        @"NSWindowDidBecomeKeyNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.window" message:@"key"]; },
        @"NSWindowWillCloseNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.window" message:@"closed"]; },
        @"NSWindowDidEnterFullScreenNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.window" message:@"full screen"]; },
        @"NSWindowDidExitFullScreenNotification": ^(NSNotification *note) { [self leaveAutoBreadcrumb:@"ui.window" message:@"left full screen"]; },
    };

    for (NSString *name in reactions) {
        void (^react)(NSNotification *) = reactions[name];

        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            react(note);

            // Termination is the one that cannot wait for a debounce.
            if ([name hasSuffix:@"WillTerminateNotification"]) {
                [ATLRun persist];
            } else {
                [self snapshotSoon];
            }
        }];
    }
}

+ (NSString *)orientationOf:(id)device {
    // UIDevice.orientation, by selector: no UIKit link. 1 and 2 are portrait,
    // 3 and 4 landscape, 5 and 6 flat.
    NSInteger value = 0;

    if ([device respondsToSelector:NSSelectorFromString(@"orientation")]) {
        value = ((NSInteger (*)(id, SEL)) objc_msgSend)(device, NSSelectorFromString(@"orientation"));
    }

    switch (value) {
        case 1: case 2: return @"portrait";
        case 3: case 4: return @"landscape";
        case 5: case 6: return @"flat";
        default: return @"unknown";
    }
}

/// The kernel's own word on memory, which arrives a little before UIKit's
/// warning and on macOS too: the level rides the run state, so a kill in
/// the next minute reads as out of memory with a reason attached.
+ (void)observeMemoryPressure {
    ATLMemoryPressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                               DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN
                                                   | DISPATCH_MEMORYPRESSURE_CRITICAL, ATLSnapshots);

    if (ATLMemoryPressure == nil) {
        return;
    }

    dispatch_source_t source = ATLMemoryPressure;
    dispatch_source_set_event_handler(source, ^{
        unsigned long level = dispatch_source_get_data(source);
        NSString *name = (level & DISPATCH_MEMORYPRESSURE_CRITICAL) ? @"critical"
            : (level & DISPATCH_MEMORYPRESSURE_WARN) ? @"warn" : @"normal";

        [ATLRun setMemoryPressure:name];

        if (![name isEqualToString:@"normal"]) {
            [self leaveAutoBreadcrumb:@"app.memory" message:[@"memory pressure " stringByAppendingString:name]];
        }

        [ATLRun persist];
    });
    dispatch_resume(source);
}

/// AppKit catches every exception thrown on the main thread and carries on,
/// so the uncaught-exception handler never hears of them. Its `reportException:`
/// is where they surface; recorded from there as errors, with the exception's
/// own stack, and passed through. `AtlasCrashOnNSException` in the Info.plist
/// makes them fatal instead (NSApplicationCrashOnExceptions), which is
/// AppKit's own switch and a behaviour change an app must choose.
+ (void)hookAppKit {
#if TARGET_OS_OSX
    Class application = NSClassFromString(@"NSApplication");
    SEL selector = NSSelectorFromString(@"reportException:");
    Method method = application != Nil ? class_getInstanceMethod(application, selector) : NULL;

    if (method == NULL || ATLOriginalReportException != NULL) {
        return;
    }

    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:ATLPlistCrashOnNSException] boolValue]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"NSApplicationCrashOnExceptions": @YES}];
    }

    ATLOriginalReportException = method_setImplementation(method, (IMP) ATLReportException);
#endif
}

#if TARGET_OS_OSX
static void ATLReportException(id self, SEL _cmd, NSException *exception) {
    @try {
        [ATLReporter recordException:exception mechanism:ATLMechanismAppKitReported];
    } @catch (NSException *ours) {
        // Recording must never take the app with it.
    }

    if (ATLOriginalReportException != NULL) {
        ((void (*)(id, SEL, NSException *)) ATLOriginalReportException)(self, _cmd, exception);
    }
}
#endif

+ (void)leaveAutoBreadcrumb:(NSString *)category message:(NSString *)message {
    [ATLScope leaveBreadcrumb:category message:message level:nil at:[[NSDate date] timeIntervalSince1970]];
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
