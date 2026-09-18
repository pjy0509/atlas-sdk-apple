#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ATLBatch;

/// The platform-free half of the SDK: an item goes to disk first as a
/// one-item envelope, and a single serial worker drains the queue — at start,
/// and after every offer. Modules hand items in; they never touch the network
/// themselves.
NS_SWIFT_NAME(AtlasCore)
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

/// The wire's instant format, UTC to the second.
+ (NSString *)isoNow;
+ (NSString *)iso:(NSTimeInterval)epochSeconds;

/// One item, disk-first, then the wire. Only the in-memory serialization
/// happens on the caller's thread.
- (void)enqueue:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload;

/// Several items that must arrive together: a crash and its session's end.
- (ATLBatch *)batch;

/// Drain whatever the disk holds.
- (void)flushSoon;

/// Drain now and wait for it, up to `seconds`: the launch-crash fast path,
/// where the next start sends the crash before it can happen again.
- (void)flushWithin:(NSTimeInterval)seconds;

/// Blocks until the worker has gone idle; for the parity gate, never app code.
- (void)awaitIdle;

@end

/// One envelope holding several items, sent together or not at all.
NS_SWIFT_NAME(AtlasBatch)
@interface ATLBatch : NSObject

- (ATLBatch *)add:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload;

/// Disk on the worker, then the wire.
- (void)enqueue;

/// Disk on the caller's thread, synchronously, then the wire from the worker.
/// For a thread that is about to die. NO when the disk refused.
- (BOOL)persistNow;

@end

NS_ASSUME_NONNULL_END
