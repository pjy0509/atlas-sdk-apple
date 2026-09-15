#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ATLTransportVerdict) {
    /// The server took it: delete the file.
    ATLTransportVerdictDelivered,
    /// The server will never take it (4xx): delete, retrying is spam.
    ATLTransportVerdictRefused,
    /// Offline, 5xx, or an active rate limit: keep for later.
    ATLTransportVerdictRetryLater,
};

/// One envelope over the wire, synchronously — only ever called on the core's
/// worker queue. While a 429's Retry-After holds, sends are skipped entirely:
/// buffering during a limit is how one 429 becomes a flood.
@interface ATLTransport : NSObject

- (instancetype)initWithBaseURL:(NSString *)baseUrl sdkKey:(NSString *)sdkKey;

- (BOOL)limitedAt:(NSTimeInterval)nowMs;

- (ATLTransportVerdict)send:(NSData *)envelope at:(NSTimeInterval)nowMs;

@end

NS_ASSUME_NONNULL_END
