#import "ATLCore.h"

#import "ATLDiskQueue.h"
#import "ATLEnvelopeWriter.h"
#import "ATLTransport.h"

static NSString *const ATLCoreVersion = @"0.2.0";

@interface ATLCore ()

- (ATLEnvelopeWriter *)newWriter;
- (void)offerBytes:(NSData *)envelope;
- (BOOL)persistBytes:(NSData *)envelope;

@end

@implementation ATLBatch {
    ATLCore *_core;
    ATLEnvelopeWriter *_writer;
}

- (instancetype)initWithCore:(ATLCore *)core {
    self = [super init];

    if (self) {
        _core = core;
        _writer = [core newWriter];
    }

    return self;
}

- (ATLBatch *)add:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload {
    [_writer add:type payload:payload];

    return self;
}

- (void)enqueue {
    [_core offerBytes:[_writer bytes]];
}

- (BOOL)persistNow {
    return [_core persistBytes:[_writer bytes]];
}

@end

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

- (ATLEnvelopeWriter *)newWriter {
    return [[ATLEnvelopeWriter alloc] initWithSDKName:_sdkName
                                              version:ATLCoreVersion
                                               sentAt:[ATLCore isoNow]
                                            installId:_installId
                                              context:_context];
}

- (void)enqueue:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload {
    [[[self batch] add:type payload:payload] enqueue];
}

- (ATLBatch *)batch {
    return [[ATLBatch alloc] initWithCore:self];
}

- (void)offerBytes:(NSData *)envelope {
    dispatch_async(_worker, ^{
        [self->_queue offer:envelope];
        [self drain];
    });
}

- (BOOL)persistBytes:(NSData *)envelope {
    BOOL written = [_queue offer:envelope] != nil;

    if (written) {
        [self flushSoon];
    }

    return written;
}

- (void)flushSoon {
    dispatch_async(_worker, ^{
        [self drain];
    });
}

- (void)flushWithin:(NSTimeInterval)seconds {
    if (seconds <= 0) {
        return;
    }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    dispatch_async(_worker, ^{
        [self drain];
        dispatch_semaphore_signal(done);
    });

    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (seconds * NSEC_PER_SEC)));
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
    return [self iso:[[NSDate date] timeIntervalSince1970]];
}

+ (NSString *)iso:(NSTimeInterval)epochSeconds {
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

    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:epochSeconds]];
    }
}

@end
