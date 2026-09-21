#import <Foundation/Foundation.h>

#import "ATLCore.h"
#import "ATLCrash.h"
#import "ATLCrashReport.h"
#import "ATLCrashScope.h"
#import "ATLEnvelopeWriter.h"
#import "ATLHangWatchdog.h"
#import "ATLMetricKitBridge.h"
#import "ATLNativeReport.h"
#import "ATLRunState.h"
#import "ATLSessionItems.h"
#import "Atlas.h"

#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include "atl_crash_capture.h"

// CrashGateCxx.mm: a C++ throw with no catch, from the gate's own binary.
void gate_throw_cxx(void);

extern char **environ;

// The gate reaches the module's internals the way its own binding does; the
// public surface stays exactly the public surface.
@interface ATLCrash (Gate)
+ (void)bootWithStateDirectory:(NSString *)directory;
@end

static void require(BOOL held, NSString *complaint) {
    if (!held) {
        fprintf(stderr, "FAIL: %s\n", complaint.UTF8String);
        exit(1);
    }
}

// --- the victim: a process that installs the hooks and dies on command ---------------------

static void *dieOnThread(void *argument) {
    (void) argument;
    pthread_setname_np("atlas-gate-worker");
    volatile int *nowhere = (volatile int *) 0x10;
    *nowhere = 1;

    return NULL;
}

static int overflow(int depth) {
    volatile char pad[1024];
    pad[0] = (char) depth;

    return overflow(depth + 1) + pad[0];
}

static int victim(NSString *mode, NSString *stateDir, NSString *baseUrl) {
    [Atlas startWithKey:@"sdk_gate" baseUrl:baseUrl];
    [ATLCrash bootWithStateDirectory:stateDir];
    [ATLCrash setUserId:@"u-gate"];
    [ATLCrash setKey:@"mode" value:mode];
    [ATLCrash leaveBreadcrumb:@"gate" message:@"about to die"];
    [ATLCrash log:@"the last line"];

    // The scope reaches disk within a second; the crash must find it there.
    [NSThread sleepForTimeInterval:1.3];

    if ([mode isEqualToString:@"segv"]) {
        volatile int *nowhere = (volatile int *) 0x8;
        *nowhere = 1;
    } else if ([mode isEqualToString:@"abrt"]) {
        abort();
    } else if ([mode isEqualToString:@"nsexception"]) {
        [NSException raise:@"GateException" format:@"raised on purpose, line %d", __LINE__];
    } else if ([mode isEqualToString:@"trap"]) {
        __builtin_trap();
    } else if ([mode isEqualToString:@"cxx"]) {
        gate_throw_cxx();
    } else if ([mode isEqualToString:@"stackoverflow"]) {
        return overflow(0);
    } else if ([mode isEqualToString:@"thread"]) {
        pthread_t worker;
        pthread_create(&worker, NULL, dieOnThread, NULL);
        pthread_join(worker, NULL);
    } else if ([mode isEqualToString:@"hang"]) {
        // A short watchdog of the gate's own; the app's is five seconds.
        NSString *path = [stateDir stringByAppendingPathComponent:@"hang.json"];
        ATLHangWatchdog *watchdog = [[ATLHangWatchdog alloc] initWithTimeout:0.4 onHang:^(NSArray *frames, NSTimeInterval stuckFor) {
            NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{@"frames": frames, @"stuckFor": @(stuckFor)}
                                                            options:0 error:NULL];
            [bytes writeToFile:path atomically:YES];
            _exit(0);
        } onRecover:^{}];
        [watchdog start];

        // The main thread, stuck: the run loop never turns.
        for (;;) {
            sleep(1);
        }
    } else if ([mode isEqualToString:@"clean"]) {
        // Lives, and leaves a run state that says it was active: the parent
        // then boots on it to see an out-of-memory kill inferred.
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NSApplicationDidBecomeActiveNotification" object:nil];
        [NSThread sleepForTimeInterval:1.3];
        [[Atlas core] awaitIdle];
        _exit(0);
    }

    fprintf(stderr, "victim: still alive after %s\n", mode.UTF8String);

    return 3;
}

// --- the parent -------------------------------------------------------------------------------------

