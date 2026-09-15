#import <Foundation/Foundation.h>

#import "ATLClaimClient.h"
#import "ATLCore.h"
#import "ATLDiskQueue.h"
#import "ATLEnvelopeWriter.h"
#import "ATLLinkURL.h"
#import "ATLLinks.h"
#import "ATLTransport.h"
#import "Atlas.h"

// The gate reaches the module's internals the way its own binding does; the
// public surface stays exactly the public surface.
@interface ATLLinks (Gate)
+ (void)setPasteboard:(id<ATLPasteboardReading>)pasteboard;
@end

@interface GateMockPasteboard : NSObject <ATLPasteboardReading>
@property (nonatomic) NSString *content;
@property (nonatomic) NSUInteger reads;
@property (nonatomic) BOOL cleared;
@end

@implementation GateMockPasteboard

- (BOOL)hasURLs {
    return self.content != nil;
}

- (NSString *)string {
    self.reads++;

    return self.content;
}

- (void)clear {
    self.cleared = YES;
    self.content = nil;
}

@end

static void require(BOOL held, NSString *complaint) {
    if (!held) {
        fprintf(stderr, "FAIL: %s\n", complaint.UTF8String);
        exit(1);
    }
}

/// Runs the main queue until the check passes or the deadline does.
static void spinUntil(BOOL (^check)(void), NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

    while (!check() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static NSString *TOKEN = @"ab12cd34ef56ab78.c2ln-bmF0dXJlLXNsb3Q";

static void writeSamples(NSString *outDir) {
    NSDictionary *context = @{@"device": @{@"os": @"ios", @"osVersion": @"17.4"}};

    NSData *open = [[[[ATLEnvelopeWriter alloc] initWithSDKName:@"atlas-apple" version:@"0.1.0"
                                                         sentAt:@"2026-09-15T09:00:00Z"
                                                      installId:@"c1a2b3d4e5f60718"
                                                        context:context]
                     add:@"open" payload:@{@"eventId": @"11111111-2222-3333-4444-555555555555",
                                           @"shortId": @"aB3kM9p", @"channel": @"email"}] bytes];
    [open writeToFile:[outDir stringByAppendingPathComponent:@"open.envelope"] atomically:YES];

    NSString *note = @"line\nbreak \"quoted\" back\\slash 한글 ctl:\x01";
    NSData *hostile = [[[[ATLEnvelopeWriter alloc] initWithSDKName:@"atlas-apple" version:@"0.1.0"
                                                            sentAt:@"2026-09-15T09:00:00Z"
                                                         installId:@"c1a2b3d4e5f60718"
                                                           context:nil]
                        add:@"open" payload:@{@"eventId": @"22222222-0000-0000-0000-000000000002",
                                              @"note": note,
                                              @"nested": @{@"deep": @YES, @"count": @42}}] bytes];
    [hostile writeToFile:[outDir stringByAppendingPathComponent:@"hostile.envelope"] atomically:YES];

    NSData *pair = [[[[[ATLEnvelopeWriter alloc] initWithSDKName:@"atlas-apple" version:@"0.1.0"
                                                          sentAt:@"2026-09-15T09:00:00Z"
                                                       installId:@"c1a2b3d4e5f60718"
                                                         context:nil]
                      add:@"open" payload:@{@"eventId": @"33333333-0000-0000-0000-000000000001"}]
                     add:@"session" payload:@{@"eventId": @"33333333-0000-0000-0000-000000000002"}] bytes];
    [pair writeToFile:[outDir stringByAppendingPathComponent:@"pair.envelope"] atomically:YES];
}

static void checkQueue(NSString *outDir) {
    ATLDiskQueue *queue = [[ATLDiskQueue alloc] initWithDirectory:
                           [outDir stringByAppendingPathComponent:@"queue"]];

    for (NSUInteger index = 0; index < ATLDiskQueue.maxFiles + 5; index++) {
        NSData *bytes = [[[[ATLEnvelopeWriter alloc] initWithSDKName:@"t" version:@"0" sentAt:@"now"
                                                           installId:@"id" context:nil]
                          add:@"open" payload:@{@"n": @(index)}] bytes];
        require([queue offer:bytes] != nil, @"offer failed");
    }

    NSArray<NSString *> *listed = [queue list];
    require(listed.count == ATLDiskQueue.maxFiles, @"cap not held");

    for (NSUInteger index = 1; index < listed.count; index++) {
        require([listed[index - 1] compare:listed[index]] == NSOrderedAscending, @"order broken");
    }
}

static void checkTransport(NSString *baseUrl) {
    // The mock answers the envelope path 200, 400, 429(+Retry-After 30), 500.
    ATLTransport *transport = [[ATLTransport alloc] initWithBaseURL:baseUrl sdkKey:@"sdk_test"];
    NSData *body = [[[ATLEnvelopeWriter alloc] initWithSDKName:@"t" version:@"0" sentAt:@"now"
                                                     installId:@"id" context:nil] bytes];

    require([transport send:body at:0] == ATLTransportVerdictDelivered, @"2xx must deliver");
    require([transport send:body at:0] == ATLTransportVerdictRefused, @"4xx must refuse");
    require([transport send:body at:0] == ATLTransportVerdictRetryLater, @"429 must defer");
    require([transport limitedAt:29000], @"the Retry-After deadline must hold");
    require(![transport limitedAt:31000], @"the deadline must expire");
    require([transport send:body at:40000] == ATLTransportVerdictRetryLater, @"5xx must retry");
}

static void checkLinkURL(void) {
    ATLLinkURL *visit = [ATLLinkURL parse:@"https://appatlas.dev/aB3kM9p?ch=email&cp=spring%202026&src=qr"];
    require(visit != nil && [visit.shortId isEqualToString:@"aB3kM9p"], @"visit URL must parse");
    require([visit.channel isEqualToString:@"email"], @"ch lost");
    require([visit.campaign isEqualToString:@"spring 2026"], @"cp not decoded");
    require([visit.source isEqualToString:@"qr"], @"src lost");

    ATLLinkURL *handoff = [ATLLinkURL parse:[@"https://appatlas.dev/c/" stringByAppendingString:TOKEN]];
    require(handoff != nil && [handoff.claimToken isEqualToString:TOKEN], @"handoff token lost");

    require([ATLLinkURL parse:@"https://appatlas.dev/install"] == nil, @"an excluded letter must refuse");
    require([ATLLinkURL parse:@"https://appatlas.dev/aB3kM9p/extra"] == nil, @"two segments are not a link");
    require([ATLLinkURL parse:@"not a url"] == nil, @"garbage must be nil");
}

static void checkLinksFlow(NSString *baseUrl, NSString *outDir) {
    // A clean slate: the gate reruns, the state keys must not linger.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    for (NSString *key in @[@"dev.appatlas.sdk.links.claimDone", @"dev.appatlas.sdk.links.firstLink"]) {
        [defaults removeObjectForKey:key];
    }

    // A fixed install id keeps the claim body byte-stable for the golden; the
    // fresh-install flag is what the clipboard gate reads, so it is set too.
    [defaults setObject:@"install-1" forKey:@"dev.appatlas.sdk.installId"];
    [defaults setBool:YES forKey:@"dev.appatlas.sdk.freshInstall"];

    [Atlas startWithKey:@"sdk_test" baseUrl:baseUrl];
    require([Atlas core] != nil, @"the core must start");

    GateMockPasteboard *pasteboard = [[GateMockPasteboard alloc] init];
    pasteboard.content = [@"https://appatlas.dev/c/" stringByAppendingString:TOKEN];
    [ATLLinks setPasteboard:pasteboard];

    // The tap landed before the listener registered: the claim (mock answers
    // 200) must queue and replay.
    [ATLLinks checkPasteboardOnFirstLaunch];

    __block ATLLink *received = nil;
    [ATLLinks setListener:^(ATLLink *link) {
        received = link;
    }];
    spinUntil(^BOOL { return received != nil; }, 5.0);

    require(received != nil, @"the deferred link never arrived");
    require(received.deferred, @"a claim is deferred by definition");
    require([received.path isEqualToString:@"spotify://"], @"path lost");
    require([received.payload[@"promo"] isEqualToString:@"launch"], @"payload lost");
    require([received.match isEqualToString:@"clipboard"], @"match lost");
    require(pasteboard.cleared, @"a consumed handoff must be cleared");
    require([ATLLinks firstReferringLink] != nil, @"firstReferringLink must persist");
    require([defaults boolForKey:@"dev.appatlas.sdk.links.claimDone"], @"the ack must set the flag");

    // Once ever: a second call must not read the pasteboard again.
    NSUInteger reads = pasteboard.reads;
    pasteboard.content = @"https://appatlas.dev/c/ffffffffffffffff.ZmFrZS1zZWNvbmQtdG9rZW4";
    [ATLLinks checkPasteboardOnFirstLaunch];
    require(pasteboard.reads == reads, @"claimDone must end the reads");

    // A direct open: the visit URL routes to the listener and lands an open
    // envelope on the queue for the drain.
    received = nil;
    require([ATLLinks handleURL:[NSURL URLWithString:@"https://appatlas.dev/aB3kM9p?ch=email"]],
            @"a visit URL must be handled");
    spinUntil(^BOOL { return received != nil; }, 5.0);
    require(received != nil && !received.deferred, @"the direct link must arrive undeferred");
    require([received.shortId isEqualToString:@"aB3kM9p"], @"shortId lost");

    require(![ATLLinks handleURL:[NSURL URLWithString:@"https://appatlas.dev/settings"]],
            @"a stranger URL must be refused");

    [[Atlas core] awaitIdle];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outDir = [NSString stringWithUTF8String:argv[1]];
        NSString *baseUrl = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];

        writeSamples(outDir);
        checkQueue(outDir);
        checkTransport(baseUrl);
        checkLinkURL();
        checkLinksFlow(baseUrl, outDir);

        printf("parity: ios envelopes, queue, transport, links and clipboard flow hold\n");
    }

    return 0;
}
