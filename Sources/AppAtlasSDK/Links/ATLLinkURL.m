#import "ATLLinkURL.h"

@implementation ATLLinkURL

+ (ATLLinkURL *)parse:(NSString *)url {
    if (url == nil) {
        return nil;
    }

    NSURLComponents *parsed = [NSURLComponents componentsWithString:url];

    if (parsed == nil || parsed.path == nil) {
        return nil;
    }

    NSArray<NSString *> *segments = [[parsed.path stringByTrimmingCharactersInSet:
                                      [NSCharacterSet characterSetWithCharactersInString:@"/"]]
                                     componentsSeparatedByString:@"/"];

    ATLLinkURL *link = [[ATLLinkURL alloc] init];

    // The clipboard handoff: /c/<click_id>.<signature>.
    if (segments.count == 2 && [segments[0] isEqualToString:@"c"] && [ATLLinkURL isClaimToken:segments[1]]) {
        link->_claimToken = segments[1];

        return link;
    }

    // The visit URL: one segment in the server's short-id alphabet.
    if (segments.count != 1 || ![ATLLinkURL isShortId:segments.firstObject]) {
        return nil;
    }

    link->_shortId = segments.firstObject;

    for (NSURLQueryItem *item in parsed.queryItems) {
        if ([item.name isEqualToString:@"ch"]) link->_channel = item.value;
        else if ([item.name isEqualToString:@"cp"]) link->_campaign = item.value;
        else if ([item.name isEqualToString:@"src"]) link->_source = item.value;
        else if ([item.name isEqualToString:@"nid"]) link->_pushId = item.value;
    }

    return link;
}

/// The server's alphabet (db/deep_links.py): 7 chars, no 0/O/1/l/I.
+ (BOOL)isShortId:(NSString *)candidate {
    return [ATLLinkURL matches:candidate pattern:@"^[2-9A-HJ-NP-Za-km-z]{7}$"];
}

/// The mint's shape: 16 hex chars, a dot, an unpadded-base64url signature.
+ (BOOL)isClaimToken:(NSString *)candidate {
    return [ATLLinkURL matches:candidate pattern:@"^[0-9a-f]{16}\\.[A-Za-z0-9_-]{20,64}$"];
}

+ (BOOL)matches:(NSString *)text pattern:(NSString *)pattern {
    if (text == nil) {
        return NO;
    }

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", pattern];

    return [predicate evaluateWithObject:text];
}

@end
