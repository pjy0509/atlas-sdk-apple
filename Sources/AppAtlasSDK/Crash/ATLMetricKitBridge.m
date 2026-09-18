#import "ATLMetricKitBridge.h"

#import "ATLCore.h"
#import "ATLCrashReport.h"
#import "ATLCrashReporter.h"

#include <dlfcn.h>

static NSString *const ATLOwnCrashesKey = @"dev.appatlas.sdk.crash.ownCrashes";
static const NSUInteger ATLOwnCrashesKept = 100;

/// The subscriber protocol, by name: MetricKit's own declaration when the SDK
/// has it, a stand-in with the same selectors otherwise. Protocols are not
/// link symbols; the runtime merges the copies.
#if __has_include(<MetricKit/MetricKit.h>)
#import <MetricKit/MetricKit.h>
#else
@protocol MXMetricManagerSubscriber <NSObject>
@optional
- (void)didReceiveMetricPayloads:(NSArray *)payloads;
- (void)didReceiveDiagnosticPayloads:(NSArray *)payloads;
@end
#endif

@interface ATLMetricKitBridge () <MXMetricManagerSubscriber>
@end

@implementation ATLMetricKitBridge {
    ATLCrashReporter *_reporter;
}

- (instancetype)initWithReporter:(ATLCrashReporter *)reporter {
    self = [super init];

    if (self) {
        _reporter = reporter;
    }

    return self;
}

- (void)subscribe {
    if (@available(iOS 14.0, macOS 12.0, *)) {
        // Not linked: loaded by path, so an iOS 12 install never sees the name.
        if (NSClassFromString(@"MXMetricManager") == nil) {
            dlopen("/System/Library/Frameworks/MetricKit.framework/MetricKit", RTLD_LAZY);
        }

        Class manager = NSClassFromString(@"MXMetricManager");
        SEL shared = NSSelectorFromString(@"sharedManager");
        SEL add = NSSelectorFromString(@"addSubscriber:");

        if (manager == nil || ![manager respondsToSelector:shared]) {
            return;
        }

        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id instance = [manager performSelector:shared];

        if ([instance respondsToSelector:add]) {
            [instance performSelector:add withObject:self];
        }
        #pragma clang diagnostic pop
    }
}

- (void)didReceiveMetricPayloads:(NSArray *)payloads {
    // Day totals without stacks: nothing an issue can be made of.
}

- (void)didReceiveDiagnosticPayloads:(NSArray *)payloads {
    for (id payload in payloads) {
        @try {
            [self handlePayload:payload];
        } @catch (NSException *shape) {
            // A payload of a shape this build does not know is skipped, not fatal.
        }
    }
}

- (void)handlePayload:(id)payload {
    id rawBegin = [self valueAt:@"timeStampBegin" of:payload];
    id rawEnd = [self valueAt:@"timeStampEnd" of:payload];
    NSDate *begin = [rawBegin isKindOfClass:[NSDate class]] ? rawBegin : nil;
    NSDate *end = [rawEnd isKindOfClass:[NSDate class]] ? rawEnd : nil;
    NSTimeInterval at = end != nil ? end.timeIntervalSince1970 : [[NSDate date] timeIntervalSince1970];

    // Crashes: only for a window this SDK saw nothing in. A crash the
    // handlers wrote a report for is already on its way.
    if (![ATLMetricKitBridge ownCrashBetween:begin and:end]) {
        for (id diagnostic in [self listAt:@"crashDiagnostics" of:payload]) {
            [self reportCrash:diagnostic at:at];
        }
    }

    for (id diagnostic in [self listAt:@"cpuExceptionDiagnostics" of:payload]) {
        NSString *cpu = [self text:[self valueAt:@"totalCPUTime" of:diagnostic]];
        NSString *sampled = [self text:[self valueAt:@"totalSampledTime" of:diagnostic]];
        [self reportDiagnostic:diagnostic at:at type:@"CPUException"
                       message:[NSString stringWithFormat:@"Excessive CPU: %@ of %@", cpu, sampled]];
    }

    for (id diagnostic in [self listAt:@"diskWriteExceptionDiagnostics" of:payload]) {
        NSString *writes = [self text:[self valueAt:@"totalWritesCaused" of:diagnostic]];
        [self reportDiagnostic:diagnostic at:at type:@"DiskWriteException"
                       message:[NSString stringWithFormat:@"Excessive disk writes: %@", writes]];
    }
}

