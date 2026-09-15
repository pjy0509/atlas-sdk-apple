#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The write-before-send store: an envelope hits disk before any network is
/// tried, and the flush at next start is what delivery really rests on. The
/// cap evicts oldest-first; the filename carries the order.
@interface ATLDiskQueue : NSObject

@property (class, nonatomic, readonly) NSUInteger maxFiles;

- (instancetype)initWithDirectory:(NSString *)directory;

/// Persists the envelope, evicting the oldest past the cap. Nil on a disk
/// that refuses — the event is gone, the app must not be.
- (nullable NSString *)offer:(NSData *)envelope;

/// Oldest first, the order they should leave in.
- (NSArray<NSString *> *)list;

@end

NS_ASSUME_NONNULL_END
