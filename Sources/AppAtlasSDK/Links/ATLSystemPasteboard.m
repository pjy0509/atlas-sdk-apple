#import <Foundation/Foundation.h>

#if __has_include(<UIKit/UIKit.h>)

#import <UIKit/UIKit.h>

#import "ATLLinks.h"

/// The module's single UIKit touch: the general pasteboard behind the
/// module's own protocol, so everything above it runs and tests without a
/// device. hasURLs (iOS 10+) is the prompt-free pre-check the incumbents
/// ship; the read itself is what shows the iOS 16 paste banner.
@interface ATLSystemPasteboard : NSObject <ATLPasteboardReading>
@end

@implementation ATLSystemPasteboard

- (BOOL)hasURLs {
    if (@available(iOS 10.0, *)) {
        return [UIPasteboard generalPasteboard].hasURLs || [UIPasteboard generalPasteboard].hasStrings;
    }

    return YES;
}

- (NSString *)string {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];

    return pasteboard.URL != nil ? pasteboard.URL.absoluteString : pasteboard.string;
}

- (void)clear {
    // Only ever called after a consumed handoff of our own shape; a second
    // app must not re-claim it (the Branch lesson).
    [UIPasteboard generalPasteboard].items = @[];
}

@end

#endif