static NSString *selfPath(void) {
    return [NSBundle mainBundle].executablePath ?: [NSProcessInfo processInfo].arguments.firstObject;
}

static int runChild(NSArray<NSString *> *arguments, NSString *home) {
    NSMutableArray<NSString *> *all = [@[selfPath()] arrayByAddingObjectsFromArray:arguments].mutableCopy;
    char **argv = calloc(all.count + 1, sizeof(char *));

    for (NSUInteger i = 0; i < all.count; i++) {
        argv[i] = strdup(all[i].UTF8String);
    }

    NSMutableArray<NSString *> *env = [NSMutableArray array];

    for (char **cursor = environ; *cursor; cursor++) {
        NSString *pair = [NSString stringWithUTF8String:*cursor];

        if (![pair hasPrefix:@"HOME="]) {
            [env addObject:pair];
        }
    }

    [env addObject:[@"HOME=" stringByAppendingString:home]];
    char **envp = calloc(env.count + 1, sizeof(char *));

    for (NSUInteger i = 0; i < env.count; i++) {
        envp[i] = strdup(env[i].UTF8String);
    }

    pid_t pid = 0;
    int status = 0;

    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, envp) != 0) {
        return -1;
    }

    waitpid(pid, &status, 0);

    return status;
}

static NSDictionary *crashedThread(NSDictionary *payload) {
    for (NSDictionary *thread in payload[@"threads"]) {
        if ([thread[@"crashed"] boolValue]) {
            return thread;
        }
    }

    return nil;
}

