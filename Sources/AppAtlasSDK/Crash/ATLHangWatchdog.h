#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A main-thread hang, seen from a thread of its own: a block is posted to
/// the main queue every `timeout` seconds, and one that has not run by the
/// next tick means the main thread is stuck. Reported once per freeze, with
/// the main thread's frames sampled while it is stuck — the iOS peer of an
/// Android ANR, and the fact the run state needs to tell a watchdog kill
/// from an out-of-memory kill. Off under a debugger; not started at all in
/// a simulator or an extension.
@interface ATLHangWatchdog : NSObject

/// `onHang` runs on the watchdog's thread with the main thread's frames as
/// the wire wants them; `onRecover` when the main thread answers again.
- (instancetype)initWithTimeout:(NSTimeInterval)timeout
                         onHang:(void (^)(NSArray *frames, NSTimeInterval stuckFor))onHang
                      onRecover:(void (^)(void))onRecover;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
