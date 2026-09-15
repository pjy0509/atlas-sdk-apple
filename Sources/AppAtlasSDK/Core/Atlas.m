#import "Atlas.h"

#import "ATLDeviceContext.h"

static NSString *const ATLDefaultBaseURL = @"https://appatlas.dev";
static NSString *const ATLInstallIdKey = @"dev.appatlas.sdk.installId";
// Set the launch the install id is minted, read by the links module: the
// pasteboard is only worth asking on the install's own first run.
static NSString *const ATLFreshInstallKey = @"dev.appatlas.sdk.freshInstall";

static ATLCore *ATLSharedCore = nil;

@implementation Atlas

+ (void)startWithKey:(NSString *)sdkKey {
    [self startWithKey:sdkKey baseUrl:ATLDefaultBaseURL];
}

+ (void)startWithKey:(NSString *)sdkKey baseUrl:(NSString *)baseUrl {
    @synchronized (self) {
        if (ATLSharedCore != nil) {
            return;
        }

        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;

        ATLSharedCore = [[ATLCore alloc] initWithSDKName:@"atlas-apple"
                                                 baseUrl:baseUrl
                                                  sdkKey:sdkKey
                                                queueDir:[caches stringByAppendingPathComponent:@"atlas/queue"]
                                               installId:[Atlas installId]
                                                 context:[ATLDeviceContext snapshot]];
    }

    // Whatever a previous run could not send leaves now.
    [ATLSharedCore flushSoon];

    // Modules on the classpath wake with the core; a pod the app did not
    // ship is simply absent (the Android binding's reflective boot, in
    // NSClassFromString form).
    Class links = NSClassFromString(@"ATLLinks");
    SEL boot = NSSelectorFromString(@"boot");

    if (links != nil && [links respondsToSelector:boot]) {
        // Suppressed because the selector is resolved by name on purpose: the
        // class is absent unless the app shipped the module.
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [links performSelector:boot];
        #pragma clang diagnostic pop
    }
}

+ (ATLCore *)core {
    return ATLSharedCore;
}

/// An install-scoped random id: minted on first start, gone with the app.
/// Never a device identifier — nothing here reads one.
+ (NSString *)installId {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *existing = [defaults stringForKey:ATLInstallIdKey];

    if (existing != nil) {
        return existing;
    }

    NSString *minted = [[[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""]
                        substringToIndex:16].lowercaseString;
    [defaults setObject:minted forKey:ATLInstallIdKey];
    [defaults setBool:YES forKey:ATLFreshInstallKey];

    return minted;
}

@end
