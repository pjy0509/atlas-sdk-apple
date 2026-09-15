#import "ATLTransport.h"

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

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = envelope;
    [request setValue:_authorization forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/x-atlas-envelope" forHTTPHeaderField:@"Content-Type"];

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
