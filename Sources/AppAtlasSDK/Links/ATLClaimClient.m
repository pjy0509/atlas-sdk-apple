#import "ATLClaimClient.h"

@implementation ATLClaimClient {
    NSURL *_endpoint;
    NSURLSession *_session;
}

- (instancetype)initWithBaseURL:(NSString *)baseUrl {
    self = [super init];

    if (self) {
        _endpoint = [NSURL URLWithString:[baseUrl stringByAppendingString:@"/api/ingest/link/claim"]];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }

    return self;
}

- (ATLClaimOutcome)claim:(NSString *)token
               installId:(NSString *)installId
                     via:(NSString *)via
                    link:(ATLLink **)link {
    NSDictionary *body = @{@"token": token, @"installId": installId, @"os": @"ios", @"via": via};

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *answerBody = nil;
    __block NSHTTPURLResponse *answer = nil;
    __block NSError *failure = nil;

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        answerBody = data;

        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            answer = (NSHTTPURLResponse *) response;
        }

        failure = error;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (15.0 * NSEC_PER_SEC)));

    if (failure != nil || answer == nil) {
        return ATLClaimOutcomeRetry;
    }

    NSInteger status = answer.statusCode;

    if (status >= 200 && status < 300) {
        if (link != NULL) {
            *link = [ATLClaimClient linkFromAnswer:answerBody];
        }

        return ATLClaimOutcomeDone;
    }

    // Already claimed, expired, or never ours: over, quietly.
    if (status == 404 || status == 409) {
        return ATLClaimOutcomeDone;
    }

    return ATLClaimOutcomeRetry;
}

+ (ATLLink *)linkFromAnswer:(NSData *)body {
    NSDictionary *parsed = body != nil
        ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL]
        : nil;

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        parsed = @{};
    }

    NSDictionary *payload = [parsed[@"payload"] isKindOfClass:[NSDictionary class]] ? parsed[@"payload"] : @{};

    return [[ATLLink alloc] initWithPayload:payload
                                       path:[ATLClaimClient text:parsed[@"path"]]
                                    shortId:nil
                                    channel:[ATLClaimClient text:parsed[@"channel"]]
                                   campaign:[ATLClaimClient text:parsed[@"campaign"]]
                                  clickedAt:[ATLClaimClient text:parsed[@"clickedAt"]]
                                   deferred:YES
                                      match:[ATLClaimClient text:parsed[@"match"]]];
}

+ (NSString *)text:(id)value {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@end
