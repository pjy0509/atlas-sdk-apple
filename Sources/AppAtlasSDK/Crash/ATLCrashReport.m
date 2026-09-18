#import "ATLCrashReport.h"

#include <dlfcn.h>

#include "atl_crash_capture.h"

NSString *const ATLMechanismUncaught = @"uncaughtExceptionHandler";
NSString *const ATLMechanismRecorded = @"recordError";
NSString *const ATLMechanismSignal = @"signalHandler";
NSString *const ATLMechanismMach = @"machException";
NSString *const ATLMechanismAnr = @"anr";
NSString *const ATLMechanismExitInfo = @"exitInfo";
NSString *const ATLMechanismMetricKit = @"metricKit";

static const NSUInteger ATLMaxFrames = 256;

@implementation ATLCrashReport

+ (NSMutableDictionary<NSString *, id> *)headWithEventId:(NSString *)eventId
                                               crashedAt:(NSString *)crashedAtIso
                                               sessionId:(NSString *)sessionId
                                               mechanism:(NSString *)mechanism
                                                 handled:(BOOL)handled {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"eventId"] = eventId;
    payload[@"crashedAt"] = crashedAtIso;

    if (sessionId != nil) {
        payload[@"sessionId"] = sessionId;
    }

    payload[@"mechanism"] = [@{@"type": mechanism, @"handled": @(handled)} mutableCopy];

    return payload;
}

+ (NSMutableDictionary<NSString *, id> *)payloadWithEventId:(NSString *)eventId
                                                  crashedAt:(NSString *)crashedAtIso
                                                  sessionId:(NSString *)sessionId
                                                  mechanism:(NSString *)mechanism
                                                    handled:(BOOL)handled
                                                       type:(NSString *)type
                                                    message:(NSString *)message
                                                     frames:(NSArray *)frames {
    NSMutableDictionary *payload = [self headWithEventId:eventId crashedAt:crashedAtIso sessionId:sessionId
                                               mechanism:mechanism handled:handled];
    NSString *text = message ?: @"";
    payload[@"exceptions"] = @[@{
        @"type": type.length > 0 ? type : @"Unknown",
        @"message": text.length > 1000 ? [text substringToIndex:1000] : text,
        @"frames": frames ?: @[],
    }];

    return payload;
}

+ (NSArray<NSDictionary *> *)framesForAddresses:(const uintptr_t *)addresses count:(NSUInteger)count topIsPC:(BOOL)topIsPC {
    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:MIN(count, ATLMaxFrames)];

    for (NSUInteger i = 0; i < count && i < ATLMaxFrames; i++) {
        atl_crash_frame_t located;
        // A return address is looked up one byte inside the call, on the
        // line that made it; only a sampled pc is looked up as it is.
        uintptr_t lookup = i == 0 && topIsPC ? addresses[i] : addresses[i] - 1;
        Dl_info info;
        NSString *function = nil;

        if (dladdr((const void *) lookup, &info) != 0 && info.dli_sname != NULL) {
            function = [NSString stringWithUTF8String:info.dli_sname];
        }

        if (atl_crash_locate(lookup, &located)) {
            [frames addObject:[self nativeFrameWithAddress:addresses[i] relative:located.relative
                                                      uuid:located.uuid[0] ? [NSString stringWithUTF8String:located.uuid] : nil
                                                      path:located.path[0] ? [NSString stringWithUTF8String:located.path] : nil
                                                  function:function]];
        } else {
            [frames addObject:[self nativeFrameWithAddress:addresses[i] relative:0 uuid:nil path:nil function:function]];
        }
    }

    return frames;
}

+ (NSArray<NSDictionary *> *)currentFramesSkipping:(NSUInteger)skip {
    NSArray<NSNumber *> *addresses = [NSThread callStackReturnAddresses];
    uintptr_t raw[ATLMaxFrames];
    NSUInteger kept = 0;

    for (NSUInteger i = skip; i < addresses.count && kept < ATLMaxFrames; i++) {
        raw[kept++] = (uintptr_t) addresses[i].unsignedLongLongValue;
    }

    return [self framesForAddresses:raw count:kept topIsPC:NO];
}

+ (NSDictionary<NSString *, id> *)nativeFrameWithAddress:(uintptr_t)address
                                                relative:(uintptr_t)relative
                                                    uuid:(NSString *)uuid
                                                    path:(NSString *)path
                                                function:(NSString *)function {
    NSMutableDictionary *frame = [NSMutableDictionary dictionary];
    NSString *module = path.lastPathComponent;
    // The image is the frame's "function" stand-in until the server
    // symbolicates: a reader still sees which binary faulted and where.
    frame[@"module"] = module.length > 0 ? module : @"?";
    frame[@"function"] = function.length > 0 ? function : [NSString stringWithFormat:@"0x%llx", (unsigned long long) relative];
    frame[@"instructionAddr"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long) address];

    if (path.length > 0) {
        frame[@"relativeAddr"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long) relative];
        frame[@"image"] = path;
    }

    if (uuid.length > 0) {
        frame[@"buildId"] = uuid;
    }

    return frame;
}

+ (NSString *)typeForError:(NSError *)error {
    return [NSString stringWithFormat:@"%@ %ld", error.domain.length > 0 ? error.domain : @"NSError", (long) error.code];
}

@end