static void checkCapture(NSString *outDir, NSString *baseUrl) {
    NSArray *modes = @[@"segv", @"abrt", @"nsexception", @"trap", @"stackoverflow", @"thread", @"cxx"];

    for (NSString *mode in modes) {
        NSString *home = [outDir stringByAppendingPathComponent:[@"home-" stringByAppendingString:mode]];
        NSString *stateDir = [home stringByAppendingPathComponent:@"state"];
        [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:NULL];

        int status = runChild(@[@"--victim", mode, stateDir, baseUrl], home);
        require(WIFSIGNALED(status), [NSString stringWithFormat:@"%@: the victim must die by signal, status %d", mode, status]);

        NSString *report = [stateDir stringByAppendingPathComponent:@"native-crash.txt"];
        NSTimeInterval at = 0;
        NSMutableDictionary *payload = [ATLNativeReport readFile:report crashedAt:&at];
        require(payload != nil, [NSString stringWithFormat:@"%@: no whole report was written", mode]);
        require(at > 0, [NSString stringWithFormat:@"%@: crash time missing", mode]);

        NSDictionary *raised = [payload[@"exceptions"] firstObject];
        NSString *type = raised[@"type"];
        NSString *mechanism = payload[@"mechanism"][@"type"];
        NSDictionary *thread = crashedThread(payload);
        NSArray *frames = raised[@"frames"];

        require(thread != nil, [NSString stringWithFormat:@"%@: no thread is flagged crashed", mode]);
        require([payload[@"threads"] count] >= 2, [NSString stringWithFormat:@"%@: the other threads are missing", mode]);
        require(frames.count >= 2, [NSString stringWithFormat:@"%@: too few frames (%lu)", mode, (unsigned long) frames.count]);

        NSDictionary *top = frames.firstObject;
        require([top[@"buildId"] length] == 32, [NSString stringWithFormat:@"%@: frame 0 has no image UUID", mode]);
        require([top[@"relativeAddr"] hasPrefix:@"0x"], [NSString stringWithFormat:@"%@: frame 0 has no relative address", mode]);
        require([top[@"image"] length] > 0, [NSString stringWithFormat:@"%@: frame 0 names no image", mode]);

        // Somewhere in the crashed thread is this very binary.
        BOOL ownFrame = NO;

        for (NSDictionary *frame in frames) {
            if ([frame[@"module"] isEqualToString:selfPath().lastPathComponent]) ownFrame = YES;
        }

        require(ownFrame, [NSString stringWithFormat:@"%@: no frame in the gate binary itself", mode]);

        // The system's frames are named at the next start, from the same
        // libraries loaded again: a reader sees abort(), not an offset.
        BOOL named = NO;

        for (NSDictionary *frame in frames) {
            if ([frame[@"image"] hasPrefix:@"/usr/lib/"] && ![frame[@"function"] hasPrefix:@"0x"]) named = YES;
        }

        require(named, [NSString stringWithFormat:@"%@: no system frame was named", mode]);

        if ([mode isEqualToString:@"segv"] || [mode isEqualToString:@"thread"] || [mode isEqualToString:@"stackoverflow"]) {
            require([mechanism isEqualToString:ATLMechanismMach], [NSString stringWithFormat:@"%@: a fault must come through mach, got %@", mode, mechanism]);
            require([type isEqualToString:@"EXC_BAD_ACCESS"], [NSString stringWithFormat:@"%@: type %@", mode, type]);
        }
        if ([mode isEqualToString:@"stackoverflow"]) {
            require([payload[@"mechanism"][@"native"][@"stackOverflow"] boolValue], @"stackoverflow: not recognised as one");
            require([raised[@"message"] containsString:@"Stack overflow"], @"stackoverflow: message does not say so");
        }
        if ([mode isEqualToString:@"thread"]) {
            require([thread[@"name"] isEqualToString:@"atlas-gate-worker"], [NSString stringWithFormat:@"thread: crashed thread named %@", thread[@"name"]]);
        } else {
            require([thread[@"name"] isEqualToString:@"main"], [NSString stringWithFormat:@"%@: crashed thread named %@", mode, thread[@"name"]]);
        }
        if ([mode isEqualToString:@"abrt"]) {
            require([mechanism isEqualToString:ATLMechanismSignal], @"abrt: must come through the signal handler");
            require([type isEqualToString:@"SIGABRT"], [NSString stringWithFormat:@"abrt: type %@", type]);
            require([raised[@"message"] containsString:@"abort"], @"abrt: __crash_info's abort() reason missing");
        }
        if ([mode isEqualToString:@"nsexception"]) {
            require([mechanism isEqualToString:ATLMechanismUncaught], @"nsexception: mechanism");
            require([type isEqualToString:@"GateException"], [NSString stringWithFormat:@"nsexception: type %@", type]);
            require([raised[@"message"] hasPrefix:@"raised on purpose"], @"nsexception: reason lost");
        }
        if ([mode isEqualToString:@"cxx"]) {
            // Uncaught, the runtime aborts; the type in flight is what groups it.
            require([mechanism isEqualToString:ATLMechanismSignal], @"cxx: must come through the signal handler");
            require([type isEqualToString:@"std::runtime_error"], [NSString stringWithFormat:@"cxx: type %@", type]);
            require([raised[@"message"] containsString:@"gate cxx"], @"cxx: what() missing from __crash_info");
            require([payload[@"mechanism"][@"native"][@"cxxException"] isEqualToString:@"std::runtime_error"], @"cxx: not flagged");
        }
        if ([mode isEqualToString:@"trap"]) {
            require([mechanism isEqualToString:ATLMechanismMach], @"trap: a brk must come through mach");
            require([type isEqualToString:@"EXC_BREAKPOINT"] || [type isEqualToString:@"EXC_BAD_INSTRUCTION"],
                    [NSString stringWithFormat:@"trap: type %@", type]);
        }

        require([payload[@"context"][@"registers"] length] > 0, [NSString stringWithFormat:@"%@: registers missing", mode]);

        // The scope the victim set reached disk before it died.
        NSDictionary *scope = [ATLCrashScope readFrom:[stateDir stringByAppendingPathComponent:@"crash-scope.json"]];
        require([scope[@"user"][@"id"] isEqualToString:@"u-gate"], [NSString stringWithFormat:@"%@: scope snapshot missing", mode]);
        require([scope[@"keys"][@"mode"] isEqualToString:mode], [NSString stringWithFormat:@"%@: keys not snapshotted", mode]);
        require([scope[@"breadcrumbs"] count] == 1, [NSString stringWithFormat:@"%@: breadcrumbs not snapshotted", mode]);
        require([scope[@"log"] containsString:@"the last line"], [NSString stringWithFormat:@"%@: log not snapshotted", mode]);

        printf("capture: %-13s %s via %s, %lu frames, %lu threads\n", mode.UTF8String, type.UTF8String, mechanism.UTF8String,
               (unsigned long) frames.count, (unsigned long) [payload[@"threads"] count]);
    }
}