- (void)reportCrash:(id)diagnostic at:(NSTimeInterval)at {
    NSString *type = nil;
    NSString *message = nil;
    NSMutableDictionary *context = [NSMutableDictionary dictionary];

    // iOS 17+: the NSException behind an abort, as the OS recorded it.
    id reason = [self valueAt:@"exceptionReason" of:diagnostic];

    if (reason != nil) {
        NSString *name = [self text:[self valueAt:@"exceptionName" of:reason]];
        NSString *composed = [self text:[self valueAt:@"composedMessage" of:reason]];

        if (name.length > 0) {
            type = name;
            message = composed;
        }
    }

    NSNumber *exceptionType = [self number:[self valueAt:@"exceptionType" of:diagnostic]];
    NSNumber *signal = [self number:[self valueAt:@"signal" of:diagnostic]];
    NSString *termination = [self text:[self valueAt:@"terminationReason" of:diagnostic]];
    NSString *region = [self text:[self valueAt:@"virtualMemoryRegionInfo" of:diagnostic]];

    if (type == nil) {
        type = exceptionType != nil ? [ATLMetricKitBridge machName:exceptionType.integerValue]
             : signal != nil ? [ATLMetricKitBridge signalName:signal.integerValue] : @"Crash";
    }

    if (message.length == 0) {
        NSMutableArray *parts = [NSMutableArray array];

        if (termination.length > 0) [parts addObject:termination];
        if (region.length > 0) [parts addObject:region];
        if (signal != nil) [parts addObject:[NSString stringWithFormat:@"signal %@", [ATLMetricKitBridge signalName:signal.integerValue]]];

        message = parts.count > 0 ? [parts componentsJoinedByString:@" — "] : @"Recorded by the OS";
    }

    NSData *tree = [self treeJSON:diagnostic];
    NSArray *threads = tree != nil ? [ATLMetricKitBridge threadsFromCallStackTree:tree] : @[];
    NSArray *frames = @[];

    for (NSDictionary *thread in threads) {
        if ([thread[@"crashed"] boolValue]) {
            frames = thread[@"frames"];
            break;
        }
    }

    if (frames.count == 0 && threads.count > 0) {
        frames = threads.firstObject[@"frames"];
    }

    id meta = [self valueAt:@"metaData" of:diagnostic];
    NSString *build = [self text:[self valueAt:@"applicationBuildVersion" of:meta]];

    if (build.length > 0) context[@"metricKitBuild"] = build;
    if (termination.length > 0) context[@"terminationReason"] = termination;

    context[@"source"] = @"MetricKit";

    [_reporter reportExitAt:at sessionId:nil mechanism:ATLMechanismExitInfo type:type message:message
                     frames:frames threads:threads.count > 0 ? threads : nil context:context sessionStatus:@"crashed"];
}

- (void)reportDiagnostic:(id)diagnostic at:(NSTimeInterval)at type:(NSString *)type message:(NSString *)message {
    NSData *tree = [self treeJSON:diagnostic];
    NSArray *threads = tree != nil ? [ATLMetricKitBridge threadsFromCallStackTree:tree] : @[];
    NSArray *frames = threads.firstObject[@"frames"] ?: @[];

    [_reporter reportDiagnosticAt:at mechanism:ATLMechanismMetricKit type:type message:message
                           frames:frames threads:threads.count > 0 ? threads : nil
                          context:@{@"source": @"MetricKit"}];
}

// --- the call stack tree ------------------------------------------------------------------------

+ (NSArray<NSDictionary *> *)threadsFromCallStackTree:(NSData *)json {
    id parsed = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    NSMutableArray *threads = [NSMutableArray array];

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        return threads;
    }

    NSArray *stacks = [parsed[@"callStacks"] isKindOfClass:[NSArray class]] ? parsed[@"callStacks"] : @[];
    NSUInteger index = 0;

    for (NSDictionary *stack in stacks) {
        if (![stack isKindOfClass:[NSDictionary class]]) continue;

        NSArray *roots = [stack[@"callStackRootFrames"] isKindOfClass:[NSArray class]] ? stack[@"callStackRootFrames"] : @[];
        NSMutableArray *outermostFirst = [NSMutableArray array];

        // The tree grows from the outermost frame toward the crash; the
        // heaviest branch is followed when a sampled tree forks.
        NSDictionary *node = [self heaviest:roots];

        while (node != nil && outermostFirst.count < 256) {
            [outermostFirst addObject:[self frameFromNode:node]];
            node = [self heaviest:[node[@"subFrames"] isKindOfClass:[NSArray class]] ? node[@"subFrames"] : @[]];
        }

        BOOL attributed = [stack[@"threadAttributed"] boolValue];
        [threads addObject:@{
            @"name": [NSString stringWithFormat:@"thread-%lu", (unsigned long) index++],
            @"crashed": @(attributed),
            @"frames": [[outermostFirst reverseObjectEnumerator] allObjects],
        }];
    }

    return threads;
}

