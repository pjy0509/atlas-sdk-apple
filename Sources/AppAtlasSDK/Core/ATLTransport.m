#import "ATLTransport.h"

#include <zlib.h>

/// The envelope gzipped, or itself when compression fails or does not pay.
/// A crash with a hundred threads is a tenth of its size on the wire, and
/// the server inflates before it judges the cap.
static NSData *ATLGzip(NSData *envelope) {
    if (envelope.length < 512) {
        return envelope;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // 15 + 16: a gzip header rather than zlib's.
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return envelope;
    }

    NSMutableData *packed = [NSMutableData dataWithLength:deflateBound(&stream, (uLong) envelope.length)];
    stream.next_in = (Bytef *) envelope.bytes;
    stream.avail_in = (uInt) envelope.length;
    stream.next_out = packed.mutableBytes;
    stream.avail_out = (uInt) packed.length;

    int status = deflate(&stream, Z_FINISH);
    NSUInteger produced = stream.total_out;
    deflateEnd(&stream);

    if (status != Z_STREAM_END || produced >= envelope.length) {
        return envelope;
    }

    packed.length = produced;

    return packed;
}

@implementation ATLTransport {
    NSURL *_endpoint;
    NSString *_authorization;
    NSURLSession *_session;
    // Milliseconds since the epoch; volatile-enough under the worker's
    // single-thread discipline.
    NSTimeInterval _retryNotBeforeMs;
}

- (instancetype)initWithBaseURL:(NSString *)baseUrl sdkKey:(NSString *)sdkKey {
    self = [super init];

    if (self) {
        _endpoint = [NSURL URLWithString:[baseUrl stringByAppendingString:@"/api/ingest/envelope"]];
        _authorization = [@"Bearer " stringByAppendingString:sdkKey];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }

    return self;
}

- (BOOL)limitedAt:(NSTimeInterval)nowMs {
    return nowMs < _retryNotBeforeMs;
}

- (ATLTransportVerdict)send:(NSData *)envelope at:(NSTimeInterval)nowMs {
    if ([self limitedAt:nowMs]) {
        return ATLTransportVerdictRetryLater;
    }

    NSData *wire = ATLGzip(envelope);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = wire;
    [request setValue:_authorization forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-atlas-envelope" forHTTPHeaderField:@"Content-Type"];

    if (wire != envelope) {
        [request setValue:@"gzip" forHTTPHeaderField:@"Content-Encoding"];
    }

    // Synchronous on purpose: the worker drains one file at a time, in order.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSHTTPURLResponse *answer = nil;
    __block NSError *failure = nil;

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                             completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            answer = (NSHTTPURLResponse *) response;
        }

        failure = error;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (15.0 * NSEC_PER_SEC)));

    if (failure != nil || answer == nil) {
        return ATLTransportVerdictRetryLater;
    }

    NSInteger status = answer.statusCode;

    if (status == 429) {
        NSString *after = [ATLTransport headerField:@"Retry-After" of:answer];
        NSTimeInterval delay = after != nil ? [after doubleValue] * 1000.0 : 60000.0;
        _retryNotBeforeMs = nowMs + (delay > 0 ? delay : 60000.0);

        return ATLTransportVerdictRetryLater;
    }

    if (status >= 200 && status < 300) {
        return ATLTransportVerdictDelivered;
    }

    if (status >= 400 && status < 500) {
        return ATLTransportVerdictRefused;
    }

    return ATLTransportVerdictRetryLater;
}

+ (NSString *)headerField:(NSString *)name of:(NSHTTPURLResponse *)response {
    // allHeaderFields is documented case-insensitive-ish but not everywhere;
    // walk once rather than trust it.
    for (id key in response.allHeaderFields) {
        if ([[key description] caseInsensitiveCompare:name] == NSOrderedSame) {
            return [response.allHeaderFields[key] description];
        }
    }

    return nil;
}

@end