static void checkHang(NSString *outDir, NSString *baseUrl) {
    NSString *home = [outDir stringByAppendingPathComponent:@"home-hang"];
    NSString *stateDir = [home stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:NULL];

    int status = runChild(@[@"--victim", @"hang", stateDir, baseUrl], home);
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, [NSString stringWithFormat:@"hang: the watchdog never fired, status %d", status]);

    NSData *bytes = [NSData dataWithContentsOfFile:[stateDir stringByAppendingPathComponent:@"hang.json"]];
    NSDictionary *seen = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL] : nil;
    NSArray *frames = seen[@"frames"];
    require(frames.count >= 2, @"hang: the main thread's frames were not sampled");
    require([frames.firstObject[@"buildId"] length] == 32, @"hang: sampled frame has no image UUID");
    require([seen[@"stuckFor"] doubleValue] >= 0.3, @"hang: stuck time not measured");
    printf("hang: the main thread was caught stuck, %lu frames\n", (unsigned long) frames.count);
}

// --- envelopes: what the next start sends ------------------------------------------------------------

/// Reads a queue file back: the header, then (type, payload) pairs.
static NSArray<NSDictionary *> *itemsOfEnvelope(NSData *bytes) {
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger at = 0;
    const char *raw = bytes.bytes;
    NSUInteger length = bytes.length;

    NSUInteger (^lineEnd)(NSUInteger) = ^NSUInteger(NSUInteger from) {
        NSUInteger end = from;
        while (end < length && raw[end] != '\n') end++;
        return end;
    };

    at = lineEnd(0) + 1;  // the header

    while (at < length) {
        NSUInteger end = lineEnd(at);
        NSDictionary *head = [NSJSONSerialization JSONObjectWithData:[bytes subdataWithRange:NSMakeRange(at, end - at)]
                                                             options:0 error:NULL];
        NSUInteger size = [head[@"length"] unsignedIntegerValue];
        NSData *body = [bytes subdataWithRange:NSMakeRange(end + 1, size)];
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        [items addObject:@{@"type": head[@"type"] ?: @"?", @"payload": payload ?: @{}}];
        at = end + 1 + size + 1;
    }

    return items;
}

static NSArray<NSDictionary *> *queuedItems(NSString *home) {
    NSString *queue = [home stringByAppendingPathComponent:@"Library/Caches/atlas/queue"];
    NSMutableArray *all = [NSMutableArray array];

    for (NSString *name in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:queue error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasSuffix:@".envelope"]) {
            [all addObjectsFromArray:itemsOfEnvelope([NSData dataWithContentsOfFile:[queue stringByAppendingPathComponent:name]])];
        }
    }

    return all;
}

static NSDictionary *firstItem(NSArray<NSDictionary *> *items, NSString *type, NSString *mechanism) {
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:type]
            && (mechanism == nil || [item[@"payload"][@"mechanism"][@"type"] isEqualToString:mechanism])) {
            return item[@"payload"];
        }
    }

    return nil;
}

static NSDictionary *sessionWithStatus(NSArray<NSDictionary *> *items, NSString *status) {
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"session"] && [item[@"payload"][@"status"] isEqualToString:status]) {
            return item[@"payload"];
        }
    }

    return nil;
}

