#import "ATLLink.h"

@implementation ATLLink

- (instancetype)initWithPayload:(NSDictionary<NSString *, id> *)payload
                           path:(NSString *)path
                        shortId:(NSString *)shortId
                        channel:(NSString *)channel
                       campaign:(NSString *)campaign
                      clickedAt:(NSString *)clickedAt
                       deferred:(BOOL)deferred
                          match:(NSString *)match {
    self = [super init];

    if (self) {
        _payload = [payload copy];
        _path = [path copy];
        _shortId = [shortId copy];
        _channel = [channel copy];
        _campaign = [campaign copy];
        _clickedAt = [clickedAt copy];
        _deferred = deferred;
        _match = [match copy];
    }

    return self;
}

@end
