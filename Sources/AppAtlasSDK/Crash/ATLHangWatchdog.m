#import "ATLHangWatchdog.h"

#import "ATLCrashReport.h"

#include "atl_crash_capture.h"

@implementation ATLHangWatchdog {
    NSTimeInterval _timeout;
    void (^_onHang)(NSArray *, NSTimeInterval);
    void (^_onRecover)(void);
    NSThread *_thread;
    volatile BOOL _stop;
    // Uptime of the last block the main thread ran; written on main, read here.
    volatile NSTimeInterval _lastAck;
}

- (instancetype)initWithTimeout:(NSTimeInterval)timeout
                         onHang:(void (^)(NSArray *, NSTimeInterval))onHang
                      onRecover:(void (^)(void))onRecover {
    self = [super init];

    if (self) {
        _timeout = timeout;
        _onHang = [onHang copy];
        _onRecover = [onRecover copy];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"atlas-crash-watchdog";
        _thread.qualityOfService = NSQualityOfServiceUtility;
    }

    return self;
}

- (void)start {
    _lastAck = [self now];
    [_thread start];
}

- (void)stop {
    _stop = YES;
}

- (NSTimeInterval)now {
    return [NSProcessInfo processInfo].systemUptime;
}

- (void)run {
    BOOL firedForThisFreeze = NO;
    NSTimeInterval stuckSince = 0;

    while (!_stop) {
        NSTimeInterval posted = [self now];
        __weak ATLHangWatchdog *weakSelf = self;

        dispatch_async(dispatch_get_main_queue(), ^{
            ATLHangWatchdog *strongSelf = weakSelf;

            if (strongSelf != nil) {
                strongSelf->_lastAck = [strongSelf now];
            }
        });

        // The tick is also when other threads' names are read for the crash
        // report: never at crash time.
        atl_crash_refresh_thread_names();
        [NSThread sleepForTimeInterval:_timeout];

        if (_stop) {
            break;
        }

        // Answered within the window: no freeze, and any earlier freeze has
        // cleared, so the next one may fire again.
        if (_lastAck >= posted) {
            if (firedForThisFreeze && _onRecover != nil) {
                _onRecover();
            }

            firedForThisFreeze = NO;
            stuckSince = 0;
            continue;
        }

        // A debugger paused the main thread: not a freeze the user feels.
        if (atl_crash_debugger_attached()) {
            continue;
        }

        if (stuckSince == 0) {
            stuckSince = posted;
        }

        if (!firedForThisFreeze) {
            firedForThisFreeze = YES;
            _onHang([self mainThreadFrames], [self now] - stuckSince);
        }
    }
}

- (NSArray *)mainThreadFrames {
    uintptr_t addresses[128];
    int count = atl_crash_snapshot_main(addresses, 128);

    return [ATLCrashReport framesForAddresses:addresses count:(NSUInteger) MAX(count, 0) topIsPC:YES];
}

@end
