#import "ATLCrashReporter.h"

#import "ATLCore.h"
#import "ATLCrashReport.h"
#import "ATLCrashScope.h"
#import "ATLMetricKitBridge.h"
#import "ATLNativeReport.h"
#import "ATLRunState.h"
#import "ATLSessionItems.h"

// A crash this soon after start is a launch crash: the next start sends it
// before anything else can crash the same way.
static const NSTimeInterval ATLLaunchWindow = 5.0;
static const NSTimeInterval ATLLaunchFlush = 2.0;

@implementation ATLCrashReporter {
    ATLCore *_core;
    ATLCrashScope *_scope;
    NSInteger _errors;
    BOOL _installed;
}

- (instancetype)initWithCore:(ATLCore *)core scope:(ATLCrashScope *)scope {
    self = [super init];

    if (self) {
        _core = core;
        _scope = scope;
        _sessionId = [ATLCore newEventId];
        _startedAt = [[NSDate date] timeIntervalSince1970];
        _startedAtIso = [ATLCore iso:_startedAt];
        _enabled = YES;
    }

    return self;
}

- (void)installWithPreviousTimeToCrash:(NSTimeInterval)previousTimeToCrash {
    @synchronized (self) {
        if (_installed) {
            return;
        }

        _installed = YES;
    }

    if (!_enabled) {
        return;
    }

    [_core enqueue:@"session" payload:[ATLSessionItems startedWithEventId:[ATLCore newEventId] sid:_sessionId
                                                                startedIso:_startedAtIso]];

    if (previousTimeToCrash >= 0 && previousTimeToCrash < ATLLaunchWindow) {
        [_core flushWithin:ATLLaunchFlush - ([[NSDate date] timeIntervalSince1970] - _startedAt)];
    }
}

// --- handled errors -----------------------------------------------------------------------

- (void)recordError:(NSError *)error {
    if (error == nil || !_enabled) {
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // Two frames of ours between the app and the stack: this one and the facade.
    NSMutableDictionary *report = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                           crashedAt:[ATLCore iso:now]
                                                           sessionId:_sessionId
                                                           mechanism:ATLMechanismRecorded
                                                             handled:YES
                                                                type:[ATLCrashReport typeForError:error]
                                                             message:error.localizedDescription
                                                              frames:[ATLCrashReport currentFramesSkipping:2]];
    [_scope writeTo:report];

    NSMutableDictionary *context = [self contextAt:now];
    NSString *userInfo = error.userInfo.count > 0 ? error.userInfo.description : nil;

    if (userInfo != nil) {
        context[@"errorUserInfo"] = userInfo.length > 1024 ? [userInfo substringToIndex:1024] : userInfo;
    }

    report[@"context"] = context;
    [self enqueueError:report];
}

- (void)recordException:(NSException *)exception {
    [self recordException:exception mechanism:ATLMechanismRecorded];
}

- (void)recordException:(NSException *)exception mechanism:(NSString *)mechanism {
    if (exception == nil || !_enabled) {
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSArray *frames;
    NSArray<NSNumber *> *own = exception.callStackReturnAddresses;

    if (own.count > 0) {
        // The exception remembers where it was raised; that beats where it
        // was caught.
        uintptr_t raw[256];
        NSUInteger count = 0;

        for (NSNumber *address in own) {
            if (count == 256) break;
            raw[count++] = (uintptr_t) address.unsignedLongLongValue;
        }

        frames = [ATLCrashReport framesForAddresses:raw count:count topIsPC:NO];
    } else {
        frames = [ATLCrashReport currentFramesSkipping:2];
    }

    NSMutableDictionary *report = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                           crashedAt:[ATLCore iso:now]
                                                           sessionId:_sessionId
                                                           mechanism:mechanism
                                                             handled:YES
                                                                type:exception.name ?: @"NSException"
                                                             message:exception.reason
                                                              frames:frames];
    [_scope writeTo:report];
    report[@"context"] = [self contextAt:now];
    [self enqueueError:report];
}

- (void)enqueueError:(NSDictionary *)report {
    ATLBatch *batch = [[_core batch] add:@"error" payload:report];
    BOOL first;

    @synchronized (self) {
        first = _errors++ == 0;
    }

    if (first) {
        [batch add:@"session" payload:[ATLSessionItems erroredWithEventId:[ATLCore newEventId] sid:_sessionId
                                                                startedIso:_startedAtIso]];
    }

    [batch enqueue];
}

// --- the previous run's deaths ------------------------------------------------------------------

