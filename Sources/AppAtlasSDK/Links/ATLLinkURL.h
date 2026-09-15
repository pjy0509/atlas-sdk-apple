#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads an incoming visit URL: the short id in its single path segment, and
/// the inflow keys the page also reads (ch, cp, src, nid). Host-agnostic on
/// purpose — a custom link domain is still the same URL shape. Also reads
/// the clipboard handoff form (/c/<token>), which carries a claim token
/// instead of a short id.
@interface ATLLinkURL : NSObject

@property (nonatomic, readonly, nullable) NSString *shortId;
@property (nonatomic, readonly, nullable) NSString *channel;
@property (nonatomic, readonly, nullable) NSString *campaign;
@property (nonatomic, readonly, nullable) NSString *source;
@property (nonatomic, readonly, nullable) NSString *pushId;
/// The claim token of a /c/<token> handoff URL; nil on a plain visit URL.
@property (nonatomic, readonly, nullable) NSString *claimToken;

/// The parsed link, or nil when the URL is neither shape.
+ (nullable ATLLinkURL *)parse:(NSString *)url;

@end

NS_ASSUME_NONNULL_END