static void checkNextStart(NSString *outDir) {
    // An unreachable server: whatever the boot enqueues stays on disk to read.
    NSString *dead = @"http://127.0.0.1:9";

    // 1. A native report waits: the next start sends it with the dead
    //    session's end, the scope, and the run's facts.
    NSString *home = [outDir stringByAppendingPathComponent:@"home-next"];
    NSString *stateDir = [home stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:NULL];
    runChild(@[@"--victim", @"segv", stateDir, dead], home);
    require([[NSFileManager defaultManager] fileExistsAtPath:[stateDir stringByAppendingPathComponent:@"native-crash.txt"]],
            @"next: the victim left no report");

    int status = runChild(@[@"--boot", stateDir, dead], home);
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, [NSString stringWithFormat:@"next: the boot child failed, status %d", status]);

    NSArray *items = queuedItems(home);
    NSDictionary *crash = firstItem(items, @"crash", ATLMechanismMach);
    require(crash != nil, @"next: no crash item was queued");
    require([crash[@"user"][@"id"] isEqualToString:@"u-gate"], @"next: the dead run's scope did not ride the crash");
    require([crash[@"keys"][@"mode"] isEqualToString:@"segv"], @"next: keys lost");
    require([crash[@"sessionId"] length] > 0, @"next: the dead session is not named");
    require([crash[@"context"][@"timeToCrashMs"] longLongValue] >= 1000, @"next: time-to-crash not computed");
    require(crash[@"context"][@"memoryTotalBytes"] != nil, @"next: the dead run's facts missing");

    NSDictionary *ended = sessionWithStatus(items, @"crashed");
    require(ended != nil && [ended[@"sid"] isEqualToString:crash[@"sessionId"]], @"next: the crashed session's end is missing");
    require(sessionWithStatus(items, @"ok") != nil, @"next: this run's session start is missing");
    require(![[NSFileManager defaultManager] fileExistsAtPath:[stateDir stringByAppendingPathComponent:@"native-crash.txt"]],
            @"next: the report must be consumed");
    printf("next start: the native crash left with its session, scope and facts\n");

    // 2. No report, a run state that says active and in the foreground, the
    //    same build and boot: an out-of-memory kill, inferred.
    home = [outDir stringByAppendingPathComponent:@"home-oom"];
    stateDir = [home stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:NULL];
    status = runChild(@[@"--victim", @"clean", stateDir, dead], home);
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, @"oom: the clean victim failed");

    // The victim exited without WillTerminate, as a killed app does.
    status = runChild(@[@"--boot", stateDir, dead], home);
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, @"oom: the boot child failed");

    items = queuedItems(home);
    NSDictionary *kill = firstItem(items, @"crash", ATLMechanismExitInfo);
    require(kill != nil, @"oom: no kill was inferred");
    require([[kill[@"exceptions"] firstObject][@"type"] isEqualToString:@"OutOfMemory"],
            [NSString stringWithFormat:@"oom: type %@", [kill[@"exceptions"] firstObject][@"type"]]);
    require(sessionWithStatus(items, @"abnormal") != nil, @"oom: the session's abnormal end is missing");
    printf("next start: a foreground death without a report became an OutOfMemory kill\n");

    // 3. The same, after a run that ended cleanly: nothing.
    home = [outDir stringByAppendingPathComponent:@"home-clean"];
    stateDir = [home stringByAppendingPathComponent:@"state"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:NULL];
    runChild(@[@"--victim", @"clean", stateDir, dead], home);
    // Say it terminated: the file the app leaves when the OS tells it so.
    NSString *statePath = [stateDir stringByAppendingPathComponent:@"run-state.json"];
    NSMutableDictionary *state = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:statePath] options:0 error:NULL] mutableCopy];
    state[@"cleanExit"] = @YES;
    [[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL] writeToFile:statePath atomically:YES];
    runChild(@[@"--boot", stateDir, dead], home);
    require(firstItem(queuedItems(home), @"crash", nil) == nil, @"clean: a clean exit must not become a kill");
    printf("next start: a clean exit is not a kill\n");
}

static int bootChild(NSString *stateDir, NSString *baseUrl) {
    [Atlas startWithKey:@"sdk_gate" baseUrl:baseUrl];
    [ATLCrash bootWithStateDirectory:stateDir];
    // The deaths thread runs on its own; give it its moment, then the worker.
    [NSThread sleepForTimeInterval:1.5];
    [[Atlas core] awaitIdle];

    return 0;
}

// --- the samples every SDK's golden pins --------------------------------------------------------------