- (NSTimeInterval)reportPendingNativeAt:(NSString *)path scopeSnapshot:(NSDictionary *)scope previousRun:(NSDictionary *)previousRun {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return -1;
    }

    NSTimeInterval crashedAt = -1;
    NSMutableDictionary *report = _enabled ? [ATLNativeReport readFile:path crashedAt:&crashedAt] : nil;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    if (report == nil) {
        return -1;
    }

    // The dead process's keys, breadcrumbs and log, as it last wrote them.
    for (NSString *key in scope) {
        if ([key isEqualToString:@"user"] || [key isEqualToString:@"keys"] || [key isEqualToString:@"breadcrumbs"]
            || [key isEqualToString:@"log"]) {
            report[key] = scope[key];
        }
    }

    NSString *sessionId = [previousRun[@"sessionId"] isKindOfClass:[NSString class]] ? previousRun[@"sessionId"] : nil;
    NSTimeInterval started = [previousRun[@"startedAt"] doubleValue];
    NSMutableDictionary *context = report[@"context"] ?: [NSMutableDictionary dictionary];

    if (started > 0) {
        context[@"startedAt"] = [ATLCore iso:started];
        context[@"timeToCrashMs"] = @((long long) ((crashedAt - started) * 1000.0));
    }

    if ([previousRun[@"facts"] isKindOfClass:[NSDictionary class]]) {
        [context addEntriesFromDictionary:previousRun[@"facts"]];
    }

    for (NSString *key in @[@"active", @"foreground", @"hanging"]) {
        if (previousRun[key] != nil) {
            context[key] = previousRun[key];
        }
    }

    report[@"context"] = context;

    if (sessionId != nil) {
        report[@"sessionId"] = sessionId;
    }

    ATLBatch *batch = [[_core batch] add:@"crash" payload:report];

    if (sessionId != nil) {
        batch = [batch add:@"session" payload:[ATLSessionItems endedWithEventId:[ATLCore newEventId] sid:sessionId
                                                                          status:@"crashed"
                                                                      startedIso:started > 0 ? [ATLCore iso:started] : nil
                                                                          errors:0
                                                                 durationSeconds:started > 0 ? crashedAt - started : -1]];
    }

    [batch enqueue];
    [ATLMetricKitBridge noteOwnCrashAt:crashedAt];
    self.crashedLastRun = YES;

    return crashedAt;
}

- (void)reportExitAt:(NSTimeInterval)at
           sessionId:(NSString *)sessionId
           mechanism:(NSString *)mechanism
                type:(NSString *)type
             message:(NSString *)message
              frames:(NSArray *)frames
             threads:(NSArray *)threads
             context:(NSDictionary *)context
       sessionStatus:(NSString *)sessionStatus {
    if (!_enabled) {
        return;
    }

    NSMutableDictionary *report = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                           crashedAt:[ATLCore iso:at]
                                                           sessionId:sessionId
                                                           mechanism:mechanism
                                                             handled:NO
                                                                type:type
                                                             message:message
                                                              frames:frames ?: @[]];

    if (threads != nil) {
        report[@"threads"] = threads;
    }
    if (context != nil) {
        report[@"context"] = context;
    }

    ATLBatch *batch = [[_core batch] add:@"crash" payload:report];

    if (sessionId != nil) {
        batch = [batch add:@"session" payload:[ATLSessionItems endedWithEventId:[ATLCore newEventId] sid:sessionId
                                                                          status:sessionStatus startedIso:nil
                                                                          errors:0 durationSeconds:-1]];
    }

    [batch enqueue];
    [ATLMetricKitBridge noteOwnCrashAt:at];
}

- (void)reportHangWithFrames:(NSArray *)frames stuckFor:(NSTimeInterval)seconds {
    if (!_enabled) {
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *report = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                           crashedAt:[ATLCore iso:now]
                                                           sessionId:_sessionId
                                                           mechanism:ATLMechanismAnr
                                                             handled:NO
                                                                type:@"AppHang"
                                                             message:[NSString stringWithFormat:@"The main thread did not answer for %.0fms", seconds * 1000.0]
                                                              frames:frames];
    [_scope writeTo:report];
    report[@"context"] = [self contextAt:now];
    report[@"threads"] = @[@{@"name": @"main", @"crashed": @YES, @"frames": frames ?: @[]}];

    // A hang is reported on its own; the session's fate is decided at the
    // next start, when the run state says whether the watchdog killed it.
    [[[_core batch] add:@"crash" payload:report] enqueue];
}

- (void)reportDiagnosticAt:(NSTimeInterval)at
                 mechanism:(NSString *)mechanism
                      type:(NSString *)type
                   message:(NSString *)message
                    frames:(NSArray *)frames
                   threads:(NSArray *)threads
                   context:(NSDictionary *)context {
    if (!_enabled) {
        return;
    }

    NSMutableDictionary *report = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                           crashedAt:[ATLCore iso:at]
                                                           sessionId:nil
                                                           mechanism:mechanism
                                                             handled:YES
                                                                type:type
                                                             message:message
                                                              frames:frames ?: @[]];

    if (threads != nil) {
        report[@"threads"] = threads;
    }
    if (context != nil) {
        report[@"context"] = context;
    }

    [_core enqueue:@"error" payload:report];
}

- (NSMutableDictionary<NSString *, id> *)contextAt:(NSTimeInterval)at {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    context[@"startedAt"] = _startedAtIso;
    context[@"timeToCrashMs"] = @((long long) ((at - _startedAt) * 1000.0));

    @try {
        [context addEntriesFromDictionary:[ATLRunState facts]];
    } @catch (NSException *moody) {
        // The facts are a bonus; the report goes without them.
    }

    return context;
}

@end
