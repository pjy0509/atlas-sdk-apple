#import "ATLCore.h"

#import "ATLDiskQueue.h"
#import "ATLEnvelopeWriter.h"
#import "ATLTransport.h"

static NSString *const ATLCoreVersion = @"0.1.0";

@implementation ATLCore {
    NSString *_sdkName;
    NSDictionary<NSString *, id> *_context;
    ATLDiskQueue *_queue;
    ATLTransport *_transport;
    dispatch_queue_t _worker;
}

- (instancetype)initWithSDKName:(NSString *)sdkName
                        baseUrl:(NSString *)baseUrl
                         sdkKey:(NSString *)sdkKey
                       queueDir:(NSString *)queueDir
                      installId:(NSString *)installId
                        context:(NSDictionary<NSString *, id> *)context {
    self = [super init];

    if (self) {
        _sdkName = [sdkName copy];
        _baseUrl = [baseUrl copy];
        _installId = [installId copy];
        _context = [context copy];
        _queue = [[ATLDiskQueue alloc] initWithDirectory:queueDir];
        _transport = [[ATLTransport alloc] initWithBaseURL:baseUrl sdkKey:sdkKey];
        _worker = dispatch_queue_create("dev.appatlas.sdk.core", DISPATCH_QUEUE_SERIAL);
    }

    return self;
}

+ (NSString *)newEventId {
    return [[NSUUID UUID] UUIDString].lowercaseString;
}

- (void)enqueue:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload {
    NSData *envelope = [[[[ATLEnvelopeWriter alloc] initWithSDKName:_sdkName
                                                            version:ATLCoreVersion
                                                             sentAt:[ATLCore isoNow]
                                                          installId:_installId
                                                            context:_context]
                        add:type payload:payload] bytes];

    dispatch_async(_worker, ^{
        [self->_queue offer:envelope];
        [self drain];
    });
}

- (void)flushSoon {
    dispatch_async(_worker, ^{
        [self drain];
    });
}

- (void)awaitIdle {
    dispatch_sync(_worker, ^{});
}

- (void)drain {
    for (NSString *path in [_queue list]) {
        NSTimeInterval nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;

        if ([_transport limitedAt:nowMs]) {
            return;
        }

        NSData *envelope = [NSData dataWithContentsOfFile:path];

        if (envelope == nil || envelope.length == 0) {
            // Unreadable is undeliverable; keeping it would spin forever.
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            continue;
        }

        switch ([_transport send:envelope at:nowMs]) {
            case ATLTransportVerdictDelivered:
            case ATLTransportVerdictRefused:
                [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                break;
            case ATLTransportVerdictRetryLater:
                // The queue is ordered; if the head cannot go, the rest
                // cannot either.
                return;
        }
    }
}

+ (NSString *)isoNow {
    // One formatter, POSIX-locked: a device set to a non-Gregorian calendar
    // must not bend the wire format.
    static NSDateFormatter *formatter;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });

    return [formatter stringFromDate:[NSDate date]];
}

@end
