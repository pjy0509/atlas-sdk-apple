#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the one listener receives, direct and deferred alike: the link's own
/// payload plus how it arrived. One shape for both cases — two code paths
/// for one concept is the integration bug factory.
NS_SWIFT_NAME(AtlasLink)
@interface ATLLink : NSObject

/// The link's custom key-values, exactly as saved on the link.
@property (nonatomic, readonly) NSDictionary<NSString *, id> *payload;
/// The deep-link path for this platform, when the link names one.
@property (nonatomic, readonly, nullable) NSString *path;
@property (nonatomic, readonly, nullable) NSString *shortId;
@property (nonatomic, readonly, nullable) NSString *channel;
@property (nonatomic, readonly, nullable) NSString *campaign;
/// When the click that produced this link happened (ISO 8601); nil on a
/// direct open, which has no click behind it.
@property (nonatomic, readonly, nullable) NSString *clickedAt;
/// YES when this link survived an install (a claimed store handoff).
@property (nonatomic, readonly) BOOL deferred;
/// referrer, campaign_id, clipboard, relink — or nil for a direct open.
@property (nonatomic, readonly, nullable) NSString *match;

- (instancetype)initWithPayload:(NSDictionary<NSString *, id> *)payload
                           path:(nullable NSString *)path
                        shortId:(nullable NSString *)shortId
                        channel:(nullable NSString *)channel
                       campaign:(nullable NSString *)campaign
                      clickedAt:(nullable NSString *)clickedAt
                       deferred:(BOOL)deferred
                          match:(nullable NSString *)match;

@end

typedef void (^ATLLinkListener)(ATLLink *link) NS_SWIFT_NAME(AtlasLinkListener);

NS_ASSUME_NONNULL_END
