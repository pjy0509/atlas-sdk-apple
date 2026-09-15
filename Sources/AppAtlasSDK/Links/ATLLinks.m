#import "ATLLinks.h"

#import "ATLClaimClient.h"
#import "ATLLinkURL.h"
#import "Atlas.h"

static NSString *const ATLClaimDoneKey = @"dev.appatlas.sdk.links.claimDone";
static NSString *const ATLFirstLinkKey = @"dev.appatlas.sdk.links.firstLink";
static NSString *const ATLFreshInstallKey = @"dev.appatlas.sdk.freshInstall";

static ATLLinkListener ATLListener = nil;
// Links that arrived before the listener did — the cold-start tap lands
// before application code can register.
static NSMutableArray<ATLLink *> *ATLQueue = nil;
static id<ATLPasteboardReading> ATLPasteboard = nil;

@implementation ATLLinks

+ (void)boot {
    @synchronized (self) {
        if (ATLQueue == nil) {
            ATLQueue = [NSMutableArray array];
        }

        if (ATLPasteboard == nil) {
            // The UIKit half, when the target links it; the gate injects a mock.
            Class system = NSClassFromString(@"ATLSystemPasteboard");

            if (system != nil) {
                ATLPasteboard = [[system alloc] init];
            }
        }
    }
}

+ (void)setPasteboard:(id<ATLPasteboardReading>)pasteboard {
    ATLPasteboard = pasteboard;
}

+ (void)setListener:(ATLLinkListener)listener {
    NSArray<ATLLink *> *replay;

    @synchronized (self) {
        ATLListener = [listener copy];
        replay = [ATLQueue copy];
        [ATLQueue removeAllObjects];
    }

    for (ATLLink *link in replay) {
        [self deliver:link];
    }
}

+ (ATLLink *)firstReferringLink {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:ATLFirstLinkKey];

    if (stored == nil) {
        return nil;
    }

    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[stored dataUsingEncoding:NSUTF8StringEncoding]
                                                           options:0 error:NULL];

    if (![parsed isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *payload = [parsed[@"payload"] isKindOfClass:[NSDictionary class]] ? parsed[@"payload"] : @{};

    return [[ATLLink alloc] initWithPayload:payload
                                       path:[self text:parsed[@"path"]]
                                    shortId:nil
                                    channel:[self text:parsed[@"channel"]]
                                   campaign:[self text:parsed[@"campaign"]]
                                  clickedAt:[self text:parsed[@"clickedAt"]]
                                   deferred:YES
                                      match:[self text:parsed[@"match"]]];
}

+ (BOOL)handleUserActivity:(NSUserActivity *)activity {
    if (![activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || activity.webpageURL == nil) {
        return NO;
    }

    return [self handleURL:activity.webpageURL];
}

+ (BOOL)handleURL:(NSURL *)url {
    ATLLinkURL *link = [ATLLinkURL parse:url.absoluteString];

    if (link == nil) {
        return NO;
    }

    // The handoff form re-tapped after install: a deterministic claim.
    if (link.claimToken != nil) {
        [self claimToken:link.claimToken via:@"relink"];

        return YES;
    }

    ATLCore *core = [Atlas core];

    if (core != nil) {
        // The funnel's third step: an installed app, opened by the link.
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"eventId"] = [ATLCore newEventId];
        payload[@"shortId"] = link.shortId;

        if (link.channel != nil) payload[@"channel"] = link.channel;
        if (link.campaign != nil) payload[@"campaign"] = link.campaign;
        if (link.pushId != nil || [link.source isEqualToString:@"push"]) payload[@"source"] = @"push";

        [core enqueue:@"open" payload:payload];
    }

    // A direct open carries what the URL carries; the saved payload rides
    // only the deferred claim.
    [self deliver:[[ATLLink alloc] initWithPayload:@{}
                                              path:nil
                                           shortId:link.shortId
                                           channel:link.channel
                                          campaign:link.campaign
                                         clickedAt:nil
                                          deferred:NO
                                             match:nil]];

    return YES;
}

+ (void)checkPasteboardOnFirstLaunch {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // The four gates, in cost order: opted in (this call), once ever,
    // the install's own first run, and a plausible URL — all before the
    // read that costs the paste prompt.
    if ([defaults boolForKey:ATLClaimDoneKey]) return;
    if (![defaults boolForKey:ATLFreshInstallKey]) return;
    if (ATLPasteboard == nil || ![ATLPasteboard hasURLs]) return;

    NSString *pasted = [ATLPasteboard string];
    ATLLinkURL *link = pasted != nil ? [ATLLinkURL parse:pasted] : nil;

    if (link == nil || link.claimToken == nil) {
        // Someone else's clipboard: not ours to touch, and not ours to clear.
        return;
    }

    [ATLPasteboard clear];
    [self claimToken:link.claimToken via:@"clipboard"];
}

+ (void)claimToken:(NSString *)token via:(NSString *)via {
    ATLCore *core = [Atlas core];

    if (core == nil) {
        return;
    }

    // Its own queue: a claim must not sit in front of envelope flushes.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ATLLink *link = nil;
        ATLClaimOutcome outcome = [[[ATLClaimClient alloc] initWithBaseURL:core.baseUrl]
                                   claim:token installId:core.installId via:via link:&link];

        if (outcome == ATLClaimOutcomeRetry) {
            return;
        }

        // Ack-gated: only a server answer ends the attempts.
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:ATLClaimDoneKey];

        if (link != nil) {
            [self storeFirstLink:link];
            [self deliver:link];
        }
    });
}

+ (void)deliver:(ATLLink *)link {
    dispatch_async(dispatch_get_main_queue(), ^{
        ATLLinkListener current;

        @synchronized (self) {
            current = ATLListener;

            if (current == nil) {
                [ATLQueue addObject:link];

                return;
            }
        }

        current(link);
    });
}

+ (void)storeFirstLink:(ATLLink *)link {
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    stored[@"payload"] = link.payload;

    if (link.path != nil) stored[@"path"] = link.path;
    if (link.channel != nil) stored[@"channel"] = link.channel;
    if (link.campaign != nil) stored[@"campaign"] = link.campaign;
    if (link.clickedAt != nil) stored[@"clickedAt"] = link.clickedAt;
    if (link.match != nil) stored[@"match"] = link.match;

    NSData *bytes = [NSJSONSerialization dataWithJSONObject:stored options:0 error:NULL];

    if (bytes != nil) {
        [[NSUserDefaults standardUserDefaults] setObject:[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]
                                                  forKey:ATLFirstLinkKey];
    }
}

+ (NSString *)text:(id)value {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

@end