static void writeSamples(NSString *outDir) {
    NSDictionary *context = @{@"device": @{@"os": @"ios", @"osVersion": @"17.4", @"model": @"iPhone16,2"},
                              @"app": @{@"version": @"3.2.1", @"build": @"151"}};

    NSArray *frames = @[
        [ATLCrashReport nativeFrameWithAddress:0x1029f4a10 relative:0x4a10
                                          uuid:@"5db7294d87fc4726a5c04a90679657b5"
                                          path:@"/private/var/containers/Bundle/Application/X/Checkout.app/Checkout"
                                      function:nil],
        [ATLCrashReport nativeFrameWithAddress:0x1a2b3c4d8 relative:0x3c4d8
                                          uuid:@"aaaabbbbccccddddeeeeffff00001111"
                                          path:@"/System/Library/Frameworks/UIKitCore.framework/UIKitCore"
                                      function:@"-[UIViewController loadViewIfRequired]"],
    ];
    NSMutableDictionary *crash = [ATLCrashReport payloadWithEventId:@"44444444-0000-0000-0000-000000000001"
                                                          crashedAt:@"2026-09-18T01:00:00Z"
                                                          sessionId:@"55555555-0000-0000-0000-000000000001"
                                                          mechanism:ATLMechanismMach handled:NO
                                                               type:@"EXC_BAD_ACCESS"
                                                            message:@"EXC_BAD_ACCESS (KERN_INVALID_ADDRESS) at 0x8"
                                                             frames:frames];
    crash[@"mechanism"][@"native"] = @{@"exception": @"EXC_BAD_ACCESS", @"code": @"KERN_INVALID_ADDRESS", @"faultAddress": @"0x8"};
    crash[@"threads"] = @[@{@"name": @"main", @"crashed": @YES, @"frames": frames},
                          @{@"name": @"com.apple.NSURLSession-work", @"crashed": @NO, @"frames": @[frames[1]]}];

    ATLCrashScope *scope = [[ATLCrashScope alloc] init];
    [scope setUserId:@"u-123"];
    [scope setKey:@"screen" value:@"checkout"];
    [scope leaveBreadcrumb:@"cart" message:@"add \"socks\"" level:nil at:1789894800];
    [scope writeTo:crash];
    crash[@"context"] = @{@"startedAt": @"2026-09-18T00:58:00Z", @"timeToCrashMs": @120000, @"memoryTotalBytes": @6144000000};

    NSData *envelope = [[[[[ATLEnvelopeWriter alloc] initWithSDKName:@"atlas-apple" version:@"0.2.0"
                                                              sentAt:@"2026-09-18T01:00:05Z"
                                                           installId:@"c1a2b3d4e5f60718"
                                                             context:context]
                          add:@"crash" payload:crash]
                         add:@"session" payload:[ATLSessionItems endedWithEventId:@"44444444-0000-0000-0000-000000000002"
                                                                               sid:@"55555555-0000-0000-0000-000000000001"
                                                                            status:@"crashed"
                                                                        startedIso:@"2026-09-18T00:58:00Z"
                                                                            errors:0 durationSeconds:120]] bytes];
    [envelope writeToFile:[outDir stringByAppendingPathComponent:@"crash.envelope"] atomically:YES];

    NSMutableDictionary *error = [ATLCrashReport payloadWithEventId:@"44444444-0000-0000-0000-000000000003"
                                                          crashedAt:@"2026-09-18T01:00:00Z"
                                                          sessionId:@"55555555-0000-0000-0000-000000000001"
                                                          mechanism:ATLMechanismRecorded handled:YES
                                                               type:@"NSURLErrorDomain -1009"
                                                            message:@"The Internet connection appears to be offline."
                                                             frames:@[frames[0]]];
    NSData *errorEnvelope = [[[[[ATLEnvelopeWriter alloc] initWithSDKName:@"atlas-apple" version:@"0.2.0"
                                                                   sentAt:@"2026-09-18T01:00:05Z"
                                                                installId:@"c1a2b3d4e5f60718"
                                                                  context:context]
                               add:@"error" payload:error]
                              add:@"session" payload:[ATLSessionItems erroredWithEventId:@"44444444-0000-0000-0000-000000000004"
                                                                                     sid:@"55555555-0000-0000-0000-000000000001"
                                                                              startedIso:@"2026-09-18T00:58:00Z"]] bytes];
    [errorEnvelope writeToFile:[outDir stringByAppendingPathComponent:@"error.envelope"] atomically:YES];
}

