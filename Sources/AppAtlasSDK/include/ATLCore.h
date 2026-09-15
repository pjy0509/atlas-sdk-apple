#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The platform-free half of the SDK: an item goes to disk first as a
/// one-item envelope, and a single serial worker drains the queue — at start,
/// and after every offer. Modules hand items in; they never touch the network
/// themselves.
@interface ATLCore : NSObject

@property (nonatomic, readonly) NSString *installId;
@property (nonatomic, readonly) NSString *baseUrl;

- (instancetype)initWithSDKName:(NSString *)sdkName
                        baseUrl:(NSString *)baseUrl
                         sdkKey:(NSString *)sdkKey
                       queueDir:(NSString *)queueDir
                      installId:(NSString *)installId
                        context:(nullable NSDictionary<NSString *, id> *)context;

/// A fresh id for one event: the server's idempotency handle.
+ (NSString *)newEventId;

/// One item, disk-first, then the wire. Only the in-memory serialization
/// happens on the caller's thread.
- (void)enqueue:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload;

/// Drain whatever the disk holds.
- (void)flushSoon;

/// Blocks until the worker has gone idle; for the parity gate, never app code.
- (void)awaitIdle;

@end

NS_ASSUME_NONNULL_END
