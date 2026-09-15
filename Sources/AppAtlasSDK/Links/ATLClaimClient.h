#import <Foundation/Foundation.h>

#import "ATLLink.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ATLClaimOutcome) {
    /// Claimed, already claimed, or never ours: the attempts end here.
    ATLClaimOutcomeDone,
    /// Offline or a server-side stumble: ask again next launch.
    ATLClaimOutcomeRetry,
};

/// Exchanges a click token for the link it came from. The consumption rule:
/// nothing is marked done until the server has answered — a claim lost to a
/// dead process replays next launch, and the server's 409 makes the replay
/// harmless.
@interface ATLClaimClient : NSObject

- (instancetype)initWithBaseURL:(NSString *)baseUrl;

/// Synchronous; only ever called off the main thread. `link` is set only on
/// a 2xx with a body.
- (ATLClaimOutcome)claim:(NSString *)token
               installId:(NSString *)installId
                     via:(NSString *)via
                    link:(ATLLink *_Nullable __autoreleasing *_Nullable)link;

@end

NS_ASSUME_NONNULL_END