static void checkMetricKitTree(void) {
    NSString *json = @"{\"callStackPerThread\":true,\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":["
        "{\"binaryUUID\":\"5DB7294D-87FC-4726-A5C0-4A90679657B5\",\"offsetIntoBinaryTextSegment\":100,\"sampleCount\":1,"
        "\"binaryName\":\"Checkout\",\"address\":4300000100,\"subFrames\":["
        "{\"binaryUUID\":\"5DB7294D-87FC-4726-A5C0-4A90679657B5\",\"offsetIntoBinaryTextSegment\":200,\"sampleCount\":1,"
        "\"binaryName\":\"Checkout\",\"address\":4300000200}]}]},"
        "{\"threadAttributed\":false,\"callStackRootFrames\":[{\"binaryUUID\":\"AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111\","
        "\"offsetIntoBinaryTextSegment\":7,\"sampleCount\":1,\"binaryName\":\"libsystem_kernel.dylib\",\"address\":7}]}]}";
    NSArray *threads = [ATLMetricKitBridge threadsFromCallStackTree:[json dataUsingEncoding:NSUTF8StringEncoding]];

    require(threads.count == 2, @"metrickit: two call stacks make two threads");
    require([threads[0][@"crashed"] boolValue] && ![threads[1][@"crashed"] boolValue], @"metrickit: the attributed thread is the crashed one");
    NSArray *frames = threads[0][@"frames"];
    require(frames.count == 2, @"metrickit: the chain was not flattened");
    // Innermost first: the leaf (offset 200) before the root (offset 100).
    require([frames[0][@"relativeAddr"] isEqualToString:@"0xc8"], @"metrickit: frames not innermost-first");
    require([frames[0][@"buildId"] isEqualToString:@"5db7294d87fc4726a5c04a90679657b5"], @"metrickit: UUID not normalised");
    require([frames[0][@"module"] isEqualToString:@"Checkout"], @"metrickit: binary name lost");
    printf("metrickit: a call stack tree flattens to wire threads\n");
}

static void checkScope(void) {
    ATLCrashScope *scope = [[ATLCrashScope alloc] init];

    for (int i = 0; i < 80; i++) {
        [scope setKey:[NSString stringWithFormat:@"k%d", i] value:@"v"];
    }
    for (int i = 0; i < 150; i++) {
        [scope leaveBreadcrumb:@"c" message:[NSString stringWithFormat:@"%d", i] level:nil at:1];
    }
    for (int i = 0; i < 100; i++) {
        [scope log:[@"" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0] at:1];
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [scope writeTo:out];
    require([out[@"keys"] count] == ATLCrashScope.maxKeys, @"scope: key cap not held");
    require([out[@"breadcrumbs"] count] == ATLCrashScope.maxBreadcrumbs, @"scope: breadcrumb cap not held");
    require([[out[@"breadcrumbs"] firstObject][@"message"] isEqualToString:@"50"], @"scope: the oldest crumbs must go first");
    require([out[@"log"] length] <= 64 * 1024, @"scope: log cap not held");
    require([out[@"log"] hasSuffix:@"\n"], @"scope: log cut mid-line");
    printf("scope: keys, breadcrumbs and log hold their caps\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;

        if (arguments.count >= 5 && [arguments[1] isEqualToString:@"--victim"]) {
            return victim(arguments[2], arguments[3], arguments[4]);
        }
        if (arguments.count >= 4 && [arguments[1] isEqualToString:@"--boot"]) {
            return bootChild(arguments[2], arguments[3]);
        }

        NSString *outDir = [NSString stringWithUTF8String:argv[1]];
        NSString *baseUrl = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];

        if (atl_crash_debugger_attached()) {
            fprintf(stderr, "crash gate: run without a debugger attached\n");

            return 1;
        }

        writeSamples(outDir);
        checkScope();
        checkMetricKitTree();
        checkCapture(outDir, baseUrl);
        checkHang(outDir, baseUrl);
        checkNextStart(outDir);

        printf("parity: mach, signal, NSException, hang and next-start paths hold\n");
    }

    return 0;
}