+ (NSDictionary *)heaviest:(NSArray *)nodes {
    NSDictionary *best = nil;

    for (NSDictionary *node in nodes) {
        if (![node isKindOfClass:[NSDictionary class]]) continue;

        if (best == nil || [node[@"sampleCount"] integerValue] > [best[@"sampleCount"] integerValue]) {
            best = node;
        }
    }

    return best;
}

+ (NSDictionary *)frameFromNode:(NSDictionary *)node {
    NSString *rawUUID = [node[@"binaryUUID"] isKindOfClass:[NSString class]] ? node[@"binaryUUID"] : @"";
    NSString *uuid = [rawUUID stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    NSString *name = [node[@"binaryName"] isKindOfClass:[NSString class]] ? node[@"binaryName"] : nil;
    unsigned long long address = [node[@"address"] unsignedLongLongValue];
    unsigned long long offset = [node[@"offsetIntoBinaryTextSegment"] unsignedLongLongValue];

    return [ATLCrashReport nativeFrameWithAddress:(uintptr_t) address relative:(uintptr_t) offset
                                             uuid:uuid.length == 32 ? uuid : nil
                                             path:name.length > 0 ? name : nil function:nil];
}

// --- the window check ------------------------------------------------------------------------------

+ (void)noteOwnCrashAt:(NSTimeInterval)epochSeconds {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *kept = [([defaults arrayForKey:ATLOwnCrashesKey] ?: @[]) mutableCopy];
    [kept addObject:@(epochSeconds)];

    while (kept.count > ATLOwnCrashesKept) {
        [kept removeObjectAtIndex:0];
    }

    [defaults setObject:kept forKey:ATLOwnCrashesKey];
}

+ (BOOL)ownCrashBetween:(NSDate *)begin and:(NSDate *)end {
    if (begin == nil || end == nil) {
        return NO;
    }

    for (NSNumber *at in [[NSUserDefaults standardUserDefaults] arrayForKey:ATLOwnCrashesKey]) {
        NSTimeInterval seconds = [at doubleValue];

        if (seconds >= begin.timeIntervalSince1970 - 60 && seconds <= end.timeIntervalSince1970 + 60) {
            return YES;
        }
    }

    return NO;
}

// --- reading foreign objects by name ---------------------------------------------------------------

- (NSArray *)listAt:(NSString *)key of:(id)object {
    id value = [self valueAt:key of:object];

    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

- (id)valueAt:(NSString *)key of:(id)object {
    if (object == nil || ![object respondsToSelector:NSSelectorFromString(key)]) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (NSException *absent) {
        return nil;
    }
}

- (NSData *)treeJSON:(id)diagnostic {
    id tree = [self valueAt:@"callStackTree" of:diagnostic];
    id json = [self valueAt:@"JSONRepresentation" of:tree];

    return [json isKindOfClass:[NSData class]] ? json : nil;
}

- (NSString *)text:(id)value {
    if ([value isKindOfClass:[NSString class]]) return value;
    if (value == nil) return @"";

    return [value description];
}

- (NSNumber *)number:(id)value {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

+ (NSString *)machName:(NSInteger)type {
    switch (type) {
        case 1: return @"EXC_BAD_ACCESS";
        case 2: return @"EXC_BAD_INSTRUCTION";
        case 3: return @"EXC_ARITHMETIC";
        case 4: return @"EXC_EMULATION";
        case 5: return @"EXC_SOFTWARE";
        case 6: return @"EXC_BREAKPOINT";
        case 10: return @"EXC_CRASH";
        case 11: return @"EXC_RESOURCE";
        case 12: return @"EXC_GUARD";
        default: return [NSString stringWithFormat:@"EXC_%ld", (long) type];
    }
}

+ (NSString *)signalName:(NSInteger)signal {
    switch (signal) {
        case 4: return @"SIGILL";
        case 5: return @"SIGTRAP";
        case 6: return @"SIGABRT";
        case 8: return @"SIGFPE";
        case 9: return @"SIGKILL";
        case 10: return @"SIGBUS";
        case 11: return @"SIGSEGV";
        case 12: return @"SIGSYS";
        case 13: return @"SIGPIPE";
        default: return [NSString stringWithFormat:@"SIG%ld", (long) signal];
    }
}

@end
