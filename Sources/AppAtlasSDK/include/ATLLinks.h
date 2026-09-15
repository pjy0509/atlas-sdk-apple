#import <Foundation/Foundation.h>

#import "ATLLink.h"

NS_ASSUME_NONNULL_BEGIN

/// What the links module needs from a pasteboard, and nothing more. The
/// system implementation (ATLSystemPasteboard) is the only UIKit touch in
/// the module; the parity gate runs the whole flow against a mock.
@protocol ATLPasteboardReading <NSObject>

/// Whether a URL is plausibly present — free of the paste prompt.
- (BOOL)hasURLs;

/// The pasteboard string; this is the read that costs the iOS 16 prompt.
- (nullable NSString *)string;

/// Clears a consumed handoff, so a second app cannot re-claim it.
- (void)clear;

@end

/// The links module: direct opens handed in from the app delegate, and the
/// consented clipboard handoff claimed once after install. One listener for
/// both. Attach after Atlas.start:
///
///     [ATLLinks setListener:^(ATLLink *link) { … }];
///     [ATLLinks checkPasteboardOnFirstLaunch];   // opt-in, by design
///
/// and from the delegate:
///
///     [ATLLinks handleUserActivity:activity];
///     [ATLLinks handleURL:url];
NS_SWIFT_NAME(AtlasLinks)
@interface ATLLinks : NSObject

/// Called by Atlas through NSClassFromString; not application API.
+ (void)boot;

+ (void)setListener:(nullable ATLLinkListener)listener;

/// The link that survived the install, set once ever; nil before then.
+ (nullable ATLLink *)firstReferringLink;

/// Universal Link arrivals. Returns YES when the activity was a visit URL.
+ (BOOL)handleUserActivity:(NSUserActivity *)activity NS_SWIFT_NAME(handle(userActivity:));

/// Custom-scheme and handoff arrivals. Returns YES when the URL was ours.
+ (BOOL)handleURL:(NSURL *)url NS_SWIFT_NAME(handle(_:));

/// The consented clipboard read, once per install and only on the install's
/// own first run: hasURLs pre-check (no prompt), then the read (the prompt),
/// own-link validation, claim, and a clear so the handoff cannot re-claim.
/// Opt-in by being a call the app must make — the iOS 16 prompt is the app's
/// UX to own.
+ (void)checkPasteboardOnFirstLaunch;

@end

NS_ASSUME_NONNULL_END
